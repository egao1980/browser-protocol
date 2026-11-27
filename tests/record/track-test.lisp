(in-package #:browser-protocol/record/tests)

;;; ADD-AUDIO-CHUNK and TRACK-BUFFER: chunks filed into tracks, assembled at
;;; exact frame positions.

(defun %mono-chunk (seq frame samples &rest keys)
  (apply #'%chunk :seq seq :frame frame :channels 1 :rate 8 :samples samples keys))

(deftest add-audio-chunk-makes-tracks-in-order
  (with-made-recording (r)
    (let ((a (rec:add-audio-chunk r (%chunk :track "d/1" :seq 0)))
          (b (rec:add-audio-chunk r (%chunk :track "d/2" :seq 0 :rate 44100)))
          (a2 (rec:add-audio-chunk r (%chunk :track "d/1" :seq 1))))
      (ok (eq a a2) "one track per id")
      (ok (equal (list a b) (rec:recording-audio-tracks r)) "in the order they started")
      (ok (equal "d/2" (rec:audio-track-id b)))
      (ok (= 44100 (rec:audio-track-sample-rate b)))
      (ok (= 2 (rec:audio-track-channels a)))
      (ok (equal '(0 1) (mapcar #'rec:audio-chunk-seq (rec:audio-track-chunks a)))))))

(deftest add-audio-chunk-keeps-seq-order-and-drops-duplicates
  (with-made-recording (r)
    (let* ((first-three (%chunk :seq 3 :samples '(0.25 0.25)))
           (track (rec:add-audio-chunk r first-three)))
      (rec:add-audio-chunk r (%chunk :seq 1))
      (rec:add-audio-chunk r (%chunk :seq 2))
      (ok (eq track (rec:add-audio-chunk r (%chunk :seq 3 :samples '(0.5 0.5))))
          "a duplicate SEQ still returns the track")
      (rec:add-audio-chunk r (%chunk :seq 0))
      (ok (equal '(0 1 2 3) (mapcar #'rec:audio-chunk-seq (rec:audio-track-chunks track))))
      (ok (eq first-three (find 3 (rec:audio-track-chunks track) :key #'rec:audio-chunk-seq))
          "the first chunk with a SEQ stays")
      (ok (null (rec:recording-warnings r)) "duplicates are dropped quietly"))))

(deftest add-audio-chunk-drops-a-mismatched-chunk-with-a-warning
  (with-made-recording (r)
    (rec:add-audio-chunk r (%chunk :seq 0 :rate 48000 :channels 2))
    (let ((warned nil))
      (handler-bind ((rec:recording-warning
                       (lambda (w) (setf warned w) (muffle-warning w))))
        (ok (null (rec:add-audio-chunk r (%chunk :seq 1 :rate 44100 :channels 2)))
            "another rate: NIL")
        (ok (null (rec:add-audio-chunk r (%chunk :seq 2 :rate 48000 :channels 1
                                                 :samples '(0.5))))
            "another channel count: NIL"))
      (ok (typep warned 'rec:recording-warning) "signalled with WARN")
      (ok (= 2 (length (rec:recording-warnings r))) "and kept")
      (ok (eq r (rec:recording-warning-recording (first (rec:recording-warnings r)))))
      (ok (equal '(0) (mapcar #'rec:audio-chunk-seq
                              (rec:audio-track-chunks (first (rec:recording-audio-tracks r)))))))))

(defun %track (&rest chunks)
  (with-made-recording (r)
    (let ((track nil))
      (dolist (c chunks track)
        (setf track (rec:add-audio-chunk r c))))))

(deftest track-buffer-places-chunks-at-their-frames
  ;; Rate 8: frames 16..17 then a gap 18..19 then 20..21.
  (let ((track (%track (%mono-chunk 0 16 '(0.5 0.25))
                       (%mono-chunk 2 20 '(-0.5 -0.25)))))
    (multiple-value-bind (buffer start) (rec:track-buffer track)
      (ok (= 8 (audio:pcm-buffer-sample-rate buffer)))
      (ok (= 1 (audio:pcm-buffer-channels buffer)))
      (ok (= 6 (audio:pcm-buffer-frames buffer)) "smallest frame .. largest end")
      (ok (equal '(0.5 0.25 0.0 0.0 -0.5 -0.25) (%samples buffer)) "the gap stays silent")
      ;; seq 0 maps: (1000000 + 1000)/1000 + 16/8 - 0 = 1003
      (ok (= 1003 start)))))

(deftest track-buffer-order-of-arrival-does-not-matter
  (let ((a (%track (%mono-chunk 0 0 '(0.5)) (%mono-chunk 1 1 '(0.25)) (%mono-chunk 2 2 '(0.125))))
        (b (%track (%mono-chunk 2 2 '(0.125)) (%mono-chunk 0 0 '(0.5)) (%mono-chunk 1 1 '(0.25)))))
    (ok (equalp (rec:track-buffer a) (rec:track-buffer b)))
    (ok (= (nth-value 1 (rec:track-buffer a)) (nth-value 1 (rec:track-buffer b))))))

(deftest track-buffer-larger-seq-wins-an-overlap
  (let ((track (%track (%mono-chunk 1 2 '(0.25 0.25 0.25))
                       (%mono-chunk 0 0 '(0.5 0.5 0.5)))))
    (ok (equal '(0.5 0.5 0.25 0.25 0.25) (%samples (rec:track-buffer track))))))

(deftest track-buffer-start-uses-the-smallest-seq-mapping
  ;; Seq 1 starts earlier in frames (an out-of-order frame number) and has
  ;; another mapping: the buffer starts at its frame, timed by seq 0's mapping.
  (let ((track (%track (%mono-chunk 0 8 '(0.5) :performance-time 2000 :context-time 0)
                       (%mono-chunk 1 4 '(0.25) :performance-time 9000 :context-time 3))))
    (multiple-value-bind (buffer start) (rec:track-buffer track)
      (ok (= 5 (audio:pcm-buffer-frames buffer)))
      ;; seq 0: (1000000 + 2000)/1000 + 8/8 - 0 = 1003; frame 4 is 4/8 s earlier
      (ok (= (- 1003 1/2) start)))))

(deftest track-buffer-stereo-and-negative-frames
  (let ((track (%track (%chunk :seq 0 :frame -2 :rate 8 :samples (%stereo '(0.5 -0.5) '(0.25 -0.25)))
                       (%chunk :seq 1 :frame 0 :rate 8 :samples (%stereo '(0.125 -0.125))))))
    (multiple-value-bind (buffer start) (rec:track-buffer track)
      (ok (= 2 (audio:pcm-buffer-channels buffer)))
      (ok (equal (%stereo '(0.5 -0.5) '(0.25 -0.25) '(0.125 -0.125)) (%samples buffer)))
      ;; (1000000 + 1000)/1000 + (-2)/8 - 0
      (ok (= (- 1001 1/4) start)))))

(deftest track-buffer-of-an-empty-track
  (multiple-value-bind (buffer start)
      (rec:track-buffer (with-made-recording (r)
                          (let ((track (rec:add-audio-chunk r (%chunk :seq 0))))
                            (setf (rec:audio-track-chunks track) '())
                            track)))
    (ok (null buffer))
    (ok (null start))))
