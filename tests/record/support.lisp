(in-package #:browser-protocol/record/tests)

;;; Test support: JSON objects, a fake CDP peer for recordings, payload and
;;; event builders, polling, scratch directories.

(defun %h (&rest kvs)
  "A string-key hash-table, as json-protocol decodes a JSON object."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k h) v))
    h))

(defun %event (method &rest params)
  (%h "method" method "params" (apply #'%h params)))

(defun %octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8) :initial-contents bytes))

(defun %b64 (octets)
  (encoding-protocol:encode (coerce octets '(simple-array (unsigned-byte 8) (*)))
                            :encoding :base64))

(defun %wait-until (test &key (timeout 5))
  "Call TEST every 10 ms until it returns true (-> its value) or TIMEOUT seconds pass (-> NIL)."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((value (funcall test)))
        (when value (return value)))
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (sleep 0.01))))

(defun %scratch-directory (name)
  "A fresh, empty scratch directory for one test."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "br1-test-~a-~36r" name
                                       (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (when (probe-file dir)
      (uiop:delete-directory-tree dir :validate t))
    (ensure-directories-exist dir)
    dir))

(defun %remove-directory (dir)
  (when (and dir (probe-file dir))
    (uiop:delete-directory-tree (uiop:ensure-directory-pathname dir) :validate t
                                                                     :if-does-not-exist :ignore)))

(defun %read-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence v in)
      v)))

(defun %write-octets (path octets)
  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede :if-does-not-exist :create)
    (write-sequence octets out))
  path)

;;; --- PCM -------------------------------------------------------------------

(defun %pcm16-code (x)
  "The tap's encoding: round(x * 32768) clamped (JS Math.round differs only at halves)."
  (max -32768 (min 32767 (round (* x 32768)))))

