(in-package #:browser-protocol/record/tests)

;;; START-RECORDING, STOP-RECORDING, WITH-RECORDING, DISCARD-RECORDING and
;;; WRITE-VIDEO against a fake CDP peer (support.lisp): the commands and their
;;; order, frames and chunks from events read on the recording's own thread,
;;; the event buffer, best-effort stopping. WRITE-VIDEO runs a stand-in ffmpeg
;;; (a sh script; skipped on Windows).

(defun %params (command)
  (or (gethash "params" command) (%h)))

(defun %param (command key)
  (gethash key (%params command)))

(defun %recording-threads ()
  (remove-if-not (lambda (th)
                   (and (bt2:thread-alive-p th)
                        (equal "browser-protocol recording" (bt2:thread-name th))))
                 (bt2:all-threads)))

(defun %handlers (backend method)
  (gethash method (bp::%cdp-handlers backend)))

(defun %buffered (backend method)
  (remove-if-not (lambda (m) (equal method (gethash "method" m)))
                 (bp::%cdp-events backend)))

(deftest start-recording-sends-the-audio-and-screencast-commands
  (with-fake-recording (r peer)
    (ok (rec:recording-active-p r))
    (ok (rec:recording-audio-p r))
    (ok (equal '("Runtime.enable" "Runtime.addBinding" "Page.addScriptToEvaluateOnNewDocument"
                 "Runtime.evaluate" "Page.startScreencast")
               (peer-methods peer))
        (format nil "~s" (peer-methods peer)))
    (let ((sent (peer-sent peer)))
      (ok (equal rec:+audio-binding-name+ (%param (second sent) "name")))
      (ok (equal (rec:audio-tap-script) (%param (third sent) "source")))
      (ok (equal (rec:audio-tap-script) (%param (fourth sent) "expression")))
      (let ((screencast (%params (fifth sent))))
        (ok (equal "jpeg" (gethash "format" screencast)))
        (ok (eql 80 (gethash "quality" screencast)))
        (ok (eql 1 (gethash "everyNthFrame" screencast)))
        (ok (not (nth-value 1 (gethash "maxWidth" screencast))) "no maxWidth unless given")
        (ok (not (nth-value 1 (gethash "maxHeight" screencast))))))))

