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

(defun start-recording (backend &key directory (audio t) max-width max-height (quality 80))
  "Start recording BACKEND's page: screencast frames and page audio (file header)."
  (declare (ignore backend directory audio max-width max-height quality))
  (%br1-pending 'start-recording))

(defun stop-recording (recording)
  "Stop RECORDING: screencast, audio tap, reader thread (file header)."
  (declare (ignore recording))
  (%br1-pending 'stop-recording))

(defun add-audio-file (recording pathname &key at epoch)
  "Put a WAV file on RECORDING's clock (file header)."
  (declare (ignore recording pathname at epoch))
  (%br1-pending 'add-audio-file))

(defun write-video (recording output &key (fps +default-fps+) tail
                                          (sample-rate +default-sample-rate+))
  "Write RECORDING as one MP4: H.264 frames and, when there is audio, AAC (file header)."
  (declare (ignore recording output fps tail sample-rate))
  (%br1-pending 'write-video))

(defun discard-recording (recording)
  "Stop RECORDING and delete the directory it made (file header)."
  (declare (ignore recording))
  (%br1-pending 'discard-recording))

(defmacro with-recording ((var backend &rest options) &body body)
  "Bind VAR to (START-RECORDING BACKEND ,@OPTIONS) around BODY; stop it on the way out."
  `(let ((,var (start-recording ,backend ,@options)))
     (unwind-protect (progn ,@body)
       (when (recording-active-p ,var)
         (stop-recording ,var)))))
