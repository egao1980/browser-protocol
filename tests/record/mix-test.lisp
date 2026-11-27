(in-package #:browser-protocol/record/tests)

;;; MIX-PLACED and MIX-RECORDING: every track and clip at its exact sample
;;; position, overlaps summed, clamped, aligned to the first frame.

(defun %const (rate channels frames value)
  (%buffer rate channels (make-list (* channels frames) :initial-element value)))

(defun %frame-values (buffer)
  "BUFFER's frames as (left right) lists."
  (loop for (l r) on (%samples buffer) by #'cddr collect (list l r)))

(deftest mix-placed-positions
  ;; Rate 8: a stereo buffer at 0.5 s starts at frame 4; FRAMES pads.
  (let ((out (rec:mix-placed (list (cons (%buffer 8 2 (%stereo '(0.5 -0.5) '(0.25 -0.25))) 1/2))
                             :sample-rate 8 :frames 8)))
    (ok (= 8 (audio:pcm-buffer-sample-rate out)))
    (ok (= 2 (audio:pcm-buffer-channels out)))
    (ok (equal '((0.0 0.0) (0.0 0.0) (0.0 0.0) (0.0 0.0) (0.5 -0.5) (0.25 -0.25) (0.0 0.0) (0.0 0.0))
               (%frame-values out)))))

(deftest mix-placed-rounds-start-to-the-nearest-frame
  ;; floor(s * 8 + 1/2): 0.3 s is 2.4 frames -> 2; 5/16 s is 2.5 -> 3 (halves up)
  (flet ((first-frame (start)
           (position-if (lambda (f) (/= 0 (first f)))
                        (%frame-values (rec:mix-placed (list (cons (%const 8 2 1 0.5) start))
                                                       :sample-rate 8 :frames 8)))))
    (ok (= 2 (first-frame 0.3d0)))
    (ok (= 3 (first-frame 5/16)) "a half rounds up")
    (ok (= 2 (first-frame 0.1875d0)) "1.5 frames -> 2")
    (ok (= 0 (first-frame 1/17)))))

(deftest mix-placed-sums-overlaps-in-order
  (let ((out (rec:mix-placed (list (cons (%const 8 2 4 0.25) 0)
                                   (cons (%const 8 2 4 0.5) 1/4))
                             :sample-rate 8)))
    (ok (= 6 (audio:pcm-buffer-frames out)) "the longest placed buffer")
    (ok (equal '((0.25 0.25) (0.25 0.25) (0.75 0.75) (0.75 0.75) (0.5 0.5) (0.5 0.5))
               (%frame-values out)))))

(deftest mix-placed-clamps-and-warns-once
  (let* ((warnings '())
         (out (handler-bind ((audio:samples-clipped
                               (lambda (w) (push w warnings) (muffle-warning w))))
                (rec:mix-placed (list (cons (%const 8 2 2 0.75) 0)
                                      (cons (%const 8 2 2 0.75) 0)
                                      (cons (%const 8 2 2 -0.25) 1/8))
                                :sample-rate 8))))
    (ok (equal '((1.0 1.0) (1.0 1.0) (-0.25 -0.25)) (%frame-values out))
        "1.5 and 1.25 are clamped to 1")
    (ok (= 1 (length warnings)) "one SAMPLES-CLIPPED warning")
    (ok (= 4 (audio:samples-clipped-count (first warnings))))))

(deftest mix-placed-mono-is-both-channels-at-unity
  (let ((out (rec:mix-placed (list (cons (%buffer 8 1 '(0.5 -0.25)) 0)) :sample-rate 8)))
    (ok (equal '((0.5 0.5) (-0.25 -0.25)) (%frame-values out)) "no -3 dB pan law")))

(deftest mix-placed-negative-start-cuts-the-head
  (let ((out (rec:mix-placed (list (cons (%buffer 8 1 '(0.5 0.25 0.125)) -1/4)
                                   (cons (%buffer 8 1 '(0.5)) -1))
                             :sample-rate 8)))
    (ok (equal '((0.125 0.125)) (%frame-values out)) "two frames cut; a buffer wholly before 0 adds nothing")))

(deftest mix-placed-resamples-to-the-mix-rate
  ;; A 16 kHz mono clip at 0.5 s in a 48 kHz mix equals audio-protocol's own
  ;; RESAMPLE of it, on both channels, from frame 24000.
  (let* ((clip (%buffer 16000 1 (loop for i below 1600
                                      collect (* 0.5 (sin (/ (* 2 pi 440 i) 16000))))))
         (resampled (audio:resample clip 48000))
         (out (rec:mix-placed (list (cons clip 1/2)) :sample-rate 48000)))
    (ok (= 48000 (audio:pcm-buffer-sample-rate out)))
    (ok (= (+ 24000 (audio:pcm-buffer-frames resampled)) (audio:pcm-buffer-frames out)))
    (ok (loop for j below (audio:pcm-buffer-frames resampled)
              always (= (audio:sample-ref resampled j 0)
                        (audio:sample-ref out (+ 24000 j) 0)
                        (audio:sample-ref out (+ 24000 j) 1)))
        "sample for sample")
    (ok (loop for j below 24000 always (zerop (audio:sample-ref out j 0))))))

(deftest mix-placed-frames-cuts
  (let ((out (rec:mix-placed (list (cons (%const 8 2 10 0.5) 0)) :sample-rate 8 :frames 3)))
    (ok (= 3 (audio:pcm-buffer-frames out)))))

(deftest mix-placed-empty-and-types
  (ok (null (rec:mix-placed '())))
  (ok (signals (rec:mix-placed (list (cons (%const 8 2 1 0.5) 0)) :sample-rate 0) 'type-error))
  (ok (signals (rec:mix-placed (list (cons (%const 8 2 1 0.5) 0)) :frames -1) 'type-error))
  (ok (signals (rec:mix-placed (list (cons (%buffer 8 3 '(0 0 0)) 0)) :sample-rate 8)
               'audio:audio-mismatch-error)
      "more than two channels: MIX refuses"))

;;; MIX-RECORDING

(defun %recording-with (frames-at &key chunks clips)
  "A hand-made recording: frames at the given timestamps, then CHUNKS added,
   then CLIPS ((buffer . (:at x)) or (buffer . (:epoch x))) written as WAV files and added."
  (let ((r (rec:make-recording :frames (loop for ts in frames-at
                                             for i from 1
                                             collect (rec:make-recording-frame
                                                      :timestamp ts :pathname #p"f.jpg" :index i))))
        (done nil))
    (unwind-protect
         (progn
           (dolist (c chunks) (rec:add-audio-chunk r c))
           (loop for (buffer . place) in clips
                 for i from 0
                 for wav = (merge-pathnames (format nil "clip~d.wav" i) (rec:recording-directory r))
                 do (audio:write-wav buffer wav :encoding :float32)
                    (apply #'rec:add-audio-file r wav place))
           (setf done t))
      (unless done
        (%remove-directory (rec:recording-directory r))))
    r))

(deftest mix-recording-aligns-tracks-to-the-first-frame
  ;; First frame at 1002 (the earliest, though it arrived second). A track
  ;; whose buffer starts at epoch 1003 (rate 8) lands at 1 s = frame 8.
  (let ((r (%recording-with '(1002.5d0 1002d0)
                            :chunks (list (%chunk :seq 0 :frame 16 :rate 8
                                                  :samples (%stereo '(0.5 0.25)))))))
    (unwind-protect
         (let ((out (rec:mix-recording r :sample-rate 8 :frames 12)))
           (ok (= 12 (audio:pcm-buffer-frames out)))
           (ok (equal '(0.5 0.25) (nth 8 (%frame-values out))))
           (ok (every (lambda (f) (equal '(0.0 0.0) f)) (subseq (%frame-values out) 0 8))))
      (%remove-directory (rec:recording-directory r)))))

(deftest mix-recording-audio-before-the-first-frame-is-cut
  (let ((r (%recording-with '(1003.25d0)
                            :chunks (list (%chunk :seq 0 :frame 16 :rate 8 :channels 1
                                                  :samples '(0.5 0.25 0.125 0.0625))))))
    (unwind-protect
         (ok (equal '((0.125 0.125) (0.0625 0.0625))
                    (%frame-values (rec:mix-recording r :sample-rate 8))))
      (%remove-directory (rec:recording-directory r)))))

(deftest mix-recording-clips-at-and-epoch
  (let ((r (%recording-with '(1000d0)
                            :clips (list (cons (%buffer 8 1 '(0.5)) '(:at 1/2))
                                         (cons (%buffer 8 1 '(0.25)) '(:epoch 1000.25d0))))))
    (unwind-protect
         (let ((frames (%frame-values (rec:mix-recording r :sample-rate 8 :frames 6))))
           (ok (equal '(0.25 0.25) (nth 2 frames)) ":epoch 1000.25 is 0.25 s on the clock")
           (ok (equal '(0.5 0.5) (nth 4 frames)) ":at 0.5")
           (ok (= 2 (count-if-not (lambda (f) (equal '(0.0 0.0) f)) frames))))
      (%remove-directory (rec:recording-directory r)))))

(deftest mix-recording-tracks-and-clips-overlap
  (let ((r (%recording-with '(1003d0)
                            :chunks (list (%chunk :seq 0 :frame 16 :rate 8
                                                  :samples (%stereo '(0.25 0.25))))
                            :clips (list (cons (%buffer 8 2 (%stereo '(0.5 -0.5))) '(:at 0))))))
    (unwind-protect
         (ok (equal '((0.75 -0.25)) (%frame-values (rec:mix-recording r :sample-rate 8))))
      (%remove-directory (rec:recording-directory r)))))

(deftest mix-recording-start-overrides-the-frames
  (let ((r (%recording-with '()
                            :clips (list (cons (%buffer 8 1 '(0.5)) '(:epoch 1001d0))))))
    (unwind-protect
         (let ((frames (%frame-values (rec:mix-recording r :sample-rate 8 :start 1000))))
           (ok (equal '(0.5 0.5) (nth 8 frames)) "time 0 is :START"))
      (%remove-directory (rec:recording-directory r)))))

(deftest mix-recording-nothing-to-mix
  (let ((r (%recording-with '(1000d0))))
    (unwind-protect
         (ok (null (rec:mix-recording r)))
      (%remove-directory (rec:recording-directory r)))))

(deftest add-audio-file-clips
  (let ((r (%recording-with '(1000d0)
                            :clips (list (cons (%buffer 16000 1 '(0.5 0.25)) '())
                                         (cons (%buffer 8 2 '(0.5 0.25)) '(:at -1/2))
                                         (cons (%buffer 8 1 '(0.5)) '(:epoch 1001))))))
    (unwind-protect
         (let ((clips (rec:recording-audio-clips r)))
           (ok (= 3 (length clips)))
           (ok (every #'rec:audio-clip-p clips))
           (ok (eql 0 (rec:audio-clip-at (first clips))) "neither: :at 0")
           (ok (null (rec:audio-clip-epoch (first clips))))
           (ok (= 16000 (audio:pcm-buffer-sample-rate (rec:audio-clip-buffer (first clips)))))
           (ok (= -1/2 (rec:audio-clip-at (second clips))))
           (ok (= 1001 (rec:audio-clip-epoch (third clips))))
           (ok (null (rec:audio-clip-at (third clips))))
           (ok (equal (uiop:native-namestring (merge-pathnames "clip2.wav" (rec:recording-directory r)))
                      (uiop:native-namestring (rec:audio-clip-pathname (third clips))))))
      (%remove-directory (rec:recording-directory r)))))

(deftest add-audio-file-errors-reach-the-caller
  (with-made-recording (r)
    (ok (signals (rec:add-audio-file r (merge-pathnames "missing.wav" (rec:recording-directory r)))
                 'file-error))
    (let ((bad (merge-pathnames "bad.wav" (rec:recording-directory r))))
      (%write-octets bad (%octets 1 2 3 4))
      (ok (signals (rec:add-audio-file r bad) 'audio:audio-format-error)))
    (let ((wav (merge-pathnames "ok.wav" (rec:recording-directory r))))
      (audio:write-wav (%buffer 8 1 '(0.5)) wav)
      (ok (signals (rec:add-audio-file r wav :at "1") 'type-error)))
    (ok (null (rec:recording-audio-clips r)))))