(deftest start-recording-screencast-options
  (with-fake-recording (r peer :audio nil :max-width 640 :max-height 480 :quality 55)
    (ok (not (rec:recording-audio-p r)))
    (ok (equal '("Page.startScreencast") (peer-methods peer)) "no audio commands")
    (let ((screencast (%params (first (peer-sent peer)))))
      (ok (eql 640 (gethash "maxWidth" screencast)))
      (ok (eql 480 (gethash "maxHeight" screencast)))
      (ok (eql 55 (gethash "quality" screencast))))))

(deftest start-recording-argument-checks
  (ok (signals (rec:start-recording (bp:make-mock-browser-backend)) 'bp:browser-error)
      "a backend that is not CDP")
  (ok (signals (rec:start-recording nil) 'bp:browser-error))
  (let ((b (fake-recording-backend)))
    (ok (signals (rec:start-recording b :quality 101) 'type-error))
    (ok (signals (rec:start-recording b :max-width 0) 'type-error))
    (ok (signals (rec:start-recording b :max-height 1.5) 'type-error)))
  (ok (null (%recording-threads)) "no reader thread was left behind"))

(deftest start-recording-failure-cleans-up
  (multiple-value-bind (b peer) (fake-recording-backend)
    (setf (peer-failing peer) '("Page.startScreencast"))
    (ok (signals (rec:start-recording b) 'bp:browser-error))
    (ok (null (%handlers b "Page.screencastFrame")) "the frame handler is off again")
    (ok (null (%handlers b "Runtime.bindingCalled")))
    (ok (null (%recording-threads)) "no reader thread")))

(deftest frames-are-written-acked-and-timestamped
  (with-fake-recording (r peer)
    (peer-push peer
               (frame-event 1000.5d0 +jpeg-a+ :session-id 11)
               (frame-event 1000d0 +jpeg-b+ :session-id 12)
               (frame-event 1000.25d0 +jpeg-a+ :session-id 13))
    ;; The test thread only waits: the recording's thread reads.
    (ok (%frames-arrived r 3) "three frames while the caller sleeps")
    (let ((frames (rec:recording-frames r)))
      (ok (equal '(1 2 3) (mapcar #'rec:recording-frame-index frames)))
      (ok (equal '(1000.5d0 1000d0 1000.25d0) (mapcar #'rec:recording-frame-timestamp frames)))
      (ok (equal (list (merge-pathnames "frame-000001.jpg" (rec:recording-directory r))
                       (merge-pathnames "frame-000002.jpg" (rec:recording-directory r))
                       (merge-pathnames "frame-000003.jpg" (rec:recording-directory r)))
                 (mapcar #'rec:recording-frame-pathname frames)))
      (ok (equalp +jpeg-a+ (%read-octets (rec:recording-frame-pathname (first frames)))))
      (ok (equalp +jpeg-b+ (%read-octets (rec:recording-frame-pathname (second frames))))))
    (ok (eql 1000d0 (rec:recording-start-time r)))
    (ok (%wait-until (lambda () (= 3 (length (peer-sent peer "Page.screencastFrameAck"))))))
    (ok (equal '(11 12 13) (mapcar (lambda (c) (%param c "sessionId"))
                                   (peer-sent peer "Page.screencastFrameAck")))
        "every frame acked with its sessionId")
    (ok (null (%buffered (rec:recording-backend r) "Page.screencastFrame"))
        "frames are not kept in the backend's event buffer")))

(deftest frames-read-by-a-command-on-the-caller-thread
  ;; Whoever reads the transport files the frame: here the test thread's own
  ;; CDP-CALL may read it before the recording's thread does.
  (with-fake-recording (r peer :audio nil)
    (peer-push peer (frame-event 1000d0 +jpeg-a+ :session-id 1))
    (bp:cdp-call (rec:recording-backend r) "Runtime.evaluate" (%h "expression" "1"))
    (ok (%frames-arrived r 1))))

(deftest bad-frames-are-dropped-with-a-warning
  (with-fake-recording (r peer :audio nil)
    (peer-push peer
               (frame-event 1000d0 nil :session-id 1 :data "@@@@")
               (%event "Page.screencastFrame" "data" (%b64 +jpeg-a+)
                       "metadata" (%h "deviceWidth" 800) "sessionId" 2)
               (frame-event 1000.5d0 +jpeg-b+ :session-id 3))
    (ok (%frames-arrived r 1))
    (ok (%wait-until (lambda () (= 2 (length (rec:recording-warnings r))))) "two warnings")
    (ok (every (lambda (w) (typep w 'rec:recording-warning)) (rec:recording-warnings r)))
    (let ((frame (first (rec:recording-frames r))))
      (ok (= 1 (length (rec:recording-frames r))))
      (ok (= 1 (rec:recording-frame-index frame)) "dropped frames use no number")
      (ok (equal (merge-pathnames "frame-000001.jpg" (rec:recording-directory r))
                 (rec:recording-frame-pathname frame))))
    (ok (%wait-until (lambda () (= 3 (length (peer-sent peer "Page.screencastFrameAck")))))
        "bad frames are acked too")))

(deftest chunks-come-through-the-binding
  (with-fake-recording (r peer)
    (peer-push peer
               (binding-event (%chunk-payload :track "d/1" :seq 0 :frame 0 :samples (%stereo '(0.5 0.5))))
               (binding-event "{\"v\":1}" :name "someOtherBinding")
               (binding-event (%chunk-payload :track "d/1" :seq 1 :frame 1 :samples (%stereo '(0.25 0.25))))
               (binding-event "not json"))
    (ok (%wait-until (lambda ()
                       (let ((tracks (rec:recording-audio-tracks r)))
                         (and tracks (= 2 (length (rec:audio-track-chunks (first tracks))))))))
        "two chunks in one track")
    (ok (%wait-until (lambda () (= 1 (length (rec:recording-warnings r)))))
        "the malformed payload is a warning")
    (let ((buffered (%buffered (rec:recording-backend r) "Runtime.bindingCalled")))
      (ok (= 1 (length buffered)) "only the other binding's event stays in the buffer")
      (ok (equal "someOtherBinding" (gethash "name" (gethash "params" (first buffered))))))))

(deftest stop-recording-sends-the-stop-commands
  (with-fake-recording (r peer)
    (let ((before (length (peer-sent peer))))
      (ok (eq r (rec:stop-recording r)))
      (let ((stop (nthcdr before (peer-sent peer))))
        (ok (equal '("Page.stopScreencast" "Runtime.evaluate" "Runtime.removeBinding"
                     "Page.removeScriptToEvaluateOnNewDocument")
                   (mapcar (lambda (c) (gethash "method" c)) stop))
            (format nil "~s" (mapcar (lambda (c) (gethash "method" c)) stop)))
        (ok (eq t (%param (second stop) "returnByValue")))
        (ok (search rec:+audio-tap-global+ (%param (second stop) "expression")))
        (ok (equal rec:+audio-binding-name+ (%param (third stop) "name")))
        (ok (equal "7" (%param (fourth stop) "identifier")))))
    (ok (not (rec:recording-active-p r)))
    (ok (= 4009/4 (rec:recording-stop-time r)) "1002250 ms is 1002.25 s")
    (ok (null (%recording-threads)) "the reader thread is joined")
    (ok (null (%handlers (rec:recording-backend r) "Page.screencastFrame")))
    (ok (null (%handlers (rec:recording-backend r) "Runtime.bindingCalled")))
    (ok (not (member "Runtime.disable" (peer-methods peer) :test #'equal)))))

(deftest stop-recording-without-audio
  (with-fake-recording (r peer :audio nil)
    (rec:stop-recording r)
    (ok (equal '("Page.startScreencast" "Page.stopScreencast" "Runtime.evaluate")
               (peer-methods peer)))
    (ok (not (search rec:+audio-tap-global+
                     (%param (third (peer-sent peer)) "expression"))))
    (ok (= 4009/4 (rec:recording-stop-time r)))))

(deftest stop-recording-without-a-stop-time
  (with-fake-recording (r peer :audio nil)
    (setf (peer-stop-epoch-ms peer) :null)
    (rec:stop-recording r)
    (ok (null (rec:recording-stop-time r)))))

(deftest stop-recording-twice
  (with-fake-recording (r peer :audio nil)
    (rec:stop-recording r)
    (let ((count (length (peer-sent peer))))
      (ok (signals (rec:stop-recording r) 'rec:recording-stopped))
      (ok (eq r (handler-bind ((rec:recording-stopped (lambda (c) (continue c))))
                  (rec:stop-recording r))))
      (ok (= count (length (peer-sent peer))) "nothing sent the second time"))))

(deftest frames-after-stop-are-ignored
  (with-fake-recording (r peer :audio nil)
    (peer-push peer (frame-event 1000d0 +jpeg-a+))
    (ok (%frames-arrived r 1))
    (rec:stop-recording r)
    (peer-push peer (frame-event 1001d0 +jpeg-b+))
    (bp:cdp-call (rec:recording-backend r) "Runtime.evaluate" (%h "expression" "1"))
    (ok (= 1 (length (rec:recording-frames r))))))

(deftest stop-recording-is-best-effort
  (with-fake-recording (r peer)
    (setf (peer-failing peer) '("Page.stopScreencast" "Runtime.removeBinding"))
    (ok (eq r (rec:stop-recording r)) "CDP errors are ignored")
    (ok (not (rec:recording-active-p r)))
    (ok (member "Page.removeScriptToEvaluateOnNewDocument" (peer-methods peer) :test #'equal)
        "the later steps still run")))

(deftest stop-recording-after-the-browser-went-away
  (with-fake-recording (r peer :audio nil)
    (peer-push peer (frame-event 1000d0 +jpeg-a+))
    (ok (%frames-arrived r 1))
    (let ((before (length (peer-sent peer))))
      (peer-close peer)
      (ok (eq r (rec:stop-recording r)) "no error")
      (ok (equal '("Page.stopScreencast") (mapcar (lambda (c) (gethash "method" c))
                                                  (nthcdr before (peer-sent peer))))
          "after BROWSER-DISCONNECTED the other steps are skipped"))
    (ok (= 1 (length (rec:recording-frames r))) "frames are kept")
    (ok (null (%recording-threads)))))

(deftest a-reader-thread-error-is-signalled-at-stop
  ;; The frames' directory disappears: writing the next frame fails on the
  ;; recording's thread, which ends; STOP-RECORDING reports it.
  (let ((dir (%scratch-directory "gone")))
   (unwind-protect
    (with-fake-recording (r peer :audio nil :directory dir)
      (%remove-directory dir)
      (peer-push peer (frame-event 1000d0 +jpeg-a+))
      (ok (%wait-until (lambda () (null (%recording-threads)))) "the reader thread ended")
      (handler-case (progn (rec:stop-recording r) (ok nil "no error"))
        (rec:recording-error (c)
          (ok (not (typep c 'rec:recording-stopped)))
          (ok (eq r (rec:recording-error-recording c)))
          (ok (typep (bp:browser-error-cause c) 'file-error)
              (format nil "cause ~s" (bp:browser-error-cause c)))))
      (ok (not (rec:recording-active-p r)) "stopped all the same"))
    (%remove-directory dir))))

(deftest with-recording-stops-on-the-way-out
  (multiple-value-bind (b peer) (fake-recording-backend)
    (let ((saved nil))
      (ok (equal '(1 2) (multiple-value-list
                         (rec:with-recording (r b :audio nil)
                           (setf saved r)
                           (values 1 2))))
          "the body's values")
      (ok (not (rec:recording-active-p saved)))
      (%remove-directory (rec:recording-directory saved))
      (block out
        (rec:with-recording (r b :audio nil)
          (setf saved r)
          (return-from out)))
      (ok (not (rec:recording-active-p saved)) "a non-local exit stops it too")
      (%remove-directory (rec:recording-directory saved))
      (ok (rec:with-recording (r b :audio nil)
            (setf saved r)
            (rec:stop-recording r)
            t)
          "a body that stopped it: no RECORDING-STOPPED")
      (%remove-directory (rec:recording-directory saved))
      (ok (= 3 (length (peer-sent peer "Page.stopScreencast"))))
      (ok (null (%recording-threads))))))

(deftest discard-recording-stops-and-deletes
  (multiple-value-bind (b peer) (fake-recording-backend)
    (let* ((r (rec:start-recording b :audio nil))
           (dir (rec:recording-directory r)))
      (peer-push peer (frame-event 1000d0 +jpeg-a+))
      (ok (%frames-arrived r 1))
      (ok (probe-file (merge-pathnames "frame-000001.jpg" dir)))
      (ok (eq t (rec:discard-recording r)))
      (ok (not (rec:recording-active-p r)))
      (ok (= 1 (length (peer-sent peer "Page.stopScreencast"))))
      (ok (not (probe-file dir)) "the temporary directory is gone"))))

(deftest write-video-stops-an-active-recording-first
  (with-fake-recording (r peer :audio nil)
    (ok (null (handler-bind ((rec:recording-no-frames (lambda (c) (continue c))))
                (rec:write-video r (merge-pathnames "x.mp4" (rec:recording-directory r))))))
    (ok (not (rec:recording-active-p r)))
    (ok (= 1 (length (peer-sent peer "Page.stopScreencast"))))))

;;; WRITE-VIDEO with a stand-in ffmpeg: it records its arguments.

(defmacro %with-recording-ffmpeg ((args-file) &body body)
  `(if (uiop:os-windows-p)
       (skip "the stand-in ffmpeg is a sh script")
       (let* ((dir (%scratch-directory "ffmpeg"))
              (,args-file (merge-pathnames "args.txt" dir))
              (program (merge-pathnames "ffmpeg" dir)))
         (unwind-protect
              (progn
                (with-open-file (out program :direction :output :if-exists :supersede)
                  (format out "#!/bin/sh~%for a in \"$@\"; do printf '%s\\n' \"$a\"; done > '~a'~%exit 0~%"
                          (uiop:native-namestring ,args-file)))
                (stack-process:run (list "chmod" "755" (uiop:native-namestring program)))
                (let ((rec:*ffmpeg-program* program))
                  ,@body))
           (%remove-directory dir)))))

(deftest write-video-orchestrates-schedule-mix-and-ffmpeg
  (%with-recording-ffmpeg (args-file)
    (with-fake-recording (r peer)
      (peer-push peer
                 (frame-event 1000d0 +jpeg-a+ :session-id 1)
                 (frame-event 1000.5d0 +jpeg-b+ :session-id 2)
                 ;; seq 0 at frame 48000 of a context whose frame 0 is heard at 1000 s
                 (binding-event (%chunk-payload :track "d/1" :seq 0 :frame 48000 :rate 48000
                                                :time-origin 1000000 :performance-time 0
                                                :context-time 0
                                                :samples (%stereo '(0.5 0.5) '(0.25 0.25)))))
      (ok (%frames-arrived r 2))
      (ok (%wait-until (lambda () (rec:recording-audio-tracks r))))
      (let* ((output (merge-pathnames "out/page.mp4" (rec:recording-directory r)))
             (result (rec:write-video r output)))
        (ok (equal (merge-pathnames output) result) "the output pathname")
        (ok (not (rec:recording-active-p r)) "stopped first")
        ;; stop time 1002.25 (the fake page), last frame 1000.5: tail 1.75 s
        ;; -> N = max(ceiling(2.25 * 30), ceiling(15) + 1) = 68 slots
        (let* ((dir (rec:recording-directory r))
               (concat (merge-pathnames "video.ffconcat" dir))
               (wav (merge-pathnames "audio.wav" dir))
               (frames (rec:recording-frames r)))
          (ok (equal (rec:ffconcat-text frames :fps 30 :tail 7/4) (uiop:read-file-string concat)))
          (ok (equal (rec:ffmpeg-arguments concat output :fps 30 :slots 68 :audio-file wav)
                     (uiop:read-file-lines args-file))
              "ffmpeg ran with FFMPEG-ARGUMENTS")
          (ok (probe-file (merge-pathnames "out/" dir)) "the output's directory was made")
          (let ((audio (audio:read-wav wav)))
            (ok (= 48000 (audio:pcm-buffer-sample-rate audio)))
            (ok (= 2 (audio:pcm-buffer-channels audio)))
            (ok (= (audio:seconds-to-frame 68/30 48000) (audio:pcm-buffer-frames audio))
                "exactly as long as the video")
            (ok (equalp (rec:mix-recording r :frames (audio:seconds-to-frame 68/30 48000)
                                             :start 1000)
                        audio)
                "the mix, aligned to the first frame")
            (ok (= 0.5 (audio:sample-ref audio 48000 0)) "the chunk at 1 s")))))))

(deftest write-video-without-audio-has-no-audio-input
  (%with-recording-ffmpeg (args-file)
    (with-fake-recording (r peer :audio nil)
      (peer-push peer (frame-event 1000d0 +jpeg-a+))
      (ok (%frames-arrived r 1))
      (rec:write-video r (merge-pathnames "silent.mp4" (rec:recording-directory r))
                       :fps 25 :tail 0)
      (let ((args (uiop:read-file-lines args-file)))
        (ok (not (member "-c:a" args :test #'equal)) "no audio stream")
        (ok (= 1 (count "-i" args :test #'equal)))
        (ok (equal "1" (second (member "-frames:v" args :test #'equal))) "tail 0: one slot")
        (ok (equal "25" (second (member "-r" args :test #'equal))))))))

(deftest write-video-use-value-frames
  ;; A recording with no frames, given saved frames by the restart.
  (%with-recording-ffmpeg (args-file)
    (with-made-recording (r)
      (let* ((file (%write-octets (merge-pathnames "saved.jpg" (rec:recording-directory r)) +jpeg-a+))
             (frames (list (rec:make-recording-frame :timestamp 50 :pathname file))))
        (handler-bind ((rec:recording-no-frames (lambda (c) (use-value frames c))))
          (rec:write-video r (merge-pathnames "v.mp4" (rec:recording-directory r)) :tail 1))
        (ok (search (uiop:native-namestring file)
                    (uiop:read-file-string (merge-pathnames "video.ffconcat"
                                                            (rec:recording-directory r)))))
        (ok (equal "30" (second (member "-frames:v" (uiop:read-file-lines args-file)
                                        :test #'equal))))))))
