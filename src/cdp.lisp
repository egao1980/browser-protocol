(in-package #:browser-protocol)

;;; CDP JSON: {id, method, params} / {id, result|error}.
;;; cdp-browser-backend talks through SEND-FN / RECV-FN so tests need no Chromium.

(defun encode-cdp-command (id method &optional params)
  "Return a CDP command object (hash-table with string keys id/method/params)."
  (check-type id integer)
  (let ((h (%ht "id" id
                "method" (if (stringp method)
                             method
                             (substitute #\. #\- (string method))))))
    (when params
      (setf (gethash "params" h) (%as-json-object params)))
    h))

(defun decode-cdp-message (message)
  "Accept a hash-table, plist, or JSON string → hash-table."
  (cond
    ((hash-table-p message) message)
    ((stringp message) (%decode-json-string message))
    ((and (consp message) (keywordp (car message))) (%plist-to-ht message))
    ((null message) (%ht))
    (t (error 'browser-error
              :message (format nil "not a CDP message: ~s" (type-of message))))))

(defun cdp-message-id (message)
  (%jget (decode-cdp-message message) "id"))

(defun cdp-message-method (message)
  (%jget (decode-cdp-message message) "method"))

(defun cdp-message-params (message)
  (%jget (decode-cdp-message message) "params"))

(defun cdp-message-param (message key)
  (%jget (cdp-message-params message) key))

(defun cdp-message-result (message)
  (%jget (decode-cdp-message message) "result"))

(defun cdp-message-error (message)
  (%jget (decode-cdp-message message) "error"))

;;; --- octets: screenshot / PDF data is base64 (encoding-protocol) -------------

(defun %usb8 (seq)
  (coerce seq '(simple-array (unsigned-byte 8) (*))))

(defun %octets-from-b64 (value)
  (cond
   ((null value) (make-array 0 :element-type '(unsigned-byte 8)))
   ((and (vectorp value) (not (stringp value))) (%usb8 value))
   ((stringp value)
    (handler-case (%usb8 (encoding-protocol:decode value :encoding :base64))
      (encoding-protocol:encoding-error (c)
        (error 'browser-error
               :message (format nil "bad base64 from the browser: ~a" c)
               :cause c))))
   (t (error 'browser-error
             :message (format nil "not base64/octets: ~s" (type-of value))))))

(defun %js-string (value)
  (with-output-to-string (s)
    (write-char #\' s)
    (loop for ch across (if (stringp value) value (princ-to-string value))
          do (case ch
               (#\\ (write-string "\\\\" s))
               (#\' (write-string "\\'" s))
               (#\Newline (write-string "\\n" s))
               (#\Return (write-string "\\r" s))
               (t (write-char ch s))))
    (write-char #\' s)))

;;; --- CDP backend -----------------------------------------------------------

(defclass cdp-browser-backend (browser-backend)
  ((send-fn :initarg :send-fn :accessor cdp-send-fn :initform nil)
   (recv-fn :initarg :recv-fn :accessor cdp-recv-fn :initform nil)
   (next-id :initarg :next-id :accessor cdp-next-id :initform 0)
   (session-id :initarg :session-id :accessor cdp-session-id :initform nil)
   (ws-url :initarg :ws-url :accessor cdp-ws-url :initform nil)
   (connected-p :initarg :connected-p :accessor cdp-connected-p :initform nil)
   (targets :initarg :targets :accessor cdp-targets :initform nil)
   (timeout :initarg :timeout :accessor cdp-timeout :initform 30
            :documentation "Seconds a command (or NAVIGATE's wait) may take.")
   (events :initform '() :accessor %cdp-events
           :documentation "Events read so far, oldest first (at most
            *CDP-EVENT-BUFFER-LIMIT*). Replaced, never modified in place.")
   (handlers :initform (make-hash-table :test 'equal) :accessor %cdp-handlers
             :documentation "Event method → list of ON-CDP-EVENT handlers.")
   (page-enabled-p :initform nil :accessor %cdp-page-enabled-p)
   (replies :initform (make-hash-table) :reader %cdp-replies
            :documentation "Id → :WAITING, or its reply, for each command in flight.")
   (reader :initform nil :accessor %cdp-reader
           :documentation "The thread inside RECV-FN, or NIL.")
   (generation :initform 0 :accessor %cdp-generation
               :documentation "Counts messages filed and reads ended, so a
                waiter sees whether anything changed since it looked.")
   (lock :initform (bt2:make-lock :name "browser-protocol cdp") :reader %cdp-lock
         :documentation "Guards the slots above. Never held while RECV-FN,
          SEND-FN, a handler or a TEST runs.")
   (filed :initform (bt2:make-condition-variable :name "browser-protocol cdp filed")
          :reader %cdp-filed
          :documentation "Notified when the reading thread files a message.")
   (send-lock :initform (bt2:make-lock :name "browser-protocol cdp send")
              :reader %cdp-send-lock
              :documentation "One SEND-FN call at a time."))
  (:documentation
   "Builds CDP commands and exchanges them via SEND-FN / RECV-FN.
    SEND-FN is called with a command hash-table; RECV-FN returns the next
    message (hash-table, plist or JSON text) and should give up after
    *CDP-RECEIVE-TIMEOUT* seconds with BROWSER-TIMEOUT. One thread at a time
    calls RECV-FN, and it files what it reads: a reply goes to the command
    waiting for its id, an event to the ON-CDP-EVENT handlers and a bounded
    buffer that WAIT-FOR-CDP-EVENT reads. So commands sent from a handler,
    or from several threads, each get their own reply, and no wait misses
    an event that another command read."))

(defun cdp-browser-backend-p (object)
  (typep object 'cdp-browser-backend))

(defun make-cdp-browser-backend (&key send-fn recv-fn compute-backend
                                      sandbox-spec ws-url session-id (timeout 30))
  (make-instance 'cdp-browser-backend
                 :send-fn send-fn
                 :recv-fn recv-fn
                 :compute-backend compute-backend
                 :sandbox-spec sandbox-spec
                 :ws-url ws-url
                 :session-id session-id
                 :timeout timeout))

(defun use-cdp-browser-backend (&rest args &key &allow-other-keys)
  (setf *browser-backend* (apply #'make-cdp-browser-backend args)))

(defun %cdp-ensure-io (backend)
  (unless (and (cdp-send-fn backend) (cdp-recv-fn backend))
    (error 'browser-disconnected
           :message "CDP send-fn/recv-fn missing — no websocket")))

(defvar *cdp-receive-timeout* nil
  "Seconds left for the RECV-FN call in progress, or NIL for no limit. Bound
   around every RECV-FN call: a transport that can wait with a timeout
   signals BROWSER-TIMEOUT once it passes.")

(defparameter *cdp-event-buffer-limit* 1000
  "Events kept per backend for WAIT-FOR-CDP-EVENT; older ones are dropped.")

(defun %deadline (seconds)
  (and seconds
       (+ (get-internal-real-time)
          (round (* seconds internal-time-units-per-second)))))

(defun %seconds-left (deadline)
  (and deadline
       (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))

(defun %cdp-receive (backend deadline limit what)
  "Next message from RECV-FN as a hash-table. BROWSER-TIMEOUT once DEADLINE
   (LIMIT seconds after the start) passes; BROWSER-DISCONNECTED when RECV-FN
   returns NIL."
  (let ((left (%seconds-left deadline)))
    (when (and left (<= left 0))
      (error 'browser-timeout
             :method what :limit limit
             :message (format nil "nothing for ~a within ~as" what limit)))
    (let ((raw (let ((*cdp-receive-timeout* left))
                 (funcall (cdp-recv-fn backend)))))
      (when (null raw)
        (error 'browser-disconnected
               :method what :message "the CDP transport is closed"))
      (decode-cdp-message raw))))

(defun %cdp-own-session-p (backend message)
  "MESSAGE has no sessionId (browser target, or a page connection) or
   BACKEND's."
  (let ((session (%jget message "sessionId")))
    (or (null session) (equal session (cdp-session-id backend)))))

(defun %cdp-dispatch (backend message)
  "Call the ON-CDP-EVENT handlers of MESSAGE (an event), oldest first, on this
   thread and with no lock held: a handler may send commands and wait."
  (let ((handlers (bt2:with-lock-held ((%cdp-lock backend))
                    (reverse (gethash (cdp-message-method message)
                                      (%cdp-handlers backend)))))
        (params (or (cdp-message-params message) (%ht))))
    (dolist (handler handlers)
      (funcall handler params))))

(defun %cdp-file (backend message)
  "With BACKEND's lock held: keep MESSAGE for whoever waits for it. An event
   goes to the end of the buffer (→ T: dispatch it once the lock is free). A
   reply goes to its command when one waits for that id; else it answers a
   command given up on and is dropped."
  (incf (%cdp-generation backend))
  (cond
   ((cdp-message-method message)
    (let* ((events (append (%cdp-events backend) (list message)))
           (excess (- (length events) *cdp-event-buffer-limit*)))
      (setf (%cdp-events backend)
            (if (plusp excess) (nthcdr excess events) events)))
    t)
   (t
    (let ((id (cdp-message-id message))
          (replies (%cdp-replies backend)))
      (when (and id (eq :waiting (gethash id replies)))
        (setf (gethash id replies) message)))
    nil)))

(defun %cdp-await (backend ready deadline limit what)
  "Call READY (no lock held) until it returns non-NIL; → that value.
   Meanwhile read: one message at a time from RECV-FN, filed (%CDP-FILE) and,
   for an event, dispatched to its handlers. While another thread reads,
   wait until it files something. BROWSER-TIMEOUT once DEADLINE (LIMIT
   seconds after the start) passes."
  (let ((lock (%cdp-lock backend))
        (me (bt2:current-thread)))
    (loop
      (let ((seen (bt2:with-lock-held (lock) (%cdp-generation backend))))
        (let ((value (funcall ready)))
          (when value
            (return value)))
        (let ((read nil) (claimed nil) (late nil))
          (bt2:with-lock-held (lock)
            ;; Something filed since READY looked: look again first.
            (when (= seen (%cdp-generation backend))
              (let ((reader (%cdp-reader backend))
                    (left (%seconds-left deadline)))
                (cond
                 ((null reader)
                  (setf (%cdp-reader backend) me
                        claimed t
                        read t))
                 ;; Our own read is on the stack (a handler of its signal).
                 ((eq reader me) (setf read t))
                 ((and left (<= left 0)) (setf late t))
                 (t (bt2:condition-wait (%cdp-filed backend) lock
                                        :timeout (and left (float left 1d0))))))))
          (when late
            (error 'browser-timeout
                   :method what :limit limit
                   :message (format nil "nothing for ~a within ~as" what limit)))
          (when read
            (let ((message nil)
                  (dispatch nil))
              (unwind-protect
                  (progn
                    (%cdp-ensure-io backend)
                    (setf message (%cdp-receive backend deadline limit what)))
                (bt2:with-lock-held (lock)
                  (when claimed
                    (setf (%cdp-reader backend) nil))
                  (when message
                    (setf dispatch (%cdp-file backend message)))
                  (incf (%cdp-generation backend))
                  (bt2:condition-broadcast (%cdp-filed backend))))
              (when dispatch
                (%cdp-dispatch backend message)))))))))

(defun %cdp-reply-result (message method)
  (let ((err (cdp-message-error message)))
    (when err
      (error 'browser-error
             :method method
             :message (format nil "~a~@[ (~a)~]"
                              (or (%jget err "message") (princ-to-string err))
                              (%jget err "data")))))
  (cdp-message-result message))

(defun %cdp-command (backend method params session-id timeout)
  "Send one command (on SESSION-ID, NIL = the connection's own target) and
   → the result of the reply with its id, whoever reads it (%CDP-AWAIT).
   Its id is in flight until it returns or gives up; a reply after that is
   dropped."
  (%cdp-ensure-io backend)
  (let* ((limit (or timeout (cdp-timeout backend)))
         (deadline (%deadline limit))
         (lock (%cdp-lock backend))
         (replies (%cdp-replies backend))
         (id (bt2:with-lock-held (lock)
               (let ((id (incf (cdp-next-id backend))))
                 (setf (gethash id replies) :waiting)
                 id)))
         (cmd (encode-cdp-command id method params)))
    (when session-id
      (setf (gethash "sessionId" cmd) session-id))
    (unwind-protect
        (progn
          (bt2:with-lock-held ((%cdp-send-lock backend))
            (funcall (cdp-send-fn backend) cmd))
          (%cdp-reply-result
           (%cdp-await backend
                       (lambda ()
                         (bt2:with-lock-held (lock)
                           (let ((reply (gethash id replies)))
                             (and (not (eq reply :waiting)) reply))))
                       deadline limit method)
           method))
      (bt2:with-lock-held (lock)
        (remhash id replies)))))

(defun %cdp-browser-call (backend method &optional params timeout)
  "CDP-CALL on the browser target: no sessionId."
  (%cdp-command backend method params nil timeout))

(defun on-cdp-event (backend method handler)
  "Call HANDLER with the params (hash-table) of every METHOD event BACKEND
   reads. Events are read while a command waits for its reply or
   WAIT-FOR-CDP-EVENT waits; HANDLER runs on the thread that read the event,
   with no lock held, so it may send commands (CDP-CALL) itself: their
   replies, and events they read, still reach the commands and waits they
   belong to. An error from HANDLER propagates from that call. → HANDLER."
  (check-type method string)
  (bt2:with-lock-held ((%cdp-lock backend))
    (push handler (gethash method (%cdp-handlers backend))))
  handler)

(defun off-cdp-event (backend method &optional handler)
  "Remove HANDLER (every handler when NIL) for METHOD events."
  (bt2:with-lock-held ((%cdp-lock backend))
    (if handler
        (setf (gethash method (%cdp-handlers backend))
              (remove handler (gethash method (%cdp-handlers backend))))
        (remhash method (%cdp-handlers backend))))
  nil)

(defun %event-matches-p (backend message method test)
  (and (equal method (cdp-message-method message))
       (%cdp-own-session-p backend message)
       (or (null test)
           (funcall test (or (cdp-message-params message) (%ht))))))

(defun %cdp-forget-events (backend method)
  "Drop buffered METHOD events of BACKEND's session (stale for a new wait)."
  (bt2:with-lock-held ((%cdp-lock backend))
    (setf (%cdp-events backend)
          (remove-if (lambda (m) (%event-matches-p backend m method nil))
                     (%cdp-events backend)))))

(defun %cdp-take-event (backend method test)
  "Remove the oldest buffered METHOD event of BACKEND's session for which
   TEST (if given) is true of the params; → its params, or NIL when there is
   none. TEST runs with no lock held."
  (let ((lock (%cdp-lock backend)))
    (loop
      (let* ((events (bt2:with-lock-held (lock) (%cdp-events backend)))
             (found (find-if (lambda (m) (%event-matches-p backend m method test))
                             events)))
        (unless found
          (return nil))
        ;; Another waiter may have taken it meanwhile: then look again.
        (when (bt2:with-lock-held (lock)
                (when (member found (%cdp-events backend) :test #'eq)
                  (setf (%cdp-events backend)
                        (remove found (%cdp-events backend) :test #'eq :count 1))
                  t))
          (return (or (cdp-message-params found) (%ht))))))))

(defun wait-for-cdp-event (backend method &key test timeout)
  "→ the params of the first METHOD event of BACKEND's session for which
   TEST (if given) is true of the params, taken from the event buffer. Reads
   the transport until one is there (events other commands read count too).
   BROWSER-TIMEOUT after TIMEOUT seconds (default (CDP-TIMEOUT BACKEND))."
  (check-type method string)
  (let* ((limit (or timeout (cdp-timeout backend)))
         (deadline (%deadline limit)))
    (%cdp-await backend
                (lambda () (%cdp-take-event backend method test))
                deadline limit method)))

(defun cdp-call (backend method &optional params)
  "Send METHOD with PARAMS (hash-table, plist or alist) on BACKEND's session.
   → the reply's result (hash-table). Events that arrive first go to the
   ON-CDP-EVENT handlers and the event buffer. A CDP error reply signals
   BROWSER-ERROR; no reply within (CDP-TIMEOUT BACKEND) seconds signals
   BROWSER-TIMEOUT."
  (%cdp-command backend method params (cdp-session-id backend) nil))

(defun %unserializable-value (text)
  "A RemoteObject's unserializableValue: a BigInt (\"12n\") → the integer,
   \"-0\" → -0.0d0, NaN / Infinity / -Infinity → :NAN / :INFINITY /
   :-INFINITY. Anything else stays the string."
  (let ((n (length text)))
    (cond
     ((equal text "NaN") :nan)
     ((equal text "Infinity") :infinity)
     ((equal text "-Infinity") :-infinity)
     ((equal text "-0") -0.0d0)
     ((and (> n 1) (char= #\n (char text (1- n))))
      (multiple-value-bind (value end) (parse-integer text :end (1- n) :junk-allowed t)
        (if (and value (= end (1- n))) value text)))
     (t text))))

(defun %remote-object-value (object)
  "The Lisp value of the CDP RemoteObject OBJECT (Runtime.evaluate with
   returnByValue): its \"value\" as json-protocol decodes it (false is NIL,
   null :NULL, an array a vector, an object a hash-table), NIL for
   undefined, and %UNSERIALIZABLE-VALUE of an unserializableValue. OBJECT
   itself when it carries no value (a function, say)."
  (if (not (hash-table-p object))
      object
      (multiple-value-bind (value present) (gethash "value" object)
        (cond
         (present value)
         ((equal "undefined" (gethash "type" object)) nil)
         ((stringp (gethash "unserializableValue" object))
          (%unserializable-value (gethash "unserializableValue" object)))
         (t object)))))

(defun %exception-text (details)
  "One line for Runtime.evaluate's exceptionDetails."
  (let ((exception (%jget details "exception")))
    (or (and exception (%jget exception "description"))
        (and exception (let ((v (%jget exception "value")))
                         (and v (not (hash-table-p v)) (princ-to-string v))))
        (%jget details "text")
        "exception")))

(defun %evaluate (backend expression)
  "Runtime.evaluate EXPRESSION (returnByValue) on BACKEND's page. → the
   value (%REMOTE-OBJECT-VALUE). A JavaScript exception signals
   BROWSER-ERROR with its text (Playwright's evaluate raises too)."
  (let* ((reply (cdp-call backend "Runtime.evaluate"
                          (%ht "expression" expression "returnByValue" t)))
         (details (%jget reply "exceptionDetails")))
    (when details
      (error 'browser-error
             :method "Runtime.evaluate"
             :message (format nil "JavaScript exception: ~a" (%exception-text details))))
    (%remote-object-value (%jget reply "result"))))

(defun %js-click (selector)
  (format nil "(function(){var e=document.querySelector(~a); if(!e) throw 'no element'; e.click(); return true;})()"
          (%js-string selector)))

(defun %js-type (selector text)
  (format nil "(function(){var e=document.querySelector(~a); if(!e) throw 'no element'; e.focus(); e.value=(e.value||'')+~a; return true;})()"
          (%js-string selector) (%js-string text)))

(defun %js-scroll (selector dx dy)
  (format nil "(function(){var e=~a; e.scrollBy(~a,~a); return true;})()"
          (if selector
              (format nil "document.querySelector(~a)" (%js-string selector))
              "window")
          (or dx 0) (or dy 0)))

(defparameter +navigate-wait-events+
  '((:load . "Page.loadEventFired")
    (:domcontentloaded . "Page.domContentEventFired"))
  "NAVIGATE :wait-until → the Page event that ends the wait.")

(defun %ensure-page-events (backend)
  "Page.enable once per backend: without it Chrome sends no Page events."
  (unless (%cdp-page-enabled-p backend)
    (cdp-call backend "Page.enable")
    (setf (%cdp-page-enabled-p backend) t)))

(defmethod navigate ((backend cdp-browser-backend) url &key (wait-until :load) timeout)
  (let* ((event (cond
                 ((member wait-until '(nil :commit)) nil)
                 ((cdr (assoc wait-until +navigate-wait-events+)))
                 (t (error 'browser-error
                           :url url :method "Page.navigate"
                           :message (format nil "wait-until ~s: want :load, :domcontentloaded or :commit"
                                            wait-until)))))
         (limit (or timeout (cdp-timeout backend)))
         (deadline (%deadline limit)))
    (when event
      (%ensure-page-events backend)
      (%cdp-forget-events backend event))
    (let* ((result (%cdp-command backend "Page.navigate" (%ht "url" url)
                                 (cdp-session-id backend) limit))
           (error-text (%jget result "errorText")))
      (when (and (stringp error-text) (plusp (length error-text)))
        (error 'browser-error
               :url url :method "Page.navigate"
               :message (format nil "navigation to ~a failed: ~a" url error-text)))
      ;; No loaderId: a same-document navigation (#fragment) fires no load event.
      (when (and event (%jget result "loaderId") (not (%jget result "isDownload")))
        (handler-case
            (wait-for-cdp-event backend event
                                :timeout (and deadline (max 0 (%seconds-left deadline))))
          (browser-timeout (c)
            (error 'browser-timeout
                   :url url :method "Page.navigate" :limit limit :cause c
                   :message (format nil "~a: no ~a within ~as" url event limit)))))
      url)))

(defmethod dom-snapshot ((backend cdp-browser-backend))
  (%evaluate backend "document.documentElement.outerHTML"))

(defmethod screenshot ((backend cdp-browser-backend) &key)
  (let ((result (cdp-call backend "Page.captureScreenshot" (%ht))))
    (%octets-from-b64 (%jget result "data"))))

(defmethod click ((backend cdp-browser-backend) &key selector x y)
  (cond
   ;; A missing element throws in the page: BROWSER-ERROR (%EVALUATE).
   (selector (%evaluate backend (%js-click selector)))
   ((and x y)
    (cdp-call backend "Input.dispatchMouseEvent"
              (%ht "type" "mousePressed" "x" x "y" y "button" "left" "clickCount" 1))
    (cdp-call backend "Input.dispatchMouseEvent"
              (%ht "type" "mouseReleased" "x" x "y" y "button" "left" "clickCount" 1)))
   (t (error 'browser-error :message "click needs :selector or :x/:y")))
  t)

(defmethod type-text ((backend cdp-browser-backend) text &key selector x y)
  (when (or selector (and x y))
    (click backend :selector selector :x x :y y))
  (if selector
      (%evaluate backend (%js-type selector text))
      (cdp-call backend "Input.insertText" (%ht "text" text)))
  text)

(defmethod scroll ((backend cdp-browser-backend) &key selector x y dx dy)
  (declare (ignore x y))
  (%evaluate backend (%js-scroll selector (or dx 0) (or dy 0)))
  t)

(defmethod eval-js ((backend cdp-browser-backend) expression)
  ;; false → NIL, undefined → NIL, null → :NULL; a JS exception signals.
  (%evaluate backend expression))

(defmethod print-pdf ((backend cdp-browser-backend) &key)
  (let ((result (cdp-call backend "Page.printToPDF" (%ht))))
    (%octets-from-b64 (%jget result "data"))))

(defmethod connect-browser ((backend cdp-browser-backend) &key url ws-url)
  (when ws-url (setf (cdp-ws-url backend) ws-url))
  (when url
    (setf (cdp-ws-url backend) (or ws-url url)))
  (%cdp-ensure-io backend)
  ;; A browser-target command: Target.* events then reach every session.
  (%cdp-browser-call backend "Target.setDiscoverTargets" (%ht "discover" t))
  (setf (cdp-connected-p backend) t)
  backend)

(defmethod close-browser ((backend cdp-browser-backend))
  (when (and (cdp-send-fn backend) (cdp-recv-fn backend))
    ;; Chrome may close the socket before it replies.
    (handler-case (%cdp-browser-call backend "Browser.close" nil 5)
      (browser-error () nil)))
  (setf (cdp-connected-p backend) nil)
  t)

(defun %coerce-target (item)
  (cond
    ((browser-target-p item) item)
    ((hash-table-p item)
     (make-browser-target :id (%jget item "targetId")
                          :type (or (%jget item "type") "page")
                          :url (%jget item "url")
                          :title (%jget item "title")))
    ((and (consp item) (keywordp (car item)))
     (apply #'make-browser-target item))
    (t (error 'browser-error :message (format nil "not a target: ~s" item)))))

(defmethod list-targets ((backend cdp-browser-backend))
  (let* ((result (%cdp-browser-call backend "Target.getTargets"))
         (raw (or (%jget result "targetInfos")
                  (%jget result "targetInfo")
                  result)))
    (mapcar #'%coerce-target
            (cond
              ((and (vectorp raw) (not (stringp raw))) (coerce raw 'list))
              ((listp raw) raw)
              (t (list raw))))))
