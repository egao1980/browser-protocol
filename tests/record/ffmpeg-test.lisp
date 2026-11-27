(in-package #:browser-protocol/record/tests)

;;; FFMPEG-ARGUMENTS, FIND-FFMPEG, RUN-FFMPEG with stand-in programs (shell
;;; scripts; skipped on Windows). The real ffmpeg is in live-test.lisp.

(defun %abs (p)
  (uiop:native-namestring (merge-pathnames (merge-pathnames p) (uiop:getcwd))))

(deftest ffmpeg-arguments-video-only
  (ok (equal (list "-nostdin" "-hide_banner" "-loglevel" "error" "-xerror" "-y"
                   "-f" "concat" "-safe" "0" "-reinit_filter" "0" "-i" (%abs "/tmp/r/video.ffconcat")
                   "-vf" "scale=trunc(iw/2)*2:trunc(ih/2)*2:eval=init:out_range=tv,format=yuv420p"
                   "-r" "30" "-fps_mode" "cfr" "-frames:v" "91"
                   "-c:v" "libx264" "-pix_fmt" "yuv420p"
                   "-movflags" "+faststart" (%abs "/tmp/out/page.mp4"))
             (rec:ffmpeg-arguments #p"/tmp/r/video.ffconcat" "/tmp/out/page.mp4" :slots 91))))

(deftest ffmpeg-arguments-with-audio
  (ok (equal (list "-nostdin" "-hide_banner" "-loglevel" "error" "-xerror" "-y"
                   "-f" "concat" "-safe" "0" "-reinit_filter" "0" "-i" (%abs "/tmp/r/video.ffconcat")
                   "-i" (%abs "/tmp/r/audio.wav") "-map" "0:v:0" "-map" "1:a:0"
                   "-vf" "scale=trunc(iw/2)*2:trunc(ih/2)*2:eval=init:out_range=tv,format=yuv420p"
                   "-r" "25" "-fps_mode" "cfr" "-frames:v" "7"
                   "-c:v" "libx264" "-pix_fmt" "yuv420p"
                   "-c:a" "aac" "-b:a" "128k"
                   "-movflags" "+faststart" (%abs "/tmp/out/page.mp4"))
             (rec:ffmpeg-arguments "/tmp/r/video.ffconcat" #p"/tmp/out/page.mp4"
                                   :fps 25 :slots 7 :audio-file #p"/tmp/r/audio.wav"))))

(deftest ffmpeg-arguments-relative-paths-are-absolute
  (let ((args (rec:ffmpeg-arguments "v.ffconcat" "o.mp4" :slots 1)))
    (ok (member (%abs "v.ffconcat") args :test #'equal))
    (ok (equal (%abs "o.mp4") (car (last args))))))

(deftest ffmpeg-arguments-types
  (ok (signals (rec:ffmpeg-arguments "v" "o" :slots 0) 'type-error))
  (ok (signals (rec:ffmpeg-arguments "v" "o") 'type-error) "SLOTS is required")
  (ok (signals (rec:ffmpeg-arguments "v" "o" :slots 1 :fps 0) 'type-error))
  (ok (signals (rec:ffmpeg-arguments "v" "o" :slots 1 :fps 29.97) 'type-error)))

(defmacro %with-env ((name value) &body body)
  (let ((old (gensym)))
    `(let ((,old (uiop:getenv ,name)))
       (setf (uiop:getenv ,name) ,value)
       (unwind-protect (progn ,@body)
         (setf (uiop:getenv ,name) (or ,old ""))))))

(deftest find-ffmpeg-takes-ffmpeg-path-first
  (let* ((dir (%scratch-directory "find"))
         (fake (merge-pathnames "my-ffmpeg" dir)))
    (unwind-protect
         (progn
           (%write-octets fake (%octets 0))
           (%with-env ("FFMPEG_PATH" (uiop:native-namestring fake))
             (ok (equal (uiop:native-namestring fake) (rec:find-ffmpeg))))
           (%with-env ("FFMPEG_PATH" (uiop:native-namestring (merge-pathnames "nope" dir)))
             (ok (not (equal (uiop:native-namestring (merge-pathnames "nope" dir))
                             (rec:find-ffmpeg)))
                 "a FFMPEG_PATH naming no file is passed over")))
      (%remove-directory dir))))

(deftest find-ffmpeg-looks-in-path
  (let* ((dir (%scratch-directory "path"))
         (fake (merge-pathnames (if (uiop:os-windows-p) "ffmpeg.exe" "ffmpeg") dir)))
    (unwind-protect
         (progn
           (%write-octets fake (%octets 0))
           (%with-env ("FFMPEG_PATH" "")
             (%with-env ("PATH" (format nil "~a~a~a"
                                        (uiop:native-namestring dir)
                                        (if (uiop:os-windows-p) ";" ":")
                                        (or (uiop:getenv "PATH") "")))
               (ok (equal (uiop:native-namestring fake) (rec:find-ffmpeg))))))
      (%remove-directory dir))))

(deftest run-ffmpeg-without-a-program
  (let ((rec:*ffmpeg-program* "/nonexistent/br1/ffmpeg"))
    (ok (signals (rec:run-ffmpeg '("-version")) 'rec:ffmpeg-not-found))
    (handler-case (rec:run-ffmpeg '("-version"))
      (rec:ffmpeg-not-found (c)
        (ok (search "nonexistent" (rec:ffmpeg-error-program c)))
        (ok (null (rec:ffmpeg-error-exit-code c)))))
    (ok (signals (rec:run-ffmpeg '("-version") :program "/nonexistent/br1/other")
                 'rec:ffmpeg-not-found)
        ":PROGRAM too")))

;;; Stand-in programs: POSIX sh scripts.

(defmacro %with-fake-program ((var dir script) &body body)
  `(if (uiop:os-windows-p)
       (skip "stand-in ffmpeg programs are sh scripts")
       (let* ((,dir (%scratch-directory "fake"))
              (,var (merge-pathnames "fake-ffmpeg" ,dir)))
         (declare (ignorable ,dir))
         (unwind-protect
              (progn
                (with-open-file (out ,var :direction :output :if-exists :supersede)
                  (format out "#!/bin/sh~%~a~%" ,script))
                (stack-process:run (list "chmod" "755" (uiop:native-namestring ,var)))
                ,@body)
           (%remove-directory ,dir)))))

(deftest run-ffmpeg-returns-stderr
  (%with-fake-program (fake dir "echo \"args: $*\" >&2; echo out; exit 0")
    (let ((stderr (rec:run-ffmpeg '("-i" "x y") :program fake)))
      (ok (stringp stderr))
      (ok (search "args: -i x y" stderr) stderr)
      (ok (not (search "out" stderr)) "standard output is not returned"))))

(deftest run-ffmpeg-failure-keeps-the-stderr-tail
  (%with-fake-program (fake dir "i=1; while [ $i -le 25 ]; do printf 'line %d\\r\\n' $i >&2; i=$((i+1)); done; exit 3")
    (handler-case (progn (rec:run-ffmpeg '("-y" "out.mp4") :program fake)
                         (ok nil "no error"))
      (rec:ffmpeg-error (c)
        (ok (not (typep c 'rec:ffmpeg-not-found)))
        (ok (= 3 (rec:ffmpeg-error-exit-code c)))
        (ok (equal '("-y" "out.mp4") (rec:ffmpeg-error-arguments c)))
        (ok (equal (uiop:native-namestring fake) (rec:ffmpeg-error-program c)))
        (ok (equal (format nil "~{line ~d~^~%~}" (loop for i from 6 to 25 collect i))
                   (rec:ffmpeg-error-stderr-tail c))
            "the last 20 lines, without carriage returns or a trailing empty line")))))

(deftest run-ffmpeg-short-stderr-tail
  (%with-fake-program (fake dir "echo only >&2; exit 1")
    (handler-case (progn (rec:run-ffmpeg '() :program fake) (ok nil "no error"))
      (rec:ffmpeg-error (c)
        (ok (equal "only" (rec:ffmpeg-error-stderr-tail c)))))))

(deftest run-ffmpeg-use-value-runs-another-program
  (%with-fake-program (fake dir "echo fine >&2; exit 0")
    (let ((rec:*ffmpeg-program* "/nonexistent/br1/ffmpeg")
          (seen 0))
      (ok (search "fine"
                  (handler-bind ((rec:ffmpeg-not-found
                                   (lambda (c) (incf seen) (use-value fake c))))
                    (rec:run-ffmpeg '("-version")))))
      (ok (= 1 seen)))))

(deftest run-ffmpeg-use-value-failure-signals-again
  (%with-fake-program (fake dir "exit 2")
    (let ((seen '()))
      (ok (signals
           (handler-bind ((rec:ffmpeg-error
                            (lambda (c)
                              (push (type-of c) seen)
                              (when (typep c 'rec:ffmpeg-not-found)
                                (use-value fake c)))))
             (rec:run-ffmpeg '() :program "/nonexistent/br1/ffmpeg"))
           'rec:ffmpeg-error))
      (ok (equal '(rec:ffmpeg-error rec:ffmpeg-not-found) (remove-duplicates seen :from-end t))
          (format nil "~s" seen)))))

(deftest run-ffmpeg-retry-runs-again
  ;; Fails until a marker file exists; the handler makes it, then RETRY.
  (%with-fake-program (fake dir (format nil "[ -f '~a' ] && { echo ok >&2; exit 0; }; echo missing >&2; exit 1"
                                        (uiop:native-namestring (merge-pathnames "marker" dir))))
    (let ((tries 0))
      (ok (search "ok" (handler-bind ((rec:ffmpeg-error
                                        (lambda (c)
                                          (incf tries)
                                          (%write-octets (merge-pathnames "marker" dir) (%octets 1))
                                          (bp:invoke-retry c))))
                         (rec:run-ffmpeg '() :program fake))))
      (ok (= 1 tries)))))

(deftest run-ffmpeg-finds-a-bare-name-in-path
  (if (uiop:os-windows-p)
      (skip "sh is not on PATH on Windows")
      (ok (stringp (rec:run-ffmpeg '("-c" "echo hi >&2") :program "sh")))))
