;;;; Recording a page: the CDP side, external clips, the MP4.
;;;;
;;;; (START-RECORDING backend &key directory (audio t) max-width max-height
;;;;   (quality 80)) -> an active RECORDING.
;;;;   BACKEND is a BROWSER-PROTOCOL:CDP-BROWSER-BACKEND (LAUNCH-BROWSER,
;;;;   CONNECT-CDP, MAKE-CDP-BROWSER-BACKEND); anything else signals
;;;;   BROWSER-ERROR. MAX-WIDTH and MAX-HEIGHT are NIL or positive integers,
;;;;   QUALITY an integer 0 .. 100 (else TYPE-ERROR). DIRECTORY as in
;;;;   MAKE-RECORDING. AUDIO true captures page audio (tap.lisp). A page whose
;;;;   AudioContext must not wait for a user gesture runs in a browser started
;;;;   with --autoplay-policy=no-user-gesture-required; that is the caller's
;;;;   launch option, not the recording's.
;;;;   First the two handlers below go on (ON-CDP-EVENT), then these commands,
;;;;   in this order, each a CDP-CALL whose params are string-key hash-tables
;;;;   with CDP's camelCase names:
;;;;     with AUDIO:
;;;;     1. Runtime.enable {}                       (bindingCalled needs it)
;;;;     2. Runtime.addBinding {"name": +AUDIO-BINDING-NAME+}
;;;;     3. Page.addScriptToEvaluateOnNewDocument {"source": (AUDIO-TAP-SCRIPT)}
;;;;        whose reply's "identifier" is kept
;;;;     4. Runtime.evaluate {"expression": (AUDIO-TAP-SCRIPT)} (reply ignored,
;;;;        exceptionDetails included)
;;;;     always:
;;;;     5. Page.startScreencast {"format": "jpeg", "quality": QUALITY,
;;;;        "everyNthFrame": 1}, plus "maxWidth" / "maxHeight" when given
;;;;   A BROWSER-ERROR from any of them removes the handlers, deletes a
;;;;   temporary directory and propagates. Then the recording's reader thread
;;;;   starts. While the recording is active it reads the transport:
;;;;     (wait-for-cdp-event backend <a method no event has>
;;;;                         :timeout *recording-pump-interval*)
;;;;   in a loop: BROWSER-TIMEOUT means look again, BROWSER-DISCONNECTED ends
;;;;   the thread quietly, any other ERROR ends it and is kept for
;;;;   STOP-RECORDING. Events reach the handlers on whichever thread reads
;;;;   them, this one or one running a command, so frames and chunks keep
;;;;   coming while the caller sleeps, and the browser's other events still
;;;;   reach the backend's buffer and handlers as before.
;;;;
;;;;   Page.screencastFrame handler (params "data", "metadata", "sessionId"):
;;;;   1. While the recording is active: "data" decoded from base64 and
;;;;      "metadata" "timestamp" a real give frame n (one more than the frames
;;;;      written so far, from 1): its octets are written to the file
;;;;      "frame-NNNNNN.jpg" (n in decimal, six digits, zero-padded) in
;;;;      RECORDING-DIRECTORY, superseding, and a RECORDING-FRAME (that
;;;;      timestamp, pathname and index n) is added. Bad base64 or no real
;;;;      timestamp: a RECORDING-WARNING, nothing written, n not used.
;;;;   2. Then Page.screencastFrameAck {"sessionId": the params' "sessionId"},
;;;;      for every frame, kept or not: the browser sends the next frame once
;;;;      this one is acked. Acking after keeping it means frames are numbered
;;;;      in arrival order even when the ack's wait reads the next frame (the
;;;;      handler runs again inside it).
;;;;   3. The event leaves the backend's event buffer, so frames are not kept
;;;;      twice.
;;;;   Runtime.bindingCalled handler: when params "name" is
;;;;   +AUDIO-BINDING-NAME+ and the recording is active, (PARSE-AUDIO-CHUNK
;;;;   payload) then ADD-AUDIO-CHUNK; a BROWSER-ERROR from parsing is a
;;;;   RECORDING-WARNING with its text, and the chunk is dropped. Those events
;;;;   leave the buffer; other bindings' events stay in it. (Page scripts can
;;;;   call the binding too: what they send is taken like the tap's.)
;;;;
;;;; (STOP-RECORDING recording) -> RECORDING.
;;;;   Not active: RECORDING-STOPPED inside a CONTINUE restart, which returns
;;;;   RECORDING. Otherwise, in this order, each CDP-CALL best effort (a
;;;;   BROWSER-ERROR is ignored; after a BROWSER-DISCONNECTED the remaining
;;;;   calls are skipped), the recording staying active (frames still taken)
;;;;   until step 4:
;;;;   1. Page.stopScreencast {}
;;;;   2. Runtime.evaluate {"expression": E, "returnByValue": true}, E calling
;;;;      window[+AUDIO-TAP-GLOBAL+].stop() when AUDIO and the global exists,
;;;;      else evaluating performance.timeOrigin + performance.now(). A number
;;;;      v in the reply's result "value" gives RECORDING-STOP-TIME
;;;;      (/ (rational v) 1000); else it stays NIL. With AUDIO this reply also
;;;;      means every chunk the page sent before stop() was read: CDP keeps
;;;;      their order.
;;;;   3. With AUDIO: Runtime.removeBinding {"name": +AUDIO-BINDING-NAME+},
;;;;      then Page.removeScriptToEvaluateOnNewDocument {"identifier": the kept
;;;;      identifier} when there is one. Runtime is not disabled.
;;;;   4. The handlers come off (OFF-CDP-EVENT), the recording stops being
;;;;      active, and the reader thread is joined.
;;;;   Then, when the reader thread ended with an error, RECORDING-ERROR
;;;;   (RECORDING, and that condition as CAUSE). Frames, tracks and clips
;;;;   received so far are kept in every case.
;;;;
;;;; (ADD-AUDIO-FILE recording pathname &key at epoch) -> the new AUDIO-CLIP.
;;;;   Reads the WAV now with AUDIO-PROTOCOL:READ-WAV (its conditions, and the
;;;;   file system's, reach the caller). AT: seconds on the recording's clock
;;;;   (a real; negative cuts the clip's start). EPOCH: seconds since 1970 on
;;;;   the browser's clock, for a moment the page reported (the file a fake
;;;;   microphone, --use-file-for-fake-audio-capture, starts to play when the
;;;;   page's getUserMedia track starts). Neither: AT 0. Both: RECORDING-ERROR.
;;;;   Not reals: TYPE-ERROR. The clip goes after the others; the recording
;;;;   may be active or not.
;;;;
;;;; (WRITE-VIDEO recording output &key (fps +default-fps+) tail
;;;;   (sample-rate +default-sample-rate+)) -> (MERGE-PATHNAMES output), or NIL
;;;;   (the CONTINUE restart below).
;;;;   1. An active RECORDING is stopped first (STOP-RECORDING).
;;;;   2. FRAMES = (RECORDING-FRAMES recording). None: RECORDING-NO-FRAMES
;;;;      (:RECORDING) inside the restarts USE-VALUE frames (a list of
;;;;      RECORDING-FRAMEs to write instead, checked again) and CONTINUE (write
;;;;      nothing, return NIL).
;;;;   3. TAIL, when NIL: (max 0 (- stop last)) with stop = RECORDING-STOP-TIME
;;;;      and last = the largest frame timestamp, as rationals, so the last
;;;;      frame lasts until the recording stopped; 0 without a stop time.
;;;;   4. (VIDEO-SCHEDULE frames :fps fps :tail tail) gives N slots;
;;;;      (FFCONCAT-TEXT frames :fps fps :tail tail) is written to
;;;;      "video.ffconcat" in RECORDING-DIRECTORY (superseding).
;;;;   5. (MIX-RECORDING recording :sample-rate sample-rate :frames A :start T0)
;;;;      with A = (AUDIO-PROTOCOL:SECONDS-TO-FRAME (/ N fps) sample-rate) and
;;;;      T0 the smallest timestamp of FRAMES. A buffer is written with
;;;;      AUDIO-PROTOCOL:WRITE-WAV (:pcm16, superseding) to "audio.wav" in
;;;;      RECORDING-DIRECTORY. NIL (no track, no clip): no audio stream at all,
;;;;      not a silent one.
;;;;   6. OUTPUT's directories are created; (RUN-FFMPEG (FFMPEG-ARGUMENTS
;;;;      concat-file output :fps fps :slots N :audio-file wav-or-NIL)).
;;;;   So the video lasts N / FPS seconds and the audio exactly as long, its
;;;;   frame 0 at the first frame's time. Conditions from MIX-RECORDING,
;;;;   WRITE-WAV and RUN-FFMPEG (with its restarts) reach the caller.
;;;;
;;;; (DISCARD-RECORDING recording) -> T. Stops an active recording first; then
;;;;   deletes RECORDING-DIRECTORY with everything in it when the recording
;;;;   made it (START-RECORDING or MAKE-RECORDING without :DIRECTORY), and leaves
;;;;   a directory the caller gave alone.
;;;;
;;;; (WITH-RECORDING (var backend &rest options) &body body) binds VAR to
;;;;   (START-RECORDING backend ,@options) around BODY and stops it on the way
;;;;   out, normal or not, unless BODY stopped it already. -> BODY's values.
;;;;   Given in the contract.

