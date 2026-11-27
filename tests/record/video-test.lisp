(in-package #:browser-protocol/record/tests)

;;; VIDEO-SCHEDULE and FFCONCAT-TEXT: frame times to constant-rate slots.
;;; Timestamps are binary fractions, so the expected slots are exact.

(defun %frames-at (&rest offsets)
  "Frames at 1000 + OFFSET seconds, named f0.jpg, f1.jpg, ... in a fixed directory."
  (loop for offset in offsets
        for i from 0
        collect (rec:make-recording-frame
                 :timestamp (+ 1000d0 offset)
                 :pathname (merge-pathnames (format nil "f~d.jpg" i)
                                            (uiop:ensure-directory-pathname
                                             (merge-pathnames "br1-frames/" (uiop:temporary-directory))))
                 :index (1+ i))))

(defun %schedule-counts (entries frames)
  "ENTRIES as (frame-position count) pairs, positions in FRAMES."
  (mapcar (lambda (e) (list (position (car e) frames) (cdr e))) entries))

(deftest-parametrize video-schedule-slots
    ((offsets fps tail expected n)
     :ids ("hold-tail" "no-tail" "short-frame-dropped" "single-frame" "single-frame-tail"
           "tail-not-a-slot-multiple" "fps-30")
     ;; slots at k/4: 0 0.25 0.5 0.75 1.0
     ('(0 0.5d0 0.75d0) 4 0.5d0 '((0 2) (1 1) (2 2)) 5)
     ('(0 0.5d0 0.75d0) 4 0 '((0 2) (1 1) (2 1)) 4)
     ;; 0.3125 is never current at a slot start (0.25 -> f0, 0.5 -> f2)
     ('(0 0.3125d0 0.375d0) 4 0 '((0 2) (2 1)) 3)
     ('(0) 30 0 '((0 1)) 1)
     ('(0) 30 1 '((0 30)) 30)
     ;; ceiling((0.5 + 0.3) * 4) = 4 > ceiling(2) + 1 = 3
     ('(0 0.5d0) 4 0.3d0 '((0 2) (1 2)) 4)
     ;; 1/16 s apart at 30 fps: slot k shows frame floor(16k/30)
     ('(0 0.0625d0 0.125d0 0.1875d0) 30 0 '((0 2) (1 2) (2 2) (3 1)) 7))
  (let ((frames (apply #'%frames-at offsets)))
    (multiple-value-bind (entries slots) (rec:video-schedule frames :fps fps :tail tail)
      (ok (equal expected (%schedule-counts entries frames))
          (format nil "entries ~s" (%schedule-counts entries frames)))
      (ok (= n slots) (format nil "~d slots" slots))
      (ok (= slots (reduce #'+ entries :key #'cdr)) "the counts add up to N")
      (ok (every (lambda (e) (member (car e) frames :test #'eq)) entries)
          "entries hold the frames themselves"))))

(deftest video-schedule-sorts-frames-by-time
  (let* ((frames (%frames-at 0 0.5d0 0.75d0))
         (shuffled (list (third frames) (first frames) (second frames))))
    (multiple-value-bind (entries slots) (rec:video-schedule shuffled :fps 4 :tail 0.5d0)
      (ok (equal (list (cons (first frames) 2) (cons (second frames) 1) (cons (third frames) 2))
                 entries))
      (ok (= 5 slots)))))

(deftest video-schedule-equal-timestamps-last-arrival-wins
  ;; Two frames with one timestamp: only the later in FRAMES can be shown.
  (let* ((frames (%frames-at 0 0.5d0 0.5d0 0.75d0))
         (early (second frames))
         (late (third frames)))
    (let ((entries (rec:video-schedule frames :fps 4 :tail 0)))
      (ok (not (find early entries :key #'car)) "the earlier duplicate gets no slot")
      (ok (eql 1 (cdr (find late entries :key #'car))) "the later one gets the slot"))
    ;; Same with the later one first in time order but last in the list
    ;; (arrival order is the list's order, not the index slot).
    (let ((entries (rec:video-schedule (list (first frames) late early (fourth frames))
                                       :fps 4 :tail 0)))
      (ok (find early entries :key #'car) "now EARLY arrived later")
      (ok (not (find late entries :key #'car))))))

(deftest video-schedule-relative-to-the-earliest-frame
  ;; Only differences count: shifting every timestamp changes nothing.
  (let ((a (rec:video-schedule (%frames-at 0 0.5d0) :fps 4 :tail 0))
        (b (rec:video-schedule (mapcar (lambda (f)
                                         (rec:make-recording-frame
                                          :timestamp (+ 5000 (rec:recording-frame-timestamp f))
                                          :pathname (rec:recording-frame-pathname f)))
                                       (%frames-at 0 0.5d0))
                               :fps 4 :tail 0)))
    (ok (equal (mapcar #'cdr a) (mapcar #'cdr b)))))

(deftest video-schedule-argument-types
  (let ((frames (%frames-at 0)))
    (ok (signals (rec:video-schedule frames :fps 0) 'type-error))
    (ok (signals (rec:video-schedule frames :fps 2.5) 'type-error))
    (ok (signals (rec:video-schedule frames :tail -1) 'type-error))
    (ok (signals (rec:video-schedule frames :tail "1") 'type-error))))

(defun %quoted (frame)
  (format nil "file '~a'" (uiop:native-namestring (rec:recording-frame-pathname frame))))

(defun %ffconcat (fps &rest slots)
  "The expected list: SLOTS are (frame duration-string), one per slot."
  (with-output-to-string (s)
    (format s "ffconcat version 1.0~%")
    (loop for (frame duration) in slots
          do (format s "~a~%option framerate ~d~%duration ~a~%" (%quoted frame) fps duration))
    (format s "~a~%option framerate ~d~%" (%quoted (first (car (last slots)))) fps)))

(deftest ffconcat-text-one-entry-per-slot
  ;; fps 4: slots 0 0.25 0.5 0.75 1.0 show f0 f0 f1 f2 f2.
  (destructuring-bind (f0 f1 f2) (%frames-at 0 0.5d0 0.75d0)
    (ok (equal (%ffconcat 4 (list f0 "0.250000") (list f0 "0.250000") (list f1 "0.250000")
                          (list f2 "0.250000") (list f2 "0.250000"))
               (rec:ffconcat-text (list f0 f1 f2) :fps 4 :tail 0.5d0)))))

(deftest ffconcat-text-rounds-boundaries-not-durations
  ;; fps 3: boundaries 0, 333333, 666667, 1000000 microseconds. Rounding each
  ;; duration alone would give 0.333333 three times (0.999999 s).
  (destructuring-bind (f0 f1 f2) (%frames-at 0 0.25d0 0.5d0)
    (ok (equal (%ffconcat 3 (list f0 "0.333333") (list f1 "0.333334") (list f2 "0.333333"))
               (rec:ffconcat-text (list f0 f1 f2) :fps 3 :tail 0)))))

(deftest ffconcat-text-whole-seconds
  (destructuring-bind (f0) (%frames-at 0)
    (ok (equal (%ffconcat 1 (list f0 "1.000000") (list f0 "1.000000"))
               (rec:ffconcat-text (list f0) :fps 1 :tail 2)))))

(deftest ffconcat-text-no-drift-over-many-frames
  ;; 64 frames 1/16 s apart at 30 fps: the durations add up to N / 30 within
  ;; a microsecond, wherever the boundaries fall.
  (let* ((frames (apply #'%frames-at (loop for i below 64 collect (/ i 16d0))))
         (text (rec:ffconcat-text frames :fps 30 :tail 0))
         (slots (nth-value 1 (rec:video-schedule frames :fps 30 :tail 0)))
         (micros (loop for line in (uiop:split-string text :separator '(#\Newline))
                       when (uiop:string-prefix-p "duration " line)
                         sum (let* ((s (subseq line 9))
                                    (dot (position #\. s)))
                               (+ (* 1000000 (parse-integer s :end dot))
                                  (parse-integer s :start (1+ dot)))))))
    (ok (= micros (round (* slots 1000000) 30)) (format nil "~d us for ~d slots" micros slots))))

(deftest ffconcat-text-quotes-single-quotes
  (let ((frame (rec:make-recording-frame
                :timestamp 1000
                :pathname (merge-pathnames "it's.jpg" (%scratch-directory "quote")))))
    (unwind-protect
         (ok (search (format nil "file '~a'\\''~a'"
                             (let ((n (uiop:native-namestring (rec:recording-frame-pathname frame))))
                               (subseq n 0 (search "'s.jpg" n)))
                             "s.jpg")
                     (rec:ffconcat-text (list frame) :fps 30 :tail 0)))
      (%remove-directory (uiop:pathname-directory-pathname (rec:recording-frame-pathname frame))))))

(deftest ffconcat-text-relative-paths-are-made-absolute
  (let* ((frame (rec:make-recording-frame :timestamp 1000 :pathname #p"rel/f.jpg"))
         (text (rec:ffconcat-text (list frame) :fps 30 :tail 0)))
    (ok (search (format nil "file '~a'"
                        (uiop:native-namestring (merge-pathnames (merge-pathnames #p"rel/f.jpg")
                                                                 (uiop:getcwd))))
                text))))
