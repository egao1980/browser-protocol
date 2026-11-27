;;;; Frame timing: screencast frames, which arrive when the page paints, to a
;;;; constant frame rate. Pure: no browser, no ffmpeg.
;;;;
;;;; Times. Each frame's time on the recording's clock is
;;;;     t_i = (rational timestamp_i) - (rational timestamp_min)
;;;; an exact rational, timestamp_min the smallest TIMESTAMP of FRAMES. The
;;;; frames are ordered by t_i with a STABLE sort, so frames of equal timestamp
;;;; keep their order in FRAMES (arrival order).
;;;;
;;;; Slots. The video has N slots, slot k (0 <= k < N) starting at time k / FPS.
;;;; Slot k shows the frame current at its start: the LAST frame, in that
;;;; order, with t_i <= k / FPS. So a frame shorter than a slot may never be
;;;; shown, and of frames with one timestamp only the last can be. With t_last
;;;; the largest t_i,
;;;;     N = max( ceiling((t_last + TAIL) * FPS), ceiling(t_last * FPS) + 1 )
;;;; so the last frame is held for TAIL seconds, and shown for at least one slot.
;;;;
;;;; (VIDEO-SCHEDULE frames &key (fps +default-fps+) (tail 0))
;;;;   -> (values entries n)
;;;;   FRAMES a list of RECORDING-FRAMEs, in any order; FPS a positive integer;
;;;;   TAIL a non-negative real (seconds). Wrong types: TYPE-ERROR (CHECK-TYPE).
;;;;   No frames: RECORDING-NO-FRAMES (no restarts here).
;;;;   ENTRIES is a fresh list of (frame . count), the frames that get a slot,
;;;;   in the order they are shown, each with its number of consecutive slots
;;;;   (count >= 1); the counts sum to N. The frames are the objects of FRAMES
;;;;   (EQ).
;;;;
;;;; (FFCONCAT-TEXT frames &key (fps +default-fps+) (tail 0)) -> a string: the
;;;;   ffmpeg concat-demuxer list of the schedule, ONE ENTRY PER SLOT, every
;;;;   line ended by #\Newline:
;;;;     ffconcat version 1.0
;;;;     file '<path of the frame slot 0 shows>'
;;;;     option framerate <fps>
;;;;     duration <d0>
;;;;     ...                                  (slots 1 .. N-1 the same way)
;;;;     file '<path of the frame slot N-1 shows>'
;;;;     option framerate <fps>
;;;;   The last slot's file is listed once more, with its option line and no
;;;;   duration (the concat demuxer needs it to keep the last duration).
;;;;   <fps> in decimal. <path> is the frame's PATHNAME made absolute,
;;;;   (uiop:native-namestring (merge-pathnames (merge-pathnames pathname)
;;;;   (uiop:getcwd))) (WRITE-VIDEO runs ffmpeg with -safe 0), each ' in it
;;;;   written as '\''. Slot k lasts
;;;;       round((k + 1) * 10^6 / FPS) - round(k * 10^6 / FPS)   microseconds
;;;;   (CL:ROUND, halves to even): slot boundaries rounded to whole
;;;;   microseconds, so the durations add up without drift. Each is written as
;;;;   seconds with exactly six decimals: 33333 microseconds is "0.033333",
;;;;   1 second "1.000000".
;;;;   Why one entry per slot, each file at framerate FPS: the concat demuxer
;;;;   takes its time base from the first file (1/25 s for a JPEG), and
;;;;   ffmpeg's constant-rate conversion starts a frame at slot
;;;;   llrint(pts - 0.6) of the previous one's run; a list of runs lands frames
;;;;   a slot early or late (ffmpeg 9.0: 0.766667 s read as 0.76 s; a frame at
;;;;   an exact slot start shown one slot early). Files at framerate FPS give
;;;;   time base 1 / FPS, every entry starts exactly at its slot, and the
;;;;   input is already constant-rate, so ffmpeg maps it 1:1.
;;;;   Same arguments and conditions as VIDEO-SCHEDULE.

(in-package #:browser-protocol/record)

(defun video-schedule (frames &key (fps +default-fps+) (tail 0))
  "The constant-frame-rate schedule of FRAMES (file header)."
  (declare (ignore frames fps tail))
  (%br1-pending 'video-schedule))

(defun ffconcat-text (frames &key (fps +default-fps+) (tail 0))
  "The ffmpeg concat list of FRAMES' schedule (file header)."
  (declare (ignore frames fps tail))
  (%br1-pending 'ffconcat-text))