(in-package #:browser-protocol/record)

(defparameter +pump-method+ "BrowserProtocolRecord.pump"
  "The method the reader thread waits for: no CDP event has it, so the wait
only reads the transport.")

(defun %cdp-params (&rest keys-and-values)
  "A fresh string-key hash-table of KEYS-AND-VALUES, every value kept."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (key value) on keys-and-values by #'cddr
          do (setf (gethash key h) value))
    h))

(defun %take-from-buffer (backend method params)
  "Remove the buffered METHOD event whose params are PARAMS (the very object
the handler got), so the recording's events are not kept twice."
  (browser-protocol::%cdp-take-event backend method (lambda (p) (eq p params))))

(defun %frame-octets (params)
  "(values octets timestamp) of a Page.screencastFrame's PARAMS, or (values
NIL NIL reason) when the frame cannot be kept."
  (let* ((data (gethash "data" params))
         (metadata (gethash "metadata" params))
         (timestamp (and (hash-table-p metadata) (gethash "timestamp" metadata)))
         (octets (and (stringp data)
                      (handler-case (encoding-protocol:decode data :encoding :base64)
                        (encoding-protocol:encoding-error () nil)))))
    (cond ((null octets)
           (values nil nil "a screencast frame whose data is not base64"))
          ((not (realp timestamp))
           (values nil nil "a screencast frame without a metadata timestamp"))
          (t (values octets timestamp nil)))))

