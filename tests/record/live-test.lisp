(in-package #:browser-protocol/record/tests)

;;; Live tests. Each skips, saying why, without what it needs:
;;;   Chrome   headless Chrome / Chromium / Edge (FIND-BROWSER-EXECUTABLE,
;;;            CHROME_PATH) whose AudioContext runs;
;;;   ffmpeg   ffmpeg and ffprobe (FFMPEG_PATH, PATH, the usual install paths).
;;; The page is tests/record/fixtures/tone.html, opened as a file: URL. Its
;;; Content-Security-Policy (a meta element, which file: pages keep) is
;;; default-src 'self'; script-src 'self'; style-src 'self'; worker-src 'none':
;;; no inline script, no blob: worklet. playTone(f, seconds, delay) plays a
;;; sine (amplitude 0.5) DELAY seconds later on the AudioContext's clock and
;;; turns the page white when the tone's first sample is heard
;;; (window.tone.heardEpoch, milliseconds since 1970, by the page's own
;;; getOutputTimestamp; window.tone.state the context's state).
;;;
;;; Tolerances, measured on Chrome 158 / ffmpeg 9.0 (macOS, 2026-11-27) and
;;; locked here:
(defparameter +placement-tolerance+ 0.005
  "Seconds: a page tone's onset in the recording vs the page's own heardEpoch.")
(defparameter +aac-tolerance+ 0.003
  "Seconds: a clip's onset in the decoded AAC vs where it was placed.")
(defparameter +mp4-onset-tolerance+ 0.010
  "Seconds: a page tone's onset in the decoded AAC vs the page's heardEpoch.")
(defparameter +av-lead-tolerance+ 0.010
  "Seconds the first white video frame may come before the tone's onset.")
(defparameter +av-lag-tolerance+ 0.080
  "Seconds the first white video frame may come after the tone's onset
   (page reaction, compositor, and a slot of 1/30 s).")
(defparameter +pitch-tolerance+ 2
  "Hz: the measured pitch of a tone vs its frequency.")
(defparameter +navigation-loss+ 0.1
  "Seconds of a tone a navigation may lose before it happens (two chunks of
   2048 frames at 48 kHz, and a margin).")

;;; --- tools ----------------------------------------------------------------

(defun %chrome-path () (bp:find-browser-executable))

(defun %tool-path (name env)
  (let ((value (uiop:getenv env))
        (exe (if (uiop:os-windows-p) (concatenate 'string name ".exe") name)))
    (or (and value (plusp (length value)) (probe-file value) (uiop:native-namestring (probe-file value)))
        (let ((found (bp::%on-path name))) (and found (uiop:native-namestring found)))
        (find-if #'probe-file (list (format nil "/opt/homebrew/bin/~a" exe)
                                    (format nil "/usr/local/bin/~a" exe)
                                    (format nil "/usr/bin/~a" exe))))))

(defun %ffmpeg-path () (%tool-path "ffmpeg" "FFMPEG_PATH"))

(defun %ffprobe-path ()
  (let ((ffmpeg (%ffmpeg-path)))
    (or (and ffmpeg
             (let ((next (merge-pathnames (if (uiop:os-windows-p) "ffprobe.exe" "ffprobe")
                                          (uiop:pathname-directory-pathname ffmpeg))))
               (and (probe-file next) (uiop:native-namestring next))))
        (%tool-path "ffprobe" "FFPROBE_PATH"))))

(defun %run (program &rest args)
  "Run PROGRAM; -> standard output (a string). A nonzero exit fails loudly."
  (multiple-value-bind (code out err)
      (stack-process:run (cons program args) :output :string :error-output :string)
    (unless (zerop code)
      (error "~a exited with ~a: ~a" program code err))
    out))

(defun %run-octets (program &rest args)
  (multiple-value-bind (code out err)
      (stack-process:run (cons program args) :output :octets :error-output :string)
    (unless (zerop code)
      (error "~a exited with ~a: ~a" program code err))
    out))

(defun %streams (file)
  "ffprobe's streams of FILE: a list of hash-tables."
  (coerce (gethash "streams" (json-protocol:decode
                              (%run (%ffprobe-path) "-v" "error" "-show_streams" "-count_frames"
                                    "-of" "json" (uiop:native-namestring file))))
          'list))

(defun %stream (streams type)
  (find type streams :key (lambda (s) (gethash "codec_type" s)) :test #'equal))

(defun %decoded-audio (file dir)
  "FILE's first audio stream decoded to 48 kHz stereo PCM16 (a PCM-BUFFER)."
  (let ((wav (merge-pathnames "decoded.wav" dir)))
    (%run (%ffmpeg-path) "-nostdin" "-v" "error" "-y" "-i" (uiop:native-namestring file)
          "-map" "0:a:0" "-c:a" "pcm_s16le" "-ar" "48000" "-ac" "2"
          (uiop:native-namestring wav))
    (values (audio:read-wav wav))))

(defun %center-levels (file)
  "The grey level (0 .. 255) of the centre of each video frame of FILE."
  (%run-octets (%ffmpeg-path) "-nostdin" "-v" "error" "-i" (uiop:native-namestring file)
               "-vf" "crop=16:16:(iw-16)/2:(ih-16)/2,scale=1:1:flags=area,format=gray"
               "-f" "rawvideo" "-"))

(defun %make-jpeg (path color width height)
  (%run (%ffmpeg-path) "-nostdin" "-v" "error" "-y" "-f" "lavfi"
        "-i" (format nil "color=~a:s=~dx~d" color width height)
        "-frames:v" "1" "-update" "1" (uiop:native-namestring path))
  path)

;;; --- signals ----------------------------------------------------------------

(defun %sine (rate seconds frequency &key (amplitude 0.5))
  (%buffer rate 1 (loop for i below (round (* rate seconds))
                        collect (* amplitude (sin (/ (* 2 pi frequency i) rate))))))

(defun %onset (buffer &key (from 0) (threshold 0.1))
  "Seconds: the first frame at or after FROM seconds whose channel 0 exceeds THRESHOLD."
  (let ((rate (audio:pcm-buffer-sample-rate buffer)))
    (loop for i from (round (* from rate)) below (audio:pcm-buffer-frames buffer)
          when (> (abs (audio:sample-ref buffer i 0)) threshold)
            return (/ i rate))))

(defun %offset (buffer &key (from 0) (threshold 0.1) (gap 0.01))
  "Seconds: the end of the sound that starts at or after FROM (the last loud
   frame before GAP seconds of quiet)."
  (let* ((rate (audio:pcm-buffer-sample-rate buffer))
         (quiet (round (* gap rate)))
         (start (round (* (or (%onset buffer :from from :threshold threshold) from) rate))))
    (loop with last = start
          for i from start below (audio:pcm-buffer-frames buffer)
          do (if (> (abs (audio:sample-ref buffer i 0)) threshold)
                 (setf last i)
                 (when (> (- i last) quiet) (return (/ last rate))))
          finally (return (/ last rate)))))

(defun %pitch (buffer at &key (size 8192))
  "Hz: the strongest frequency of channel 0 in SIZE frames from AT seconds
   (Hann window, RFFT, parabolic interpolation of the peak bin)."
  (let* ((rate (audio:pcm-buffer-sample-rate buffer))
         (start (round (* at rate)))
         (window (dsp:make-window :hann size))
         (frame (make-array size :element-type 'double-float)))
    (dotimes (i size)
      (setf (aref frame i) (* (aref window i)
                              (if (< (+ start i) (audio:pcm-buffer-frames buffer))
                                  (float (audio:sample-ref buffer (+ start i) 0) 1d0)
                                  0d0))))
    (let* ((mag (dsp:magnitude (dsp:rfft frame)))
           (k (loop with best = 1
                    for j from 1 below (1- (length mag))
                    when (> (aref mag j) (aref mag best)) do (setf best j)
                    finally (return best)))
           (a (log (max 1d-300 (aref mag (1- k)))))
           (b (log (max 1d-300 (aref mag k))))
           (c (log (max 1d-300 (aref mag (1+ k)))))
           (delta (/ (* 0.5d0 (- a c)) (+ (- a (* 2 b)) c))))
      (* (+ k delta) (/ rate size)))))

;;; --- the browser ----------------------------------------------------------

(defun %fixture-url (name)
  (let* ((path (uiop:native-namestring
                (asdf:system-relative-pathname "browser-protocol/record/tests"
                                               (format nil "tests/record/fixtures/~a" name))))
         (slashed (substitute #\/ #\\ path)))
    (with-output-to-string (s)
      (write-string (if (char= #\/ (char slashed 0)) "file://" "file:///") s)
      (loop for ch across slashed
            do (case ch
                 (#\Space (write-string "%20" s))
                 (#\# (write-string "%23" s))
                 (#\% (write-string "%25" s))
                 (t (write-char ch s)))))))

(defmacro with-live-browser ((var) &body body)
  `(if (null (%chrome-path))
       (skip "no Chrome/Chromium (set CHROME_PATH)")
       (let ((,var (bp:launch-browser :timeout 30
                                      :args '("--autoplay-policy=no-user-gesture-required"))))
         (unwind-protect (progn ,@body)
           (bp:close-browser ,var)))))

(defun %evaluate-awaited (backend expression)
  "Runtime.evaluate with awaitPromise (eval-js does not await, browser-protocol#8)."
  (let ((reply (bp:cdp-call backend "Runtime.evaluate"
                            (%h "expression" expression "returnByValue" t "awaitPromise" t))))
    (gethash "value" (gethash "result" reply))))

(defun %play (b frequency seconds delay)
  "Start a tone on the page; -> the AudioContext's state."
  (bp:eval-js b (format nil "playTone(~d, ~f, ~f)" frequency seconds delay)))

(defun %heard-epoch (b)
  "Seconds since 1970 at which the page heard its tone start, waiting for it."
  (let ((ms (%wait-until (lambda ()
                           (bp:eval-js b "window.tone && window.tone.heardEpoch ? window.tone.heardEpoch : false"))
                         :timeout 5)))
    (and ms (/ (rational ms) 1000))))

(defun %page-now (b)
  (/ (rational (bp:eval-js b "performance.timeOrigin + performance.now()")) 1000))

(defmacro %unless-audio-runs ((b state) &body body)
  `(if (not (equal "running" ,state))
       (skip (format nil "the browser's AudioContext does not run here (state ~s)" ,state))
       (let ((heard (%heard-epoch ,b)))
         (if (null heard)
             (skip "the page never heard its tone (no audio output clock here)")
             (progn ,@body)))))

;;; --- Chrome: page audio under a strict CSP ----------------------------------

(deftest live-strict-csp-page-blocks-what-a-worklet-tap-would-need
  ;; Evidence for the method: on this page an AudioWorklet from a blob: URL
  ;; is refused and inline scripts do not run.
  (with-live-browser (b)
    (bp:navigate b (%fixture-url "tone.html"))
    (ok (null (bp:eval-js b "window.inlineScriptRan === true")) "inline scripts are blocked")
    (ok (eq t (bp:eval-js b "typeof window.playTone === 'function'")) "'self' scripts run")
    (ok (search "blocked"
                (%evaluate-awaited b "(async () => { const ctx = new AudioContext();
                   const url = URL.createObjectURL(new Blob([\"registerProcessor('x', class extends AudioWorkletProcessor { process() { return true; } })\"], {type: 'application/javascript'}));
                   try { await ctx.audioWorklet.addModule(url); return 'loaded'; } catch (e) { return 'blocked: ' + e; } })()"))
        "a blob: worklet module is refused")))

(deftest live-page-audio-is-captured-under-a-strict-csp
  (with-live-browser (b)
    (let ((r (rec:start-recording b)))
      (unwind-protect
           (progn
             (bp:navigate b (%fixture-url "tone.html"))
             (ok (null (bp:eval-js b "window.inlineScriptRan === true")) "the CSP is in force")
             (%unless-audio-runs (b (%play b 440 1.0 0.5))
               (sleep 1.4)
               (rec:stop-recording r)
               (let* ((tracks (rec:recording-audio-tracks r))
                      (start (rational (rec:recording-start-time r)))
                      (mix (rec:mix-recording r))
                      (onset (%onset mix))
                      (expected (- heard start)))
                 (ok (= 1 (length tracks)) "one AudioContext, one track")
                 (ok (search "/1" (rec:audio-track-id (first tracks))))
                 (ok (= 48000 (audio:pcm-buffer-sample-rate mix)))
                 (ok (and onset (< (abs (- onset expected)) +placement-tolerance+))
                     (format nil "onset ~,4fs, the page heard it at ~,4fs" onset (float expected)))
                 (ok (< (abs (- (%pitch mix (+ onset 0.1)) 440)) +pitch-tolerance+)
                     (format nil "pitch ~,2f Hz" (%pitch mix (+ onset 0.1))))
                 (ok (< (abs (- (- (%offset mix) onset) 1)) 0.01)
                     (format nil "the tone lasts ~,4fs" (- (%offset mix) onset)))
                 (ok (rec:recording-frames r) "frames")
                 (ok (every (lambda (f)
                              (let ((o (%read-octets (rec:recording-frame-pathname f))))
                                (and (> (length o) 2) (= #xFF (aref o 0)) (= #xD8 (aref o 1)))))
                            (rec:recording-frames r))
                     "every frame file is a JPEG")
                 (ok (null (rec:recording-warnings r)) "nothing dropped")
                 (ok (rec:recording-stop-time r)))))
        (let ((dir (rec:recording-directory r)))
          (rec:discard-recording r)
          (ok (not (probe-file dir)) "discarded"))))))

(deftest live-tap-installed-in-the-current-document
  ;; Recording starts after the page loaded: Runtime.evaluate installs the tap.
  (with-live-browser (b)
    (bp:navigate b (%fixture-url "tone.html"))
    (let ((r (rec:start-recording b)))
      (unwind-protect
           (%unless-audio-runs (b (%play b 660 0.4 0.3))
             (sleep 0.8)
             (rec:stop-recording r)
             (let* ((mix (rec:mix-recording r))
                    (onset (%onset mix)))
               (ok (and onset (< (abs (- onset (- heard (rational (rec:recording-start-time r)))))
                                 +placement-tolerance+)))
               (ok (< (abs (- (%pitch mix (+ onset 0.05) :size 4096) 660)) (* 2 +pitch-tolerance+)))))
        (rec:discard-recording r)))))

(deftest live-navigation-keeps-the-audio-up-to-it
  ;; A tone plays, the page navigates mid-tone (the document and its
  ;; AudioContext go away), the new document plays another tone: two tracks,
  ;; the first kept up to the navigation.
  (with-live-browser (b)
    (let ((r (rec:start-recording b)))
      (unwind-protect
           (progn
             (bp:navigate b (%fixture-url "tone.html"))
             (%unless-audio-runs (b (%play b 440 2.0 0.3))
               (sleep 0.6)
               (let ((left (%page-now b)))
                 (bp:navigate b (%fixture-url "tone.html"))
                 (let ((state (%play b 880 0.5 0.3))
                       (second-heard (%heard-epoch b)))
                   (sleep 0.8)
                   (rec:stop-recording r)
                   (ok (equal "running" state))
                   (let* ((start (rational (rec:recording-start-time r)))
                          (tracks (rec:recording-audio-tracks r))
                          (mix (rec:mix-recording r))
                          (first-onset (%onset mix))
                          (first-end (%offset mix :gap 0.05)))
                     (ok (= 2 (length tracks)) "a track per document")
                     (ok (not (equal (rec:audio-track-id (first tracks))
                                     (rec:audio-track-id (second tracks)))))
                     (ok (< (abs (- first-onset (- heard start))) +placement-tolerance+))
                     (ok (>= first-end (- left start +navigation-loss+))
                         (format nil "the first tone lasts until ~,3fs; the page left at ~,3fs"
                                 first-end (float (- left start))))
                     (ok (< (abs (- (%pitch mix (+ first-onset 0.1)) 440)) +pitch-tolerance+))
                     (ok second-heard)
                     (when second-heard
                       (let ((second-onset (%onset mix :from (+ first-end 0.02))))
                         (ok (and second-onset
                                  (< (abs (- second-onset (- second-heard start)))
                                     +placement-tolerance+))
                             (format nil "second onset ~a" second-onset))
                         (when second-onset
                           (ok (< (abs (- (%pitch mix (+ second-onset 0.05)) 880))
                                  +pitch-tolerance+))))))))))
        (rec:discard-recording r)))))

;;; --- ffmpeg: saved frames to MP4 --------------------------------------------

(defmacro with-ffmpeg ((dir) &body body)
  `(if (not (and (%ffmpeg-path) (%ffprobe-path)))
       (skip "no ffmpeg / ffprobe (set FFMPEG_PATH)")
       (let ((,dir (%scratch-directory "mp4"))
             (rec:*ffmpeg-program* (%ffmpeg-path)))
         (unwind-protect (progn ,@body)
           (%remove-directory ,dir)))))

(defun %saved-frames (dir)
  "Black and white 101x75 frames and a grey 160x120 one, at 1000, 1000.5 and 1000.75."
  (list (rec:make-recording-frame :timestamp 1000d0 :index 1
                                  :pathname (%make-jpeg (merge-pathnames "a.jpg" dir) "black" 101 75))
        (rec:make-recording-frame :timestamp 1000.5d0 :index 2
                                  :pathname (%make-jpeg (merge-pathnames "b.jpg" dir) "white" 101 75))
        (rec:make-recording-frame :timestamp 1000.75d0 :index 3
                                  :pathname (%make-jpeg (merge-pathnames "c.jpg" dir) "gray" 160 120))))

(deftest live-saved-frames-and-clips-to-mp4
  (with-ffmpeg (dir)
    (let* ((r (rec:make-recording :directory (merge-pathnames "rec/" dir)
                                  :frames (%saved-frames dir)))
           (beep (merge-pathnames "beep.wav" dir))
           (low (merge-pathnames "low.wav" dir))
           (out (merge-pathnames "out/saved.mp4" dir)))
      (audio:write-wav (%sine 48000 0.3 1000) beep)
      (audio:write-wav (%sine 16000 0.2 660) low)
      (rec:add-audio-file r beep :at 0.4)
      (rec:add-audio-file r low :at 0.9)
      ;; 1000.75 + tail 0.25: 30 slots at 30 fps
      (ok (equal (merge-pathnames out) (rec:write-video r out :fps 30 :tail 0.25)))
      (let* ((streams (%streams out))
             (video (%stream streams "video"))
             (sound (%stream streams "audio")))
        (ok (equal "h264" (gethash "codec_name" video)))
        (ok (equal "yuv420p" (gethash "pix_fmt" video)))
        (ok (eql 100 (gethash "width" video)) "even: 101 -> 100")
        (ok (eql 74 (gethash "height" video)) "75 -> 74; the 160x120 frame is scaled to it")
        (ok (equal "30" (gethash "nb_read_frames" video)) "30 frames")
        (ok (equal "30/1" (gethash "r_frame_rate" video)))
        (ok (equal "aac" (gethash "codec_name" sound)))
        (ok (equal "48000" (gethash "sample_rate" sound)))
        (ok (eql 2 (gethash "channels" sound))))
      (let ((levels (%center-levels out)))
        (ok (= 30 (length levels)))
        (ok (every (lambda (v) (< v 40)) (subseq levels 0 15))
            (format nil "slots 0-14 black: ~a" levels))
        (ok (every (lambda (v) (> v 200)) (subseq levels 15 23))
            (format nil "slots 15-22 white: ~a" levels))
        (ok (every (lambda (v) (< 90 v 170)) (subseq levels 23 30))
            (format nil "slots 23-29 grey: ~a" levels)))
      (let* ((pcm (%decoded-audio out dir))
             (beep-at (%onset pcm))
             (low-at (%onset pcm :from 0.8)))
        (ok (< (abs (- (audio:pcm-buffer-duration pcm) 1)) 0.03)
            (format nil "audio lasts ~,4fs" (float (audio:pcm-buffer-duration pcm))))
        (ok (and beep-at (< (abs (- beep-at 0.4)) +aac-tolerance+))
            (format nil "the beep at ~,4fs" beep-at))
        (ok (< (abs (- (%pitch pcm 0.45 :size 4096) 1000)) +pitch-tolerance+))
        (ok (and low-at (< (abs (- low-at 0.9)) +aac-tolerance+))
            (format nil "the 16 kHz clip at ~,4fs" low-at))
        (ok (< (abs (- (%pitch pcm 0.905 :size 4096) 660)) (* 2 +pitch-tolerance+)))))))

(deftest live-no-audio-means-no-audio-stream
  (with-ffmpeg (dir)
    (let* ((r (rec:make-recording :directory (merge-pathnames "rec/" dir)
                                  :frames (%saved-frames dir)))
           (out (merge-pathnames "silent.mp4" dir)))
      (rec:write-video r out :tail 0)
      (let ((streams (%streams out)))
        (ok (%stream streams "video"))
        (ok (null (%stream streams "audio")) "no audio stream, not a silent one")))))

(deftest live-ffmpeg-failure-and-retry
  (with-ffmpeg (dir)
    (let* ((frames (%saved-frames dir))
           (bad (rec:recording-frame-pathname (second frames)))
           (r (rec:make-recording :directory (merge-pathnames "rec/" dir) :frames frames))
           (out (merge-pathnames "retry.mp4" dir))
           (failures '()))
      (%write-octets bad (%octets 1 2 3 4 5))
      (ok (equal (merge-pathnames out)
                 (handler-bind ((rec:ffmpeg-error
                                  (lambda (c)
                                    (push c failures)
                                    (%make-jpeg bad "white" 101 75)
                                    (bp:invoke-retry c))))
                   (rec:write-video r out :tail 0)))
          "RETRY after fixing the frame")
      (ok (= 1 (length failures)))
      (let ((c (first failures)))
        (ok (not (typep c 'rec:ffmpeg-not-found)))
        (ok (and (integerp (rec:ffmpeg-error-exit-code c)) (/= 0 (rec:ffmpeg-error-exit-code c))))
        (ok (plusp (length (rec:ffmpeg-error-stderr-tail c))) (rec:ffmpeg-error-stderr-tail c))
        (ok (<= (length (uiop:split-string (rec:ffmpeg-error-stderr-tail c) :separator '(#\Newline)))
                rec:+ffmpeg-stderr-tail-lines+)))
      (ok (probe-file out)))))

(deftest live-find-ffmpeg-finds-it
  (if (null (%ffmpeg-path))
      (skip "no ffmpeg (set FFMPEG_PATH)")
      (let ((found (rec:find-ffmpeg)))
        (ok (and found (probe-file found)) (format nil "found ~a" found))
        (ok (stringp (rec:run-ffmpeg '("-hide_banner" "-loglevel" "error" "-version")
                                     :program found))
            "it runs"))))

;;; --- Chrome and ffmpeg: a page with sound to MP4 ----------------------------

(deftest live-recording-with-sound-to-mp4
  (if (not (and (%ffmpeg-path) (%ffprobe-path)))
      (skip "no ffmpeg / ffprobe (set FFMPEG_PATH)")
      (with-live-browser (b)
        (let ((dir (%scratch-directory "page"))
              (rec:*ffmpeg-program* (%ffmpeg-path))
              (saved nil))
          (unwind-protect
               (rec:with-recording (r b)
                 (setf saved r)
                 (bp:navigate b (%fixture-url "tone.html"))
                 (%unless-audio-runs (b (%play b 440 1.0 0.5))
                   (sleep 1.2)
                   ;; A clip on the page's clock: 1.5 s after the tone was heard.
                   (let ((beep (merge-pathnames "beep.wav" dir)))
                     (audio:write-wav (%sine 48000 0.2 1000) beep)
                     (rec:add-audio-file r beep :epoch (+ heard 3/2)))
                   (sleep 1.0)
                   (rec:stop-recording r)
                   (let* ((out (merge-pathnames "page.mp4" dir))
                          (start (rational (rec:recording-start-time r)))
                          (tone-at (- heard start)))
                     (rec:write-video r out)
                     (let* ((streams (%streams out))
                            (video (%stream streams "video")))
                       (ok video "a video stream")
                       (ok (equal "h264" (gethash "codec_name" video)))
                       (ok (equal "yuv420p" (gethash "pix_fmt" video)))
                       (ok (evenp (gethash "width" video)))
                       (ok (evenp (gethash "height" video)))
                       (ok (equal "aac" (gethash "codec_name" (%stream streams "audio"))) "an AAC stream")
                       (ok (< (abs (- (* (parse-integer (gethash "nb_read_frames" video)) 1/30)
                                      (- (rational (rec:recording-stop-time r)) start)))
                              1/15)
                           "the video lasts until the recording stopped"))
                     (let* ((pcm (%decoded-audio out dir))
                            (onset (%onset pcm))
                            (beep-at (%onset pcm :from (+ tone-at 1.2))))
                       (ok (and onset (< (abs (- onset tone-at)) +mp4-onset-tolerance+))
                           (format nil "tone at ~,4fs, heard at ~,4fs" onset (float tone-at)))
                       (ok (< (abs (- (%pitch pcm (+ onset 0.1)) 440)) +pitch-tolerance+))
                       (ok (and beep-at (< (abs (- beep-at (+ tone-at 3/2))) +mp4-onset-tolerance+))
                           (format nil "beep at ~,4fs" beep-at))
                       (when beep-at
                         (ok (< (abs (- (%pitch pcm (+ beep-at 0.05) :size 4096) 1000))
                                +pitch-tolerance+)))
                       ;; The page turns white when it hears the tone.
                       (let* ((levels (%center-levels out))
                              (white (position-if (lambda (v) (> v 128)) levels)))
                         (ok white "the page turned white")
                         (when (and white onset)
                           (let ((lag (- (/ white 30) onset)))
                             (ok (<= (- +av-lead-tolerance+) lag +av-lag-tolerance+)
                                 (format nil "first white frame ~,4fs after the tone" (float lag))))))))))
            (when saved (rec:discard-recording saved))
            (%remove-directory dir))))))
