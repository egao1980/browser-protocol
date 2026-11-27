(in-package #:browser-protocol/record/tests)

;;; The model (given) and DISCARD-RECORDING.

(defun %frame (timestamp &optional (name "f.jpg") (index 0))
  (rec:make-recording-frame :timestamp timestamp :pathname (pathname name) :index index))

(deftest constants
  (ok (equal "__browserProtocolRecordAudio" rec:+audio-binding-name+))
  (ok (equal "__browserProtocolRecord" rec:+audio-tap-global+))
  (ok (= 2048 rec:+audio-tap-buffer-size+))
  (ok (= 30 rec:+default-fps+))
  (ok (= 48000 rec:+default-sample-rate+))
  (ok (= 20 rec:+ffmpeg-stderr-tail-lines+)))

(deftest make-recording-holds-frames
  (let ((frames (list (%frame 1000.5d0 "b.jpg" 2) (%frame 1000.25d0 "a.jpg" 1))))
    (with-made-recording (r :frames frames)
      (ok (not (rec:recording-active-p r)))
      (ok (null (rec:recording-backend r)))
      (ok (equal frames (rec:recording-frames r)) "arrival order as given")
      (ok (not (eq frames (rec:recording-frames r))) "a fresh list")
      (ok (eql 1000.25d0 (rec:recording-start-time r)) "the smallest timestamp, as stored")
      (ok (null (rec:recording-stop-time r)))
      (ok (null (rec:recording-audio-tracks r)))
      (ok (null (rec:recording-audio-clips r)))
      (ok (null (rec:recording-warnings r)))
      (ok (uiop:directory-pathname-p (rec:recording-directory r)))
      (ok (probe-file (rec:recording-directory r)) "a temporary directory exists"))))

(deftest start-time-without-frames-is-nil
  (with-made-recording (r)
    (ok (null (rec:recording-start-time r)))))

(deftest make-recording-in-a-given-directory
  (let* ((parent (%scratch-directory "given"))
         (dir (merge-pathnames "sub/" parent)))
    (unwind-protect
         (let ((r (rec:make-recording :directory dir)))
           (ok (probe-file dir) "created when missing")
           (ok (equal (uiop:native-namestring dir)
                      (uiop:native-namestring (rec:recording-directory r)))))
      (%remove-directory parent))))

(deftest audio-chunk-frames-counts-frames
  (ok (= 3 (rec:audio-chunk-frames
            (rec:make-audio-chunk :channels 2
                                  :samples (make-array 6 :element-type 'single-float
                                                         :initial-element 0.0)))))
  (ok (= 6 (rec:audio-chunk-frames
            (rec:make-audio-chunk :channels 1
                                  :samples (make-array 6 :element-type 'single-float
                                                         :initial-element 0.0))))))

(deftest discard-deletes-a-temporary-directory
  (let* ((r (rec:make-recording))
         (dir (rec:recording-directory r)))
    (%write-octets (merge-pathnames "frame-000001.jpg" dir) +jpeg-a+)
    (unwind-protect
         (progn
           (ok (eq t (rec:discard-recording r)))
           (ok (not (probe-file dir)) "the directory is gone"))
      (%remove-directory dir))))

(deftest discard-leaves-a-given-directory
  (let* ((dir (%scratch-directory "keep"))
         (r (rec:make-recording :directory dir)))
    (%write-octets (merge-pathnames "frame-000001.jpg" dir) +jpeg-a+)
    (unwind-protect
         (progn
           (ok (eq t (rec:discard-recording r)))
           (ok (probe-file (merge-pathnames "frame-000001.jpg" dir)) "a caller's directory stays"))
      (%remove-directory dir))))