(defun %frame-handler (recording backend)
  "The Page.screencastFrame handler: keep the frame (file header), then ack it."
  (lambda (params)
    (%take-from-buffer backend "Page.screencastFrame" params)
    (when (recording-active-p recording)
      (multiple-value-bind (octets timestamp reason) (%frame-octets params)
        (if reason
            (%recording-warn recording reason)
            ;; Number, write and keep in one step, so numbers follow arrival
            ;; order whichever thread reads; the ack (which may read the next
            ;; frame, running this handler again) comes after, unlocked.
            (%with-recording-lock (recording)
              (when (eq (%recording-state recording) :recording)
                (let* ((n (1+ (%recording-frame-count recording)))
                       (path (merge-pathnames (format nil "frame-~6,'0d.jpg" n)
                                              (recording-directory recording))))
                  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                            :if-exists :supersede :if-does-not-exist :create)
                    (write-sequence octets out))
                  (setf (%recording-frame-count recording) n)
                  (push (make-recording-frame :timestamp timestamp :pathname path :index n)
                        (%recording-frames recording))))))))
    (browser-protocol:cdp-call backend "Page.screencastFrameAck"
                               (%cdp-params "sessionId" (gethash "sessionId" params)))))

(defun %binding-handler (recording backend)
  "The Runtime.bindingCalled handler: the tap's chunks (file header)."
  (lambda (params)
    (when (equal +audio-binding-name+ (gethash "name" params))
      (%take-from-buffer backend "Runtime.bindingCalled" params)
      (let* ((p (gethash "payload" params))
             (cut (and (stringp p) (search ",\"pcm\"" p))))
        (when cut
          (format *error-output* "~&BR1DIAG ~a ~a~%"
                  (get-internal-real-time) (subseq p 0 cut))
          (finish-output *error-output*)))
      (when (recording-active-p recording)
        (let ((chunk (handler-case (parse-audio-chunk (gethash "payload" params))
                       (browser-protocol:browser-error (c)
                         (%recording-warn recording
                                          (format nil "an audio payload (~a)"
                                                  (or (browser-protocol:browser-error-message c) c)))
                         nil))))
          (when chunk
            (add-audio-chunk recording chunk)))))))