(defun %pcm16-octets (samples)
  "Signed 16-bit little-endian octets of SAMPLES (reals in -1 .. 1)."
  (let ((out (make-array (* 2 (length samples)) :element-type '(unsigned-byte 8)))
        (i 0))
    (map nil (lambda (x)
               (let ((c (ldb (byte 16 0) (%pcm16-code x))))
                 (setf (aref out i) (ldb (byte 8 0) c)
                       (aref out (1+ i)) (ldb (byte 8 8) c))
                 (incf i 2)))
         samples)
    out))

(defun %chunk-payload (&key (track "doc1/1") (seq 0) (rate 48000) (channels 2) (frame 0)
                            (context-time 0) (performance-time 1000) (time-origin 1000000)
                            (samples #(0.5 0.5)) (pcm nil pcm-p) (version 1) omit)
  "A page-tap payload (JSON text) as tap.lisp writes it. OMIT names members to leave out."
  (let ((h (%h "v" version "track" track "seq" seq "rate" rate "channels" channels
               "frame" frame "contextTime" context-time "performanceTime" performance-time
               "timeOrigin" time-origin
               "pcm" (if pcm-p pcm (%b64 (%pcm16-octets samples))))))
    (dolist (k omit) (remhash k h))
    (json-protocol:encode h)))

(defun %chunk (&rest keys &key &allow-other-keys)
  "The AUDIO-CHUNK of (apply #'%chunk-payload KEYS)."
  (rec:parse-audio-chunk (apply #'%chunk-payload keys)))

(defun %samples (buffer)
  "BUFFER's interleaved samples as a list of single-floats."
  (coerce (audio:pcm-buffer-samples buffer) 'list))

(defun %stereo (&rest frames)
  "Interleave FRAMES (each a list (left right)) into a flat list."
  (loop for (l r) in frames collect l collect r))

(defun %buffer (rate channels samples)
  (audio:make-pcm-buffer :sample-rate rate :channels channels :samples samples))

;;; --- a fake CDP peer for recordings ----------------------------------------

(defclass fake-peer ()
  ((lock :initform (bt2:make-lock :name "fake peer") :reader peer-lock)
   (ready :initform (bt2:make-condition-variable :name "fake peer") :reader peer-ready)
   (queue :initform '() :accessor peer-queue)
   (sent :initform '() :accessor %peer-sent :documentation "Newest first.")
   (closed :initform nil :accessor peer-closed)
   (stop-epoch-ms :initarg :stop-epoch-ms :initform 1002250 :accessor peer-stop-epoch-ms)
   (script-id :initform "7" :accessor peer-script-id)
   (failing :initarg :failing :initform '() :accessor peer-failing
            :documentation "Methods answered with a CDP error.")
   (reply-hook :initarg :reply-hook :initform nil :accessor peer-reply-hook
               :documentation "NIL or (lambda (peer command)) called before the reply.")))

(defun peer-push (peer &rest messages)
  "Queue MESSAGES (hash-tables) for the backend to read."
  (bt2:with-lock-held ((peer-lock peer))
    (setf (peer-queue peer) (append (peer-queue peer) messages))
    (bt2:condition-broadcast (peer-ready peer))))

(defun peer-close (peer)
  (bt2:with-lock-held ((peer-lock peer))
    (setf (peer-closed peer) t)
    (bt2:condition-broadcast (peer-ready peer))))

(defun peer-sent (peer &optional method)
  "Commands sent to PEER, oldest first (only METHOD's when given)."
  (let ((all (bt2:with-lock-held ((peer-lock peer)) (reverse (%peer-sent peer)))))
    (if method
        (remove-if-not (lambda (c) (equal method (gethash "method" c))) all)
        all)))

(defun peer-methods (peer)
  (mapcar (lambda (c) (gethash "method" c)) (peer-sent peer)))

(defun %peer-reply (peer command)
  (let ((id (gethash "id" command))
        (method (gethash "method" command)))
    (cond
      ((member method (peer-failing peer) :test #'equal)
       (%h "id" id "error" (%h "code" -32000 "message" (format nil "~a failed" method))))
      ((equal method "Page.addScriptToEvaluateOnNewDocument")
       (%h "id" id "result" (%h "identifier" (peer-script-id peer))))
      ((equal method "Runtime.evaluate")
       (%h "id" id "result" (%h "result" (%h "type" "number"
                                            "value" (peer-stop-epoch-ms peer)))))
      (t (%h "id" id "result" (%h))))))

(defun fake-recording-backend (&optional (peer (make-instance 'fake-peer)))
  "A CDP backend wired to PEER: RECV-FN waits (like a socket) for a message,
   honouring *CDP-RECEIVE-TIMEOUT*, and returns NIL once PEER is closed and
   empty. Every command is answered at once. -> (values backend peer)."
  (values
   (bp:make-cdp-browser-backend
    :timeout 5
    :send-fn (lambda (cmd)
               (let ((command (bp:decode-cdp-message cmd)))
                 (bt2:with-lock-held ((peer-lock peer))
                   (push command (%peer-sent peer)))
                 (when (peer-closed peer)
                   (error 'bp:browser-disconnected :message "fake peer closed"))
                 (when (peer-reply-hook peer)
                   (funcall (peer-reply-hook peer) peer command))
                 (peer-push peer (%peer-reply peer command))))
    :recv-fn (lambda ()
               (let* ((limit (or bp:*cdp-receive-timeout* 30))
                      (deadline (+ (get-internal-real-time)
                                   (round (* limit internal-time-units-per-second)))))
                 (bt2:with-lock-held ((peer-lock peer))
                   (loop
                     (when (peer-queue peer)
                       (return (pop (peer-queue peer))))
                     (when (peer-closed peer)
                       (return nil))
                     (let ((left (/ (- deadline (get-internal-real-time))
                                    internal-time-units-per-second)))
                       (when (<= left 0)
                         (error 'bp:browser-timeout :limit limit
                                                    :message "fake peer: nothing pending"))
                       (bt2:condition-wait (peer-ready peer) (peer-lock peer)
                                           :timeout (float left 1d0))))))))
   peer))

(defun frame-event (timestamp octets &key (session-id 1) (data nil data-p))
  "A Page.screencastFrame event carrying OCTETS (or DATA, a string, as given)."
  (%event "Page.screencastFrame"
          "data" (if data-p data (%b64 octets))
          "metadata" (%h "timestamp" timestamp "deviceWidth" 800 "deviceHeight" 600
                         "pageScaleFactor" 1 "offsetTop" 0
                         "scrollOffsetX" 0 "scrollOffsetY" 0)
          "sessionId" session-id))

(defun binding-event (payload &key (name rec:+audio-binding-name+))
  (%event "Runtime.bindingCalled" "name" name "payload" payload "executionContextId" 1))

(defparameter +jpeg-a+ (%octets #xFF #xD8 #xFF #xE0 1 2 3 #xFF #xD9))
(defparameter +jpeg-b+ (%octets #xFF #xD8 #xFF #xE0 4 5 6 7 #xFF #xD9))

(defmacro with-fake-recording ((recording peer &rest options) &body body)
  "Bind RECORDING to a recording of a fake backend (PEER its peer) around BODY;
   stop it if still active and discard it on the way out."
  (let ((backend (gensym "BACKEND")))
    `(multiple-value-bind (,backend ,peer) (fake-recording-backend)
       (declare (ignorable ,peer))
       (let ((,recording (rec:start-recording ,backend ,@options)))
         (unwind-protect (progn ,@body)
           (when (rec:recording-active-p ,recording)
             (ignore-errors (rec:stop-recording ,recording)))
           (ignore-errors (rec:discard-recording ,recording)))))))

(defun %frames-arrived (recording n)
  "Wait until RECORDING has N frames; -> true when it has."
  (%wait-until (lambda () (>= (length (rec:recording-frames recording)) n))))

(defmacro with-made-recording ((recording &rest options) &body body)
  "Bind RECORDING to (MAKE-RECORDING ,@OPTIONS) around BODY, then remove its
   directory (a temporary one) without DISCARD-RECORDING."
  `(let ((,recording (rec:make-recording ,@options)))
     (unwind-protect (progn ,@body)
       (unless (getf (list ,@options) :directory)
         (%remove-directory (rec:recording-directory ,recording))))))
