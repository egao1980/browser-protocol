(in-package #:browser-protocol/record/tests)

;;; The condition tree (given) and the restarts of each signal site.

(deftest condition-tree
  (ok (subtypep 'rec:recording-error 'bp:browser-error))
  (ok (subtypep 'rec:recording-stopped 'rec:recording-error))
  (ok (subtypep 'rec:recording-no-frames 'rec:recording-error))
  (ok (subtypep 'rec:ffmpeg-error 'rec:recording-error))
  (ok (subtypep 'rec:ffmpeg-not-found 'rec:ffmpeg-error))
  (ok (subtypep 'rec:recording-warning 'warning))
  (ng (subtypep 'rec:recording-warning 'error)))

(deftest ffmpeg-error-slots-and-report
  (let ((c (make-condition 'rec:ffmpeg-error :program "/usr/bin/ffmpeg"
                                             :arguments '("-i" "x")
                                             :exit-code 1
                                             :stderr-tail (format nil "a~%b"))))
    (ok (equal "/usr/bin/ffmpeg" (rec:ffmpeg-error-program c)))
    (ok (equal '("-i" "x") (rec:ffmpeg-error-arguments c)))
    (ok (eql 1 (rec:ffmpeg-error-exit-code c)))
    (ok (search (format nil "a~%b") (princ-to-string c)) "the report shows the stderr tail")
    (ok (search "code 1" (princ-to-string c)))))

(deftest ffmpeg-not-found-report
  (ok (search "no ffmpeg" (princ-to-string (make-condition 'rec:ffmpeg-not-found))))
  (ok (search "/nonexistent/ffmpeg"
              (princ-to-string (make-condition 'rec:ffmpeg-not-found
                                               :program "/nonexistent/ffmpeg")))))

(deftest recording-warning-slots
  (let ((c (make-condition 'rec:recording-warning :reason "a frame without a timestamp")))
    (ok (equal "a frame without a timestamp" (rec:recording-warning-reason c)))
    (ok (search "a frame without a timestamp" (princ-to-string c)))))

(deftest stop-twice-signals-recording-stopped
  ;; A recording that is not active, made by hand: no browser needed.
  (with-made-recording (r)
    (ok (signals (rec:stop-recording r) 'rec:recording-stopped))
    (handler-case (rec:stop-recording r)
      (rec:recording-stopped (c)
        (ok (eq r (rec:recording-error-recording c)) "the condition names the recording")))))

(deftest stop-twice-continue-returns-the-recording
  (with-made-recording (r)
    (ok (eq r (handler-bind ((rec:recording-stopped
                               (lambda (c) (continue c))))
                (rec:stop-recording r))))))

(deftest write-video-without-frames-signals
  (with-made-recording (r)
    (let ((out (merge-pathnames "none.mp4" (rec:recording-directory r))))
      (ok (signals (rec:write-video r out) 'rec:recording-no-frames))
      (ok (null (handler-bind ((rec:recording-no-frames
                                 (lambda (c) (continue c))))
                  (rec:write-video r out)))
          "CONTINUE: WRITE-VIDEO returns NIL")
      (ok (not (probe-file out)) "and writes nothing"))))

(deftest write-video-no-frames-use-value-is-checked-again
  ;; USE-VALUE with an empty list is checked again: the handler sees a second
  ;; signal and then continues.
  (let ((seen 0))
    (with-made-recording (r)
      (ok (null (handler-bind ((rec:recording-no-frames
                                 (lambda (c)
                                   (incf seen)
                                   (if (= seen 1) (use-value '() c) (continue c)))))
                  (rec:write-video r (merge-pathnames "x.mp4" (rec:recording-directory r)))))
          "the replacement is checked again"))
    (ok (= 2 seen))))

(deftest video-schedule-without-frames-signals
  (ok (signals (rec:video-schedule '()) 'rec:recording-no-frames))
  (ok (signals (rec:ffconcat-text '()) 'rec:recording-no-frames)))

(deftest mix-recording-without-a-clock-signals
  (with-made-recording (r)
    (ok (signals (rec:mix-recording r) 'rec:recording-no-frames))))

(deftest add-audio-file-at-and-epoch-is-an-error
  (with-made-recording (r)
    (let ((wav (merge-pathnames "c.wav" (rec:recording-directory r))))
      (audio:write-wav (%buffer 48000 1 '(0.5 0.5)) wav)
      (ok (signals (rec:add-audio-file r wav :at 1 :epoch 1000) 'rec:recording-error))
      (ok (null (rec:recording-audio-clips r)) "nothing added"))))