(defun %pump (recording backend interval)
  "The reader thread: read the transport while RECORDING is active (file header)."
  (handler-case
      (loop while (recording-active-p recording)
            do (handler-case
                   (browser-protocol:wait-for-cdp-event backend +pump-method+ :timeout interval)
                 (browser-protocol:browser-timeout () nil)))
    ;; Before ERROR: a disconnect is a BROWSER-ERROR too.
    (browser-protocol:browser-disconnected () nil)
    (error (c)
      (%with-recording-lock (recording)
        (setf (%recording-pump-condition recording) c)))))

(defun %detach (recording)
  "Step 4 of STOP-RECORDING: the handlers off, the recording not active, the
reader thread joined (unless this is it)."
  (let ((backend (recording-backend recording))
        (handlers (%with-recording-lock (recording)
                    (shiftf (%recording-handlers recording) '()))))
    (loop for (method . handler) in handlers
          do (browser-protocol:off-cdp-event backend method handler)))
  (let ((pump (%with-recording-lock (recording)
                (setf (%recording-state recording) :stopped)
                (shiftf (%recording-pump recording) nil))))
    (when (and pump (not (eq pump (bt2:current-thread))))
      (handler-case (bt2:join-thread pump)
        (bt2:abnormal-exit (c)
          (%with-recording-lock (recording)
            (unless (%recording-pump-condition recording)
              (setf (%recording-pump-condition recording) c))))))))

(defun start-recording (backend &key directory (audio t) max-width max-height (quality 80))
  "Start recording BACKEND's page: screencast frames and page audio (file header)."
  (unless (typep backend 'browser-protocol:cdp-browser-backend)
    (error 'browser-protocol:browser-error
           :message (format nil "START-RECORDING needs a CDP backend, not ~s" (type-of backend))))
  (check-type max-width (or null (integer 1)))
  (check-type max-height (or null (integer 1)))
  (check-type quality (integer 0 100))
  (multiple-value-bind (dir temporary-p) (%recording-directory-for directory)
    (let ((recording (make-instance 'recording :backend backend :directory dir
                                               :temporary-p temporary-p :audio-p (and audio t)
                                               :max-width max-width :max-height max-height
                                               :quality quality :state :recording))
          (started nil))
      (unwind-protect
           (progn
             (let ((handlers (list (cons "Page.screencastFrame" (%frame-handler recording backend))
                                   (cons "Runtime.bindingCalled" (%binding-handler recording backend)))))
               (%with-recording-lock (recording)
                 (setf (%recording-handlers recording) handlers))
               (loop for (method . handler) in handlers
                     do (browser-protocol:on-cdp-event backend method handler)))
             (when audio
               (browser-protocol:cdp-call backend "Runtime.enable" (%cdp-params))
               (browser-protocol:cdp-call backend "Runtime.addBinding"
                                          (%cdp-params "name" +audio-binding-name+))
               (let* ((reply (browser-protocol:cdp-call backend "Page.addScriptToEvaluateOnNewDocument"
                                                        (%cdp-params "source" (audio-tap-script))))
                      (identifier (and (hash-table-p reply) (gethash "identifier" reply))))
                 (%with-recording-lock (recording)
                   (setf (%recording-script-identifier recording) identifier)))
               (browser-protocol:cdp-call backend "Runtime.evaluate"
                                          (%cdp-params "expression" (audio-tap-script))))
             (let ((screencast (%cdp-params "format" "jpeg" "quality" quality "everyNthFrame" 1)))
               (when max-width (setf (gethash "maxWidth" screencast) max-width))
               (when max-height (setf (gethash "maxHeight" screencast) max-height))
               (browser-protocol:cdp-call backend "Page.startScreencast" screencast))
             ;; A bt2 thread sees global values only: pass the interval in.
             (let ((interval *recording-pump-interval*))
               (%with-recording-lock (recording)
                 (setf (%recording-pump recording)
                       (bt2:make-thread (lambda () (%pump recording backend interval))
                                        :name "browser-protocol recording"))))
             (setf started t))
        (unless started
          (%detach recording)
          (when temporary-p
            (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
      recording)))

(defun %stop-expression (audio)
  "The Runtime.evaluate expression of STOP-RECORDING's step 2."
  (if audio
      (concatenate 'string
                   "(function () { var g = window['" +audio-tap-global+ "']; "
                   "return (g && typeof g.stop === 'function') ? g.stop() : "
                   "performance.timeOrigin + performance.now(); })()")
      "performance.timeOrigin + performance.now()"))

(defun %stop-page (recording)
  "Steps 1 to 3 of STOP-RECORDING, each best effort."
  (let ((backend (recording-backend recording))
        (audio (recording-audio-p recording)))
    (block steps
      (flet ((call (method params)
               (handler-case (browser-protocol:cdp-call backend method params)
                 ;; The browser went away: skip the remaining calls.
                 (browser-protocol:browser-disconnected () (return-from steps))
                 (browser-protocol:browser-error () nil))))
        (call "Page.stopScreencast" (%cdp-params))
        (let* ((reply (call "Runtime.evaluate"
                            (%cdp-params "expression" (%stop-expression audio) "returnByValue" t)))
               (result (and (hash-table-p reply) (gethash "result" reply)))
               (value (and (hash-table-p result) (gethash "value" result))))
          (when (realp value)
            (%with-recording-lock (recording)
              (setf (%recording-stop-time recording) (/ (rational value) 1000)))))
        (when audio
          (call "Runtime.removeBinding" (%cdp-params "name" +audio-binding-name+))
          (let ((identifier (%with-recording-lock (recording)
                              (%recording-script-identifier recording))))
            (when identifier
              (call "Page.removeScriptToEvaluateOnNewDocument"
                    (%cdp-params "identifier" identifier)))))))))

(defun stop-recording (recording)
  "Stop RECORDING: screencast, audio tap, reader thread (file header)."
  (check-type recording recording)
  (unless (recording-active-p recording)
    (restart-case (error 'recording-stopped :recording recording)
      (continue ()
        :report "Return the recording unchanged."
        (return-from stop-recording recording))))
  (unwind-protect (%stop-page recording)
    (%detach recording))
  (let ((condition (%with-recording-lock (recording)
                     (%recording-pump-condition recording))))
    (when condition
      (error 'recording-error
             :recording recording :cause condition
             :message (format nil "the recording's reader thread failed: ~a" condition))))
  recording)

(defun add-audio-file (recording pathname &key at epoch)
  "Put a WAV file on RECORDING's clock (file header)."
  (check-type recording recording)
  (check-type at (or null real))
  (check-type epoch (or null real))
  (when (and at epoch)
    (error 'recording-error :recording recording
                            :message "ADD-AUDIO-FILE takes :AT or :EPOCH, not both"))
  (let* ((buffer (values (audio-protocol:read-wav pathname)))
         (clip (make-audio-clip :pathname pathname :buffer buffer
                                :at (if (or at epoch) at 0) :epoch epoch)))
    (%with-recording-lock (recording)
      (push clip (%recording-clips recording)))
    clip))

(defun %frames-to-write (recording)
  "RECORDING's frames, or the frames a USE-VALUE gave for none (WRITE-VIDEO
step 2). CONTINUE returns from WRITE-VIDEO with NIL."
  (let ((frames (recording-frames recording)))
    (loop
      (when frames
        (return frames))
      (restart-case (error 'recording-no-frames :recording recording)
        (use-value (replacement)
          :report "Write these RECORDING-FRAMEs instead."
          :interactive (lambda ()
                         (format *query-io* "A list of RECORDING-FRAMEs: ")
                         (force-output *query-io*)
                         (list (read *query-io*)))
          (unless (and (listp replacement) (every #'recording-frame-p replacement))
            (error 'type-error :datum replacement :expected-type 'list))
          (setf frames replacement))
        (continue ()
          :report "Write nothing: WRITE-VIDEO returns NIL."
          (return nil))))))

(defun write-video (recording output &key (fps +default-fps+) tail
                                          (sample-rate +default-sample-rate+))
  "Write RECORDING as one MP4: H.264 frames and, when there is audio, AAC (file header)."
  (check-type recording recording)
  (check-type fps (integer 1))
  (check-type tail (or null (real 0)))
  (check-type sample-rate (integer 1))
  (when (recording-active-p recording)
    (stop-recording recording))
  (let ((frames (%frames-to-write recording)))
    (unless frames
      (return-from write-video nil))
    (let* ((directory (recording-directory recording))
           (t0 (reduce #'min frames :key #'%frame-time))
           (last (reduce #'max frames :key #'%frame-time))
           (stop (recording-stop-time recording))
           (tail (cond (tail (rational tail))
                       (stop (max 0 (- (rational stop) last)))
                       (t 0)))
           (slots (nth-value 1 (video-schedule frames :fps fps :tail tail)))
           (concat (merge-pathnames "video.ffconcat" directory))
           (wav (merge-pathnames "audio.wav" directory)))
      (with-open-file (s concat :direction :output :if-exists :supersede
                                :if-does-not-exist :create :external-format :utf-8)
        (write-string (ffconcat-text frames :fps fps :tail tail) s))
      (let ((mix (mix-recording recording
                                :sample-rate sample-rate :start t0
                                :frames (audio-protocol:seconds-to-frame (/ slots fps) sample-rate))))
        (when mix
          (audio-protocol:write-wav mix wav :encoding :pcm16 :if-exists :supersede))
        (ensure-directories-exist (merge-pathnames (merge-pathnames output) (uiop:getcwd)))
        (run-ffmpeg (ffmpeg-arguments concat output :fps fps :slots slots
                                                     :audio-file (and mix wav)))
        (merge-pathnames output)))))

(defun discard-recording (recording)
  "Stop RECORDING and delete the directory it made (file header)."
  (check-type recording recording)
  (unwind-protect
       (when (recording-active-p recording)
         (stop-recording recording))
    (when (%recording-temporary-p recording)
      (uiop:delete-directory-tree (recording-directory recording)
                                  :validate t :if-does-not-exist :ignore)))
  t)

(defmacro with-recording ((var backend &rest options) &body body)
  "Bind VAR to (START-RECORDING BACKEND ,@OPTIONS) around BODY; stop it on the way out."
  `(let ((,var (start-recording ,backend ,@options)))
     (unwind-protect (progn ,@body)
       (when (recording-active-p ,var)
         (stop-recording ,var)))))
