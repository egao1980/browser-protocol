;;;; ffmpeg, out of process through process-protocol (STACK-PROCESS, backend
;;;; process-backend-uiop).
;;;;
;;;; (FIND-FFMPEG) -> a native namestring, or NIL. The first of these that names
;;;;   an existing file (not a directory): the environment variable FFMPEG_PATH
;;;;   when it is not empty; "ffmpeg" ("ffmpeg.exe" on Windows) in a directory
;;;;   of PATH, in PATH's order; each of *FFMPEG-EXECUTABLE-CANDIDATES*. The
;;;;   result is that path as built (the PATH directory merged with the name),
;;;;   symbolic links not resolved.
;;;;
;;;; (FFMPEG-ARGUMENTS concat-file output &key (fps +default-fps+) slots
;;;;   audio-file) -> a fresh list of strings, the command line after the program
;;;;   name. CONCAT-FILE (an FFCONCAT-TEXT list), OUTPUT and AUDIO-FILE (a WAV,
;;;;   or NIL) are pathname designators, each written absolute, as
;;;;   (uiop:native-namestring (merge-pathnames (merge-pathnames p)
;;;;   (uiop:getcwd))). FPS and SLOTS
;;;;   are positive integers (else TYPE-ERROR), written in decimal. Exactly:
;;;;     -nostdin -hide_banner -loglevel error -xerror -y
;;;;     -f concat -safe 0 -reinit_filter 0 -i <concat-file>
;;;;     -i <audio-file> -map 0:v:0 -map 1:a:0          (only with AUDIO-FILE)
;;;;     -vf scale=trunc(iw/2)*2:trunc(ih/2)*2:eval=init:out_range=tv,format=yuv420p
;;;;     -r <fps> -fps_mode cfr -frames:v <slots>
;;;;     -c:v libx264 -pix_fmt yuv420p
;;;;     -c:a aac -b:a 128k                             (only with AUDIO-FILE)
;;;;     -movflags +faststart <output>
;;;;   one string per word. So: a frame ffmpeg cannot decode fails the run
;;;;   (-xerror; without it ffmpeg skips the frame and exits 0); H.264 in
;;;;   yuv420p with limited range; the size of
;;;;   the first frame rounded down to even numbers, and frames of another size
;;;;   (a viewport change) scaled to it (-reinit_filter 0 with eval=init keeps
;;;;   one filter graph); exactly SLOTS frames at FPS; AAC; the index at the
;;;;   front (+faststart). Without AUDIO-FILE the file has no audio stream.
;;;;
;;;; (RUN-FFMPEG arguments &key program) -> ffmpeg's standard error, a string.
;;;;   The program is PROGRAM, else *FFMPEG-PROGRAM*, else (FIND-FFMPEG): a
;;;;   pathname designator. One with no directory part is looked up in PATH as
;;;;   FIND-FFMPEG does; one naming no existing file, or NIL, signals
;;;;   FFMPEG-NOT-FOUND (PROGRAM what was tried, as a string, or NIL). It runs
;;;;     (stack-process:run (cons program arguments) :output nil :error-output :string)
;;;;   with PROGRAM as a native namestring; a PROCESS-PROTOCOL:PROCESS-ERROR
;;;;   while starting it is FFMPEG-NOT-FOUND with that CAUSE. Exit code 0: the
;;;;   standard error is returned. Any other: FFMPEG-ERROR with PROGRAM,
;;;;   ARGUMENTS (as given), EXIT-CODE and STDERR-TAIL: the last
;;;;   +FFMPEG-STDERR-TAIL-LINES+ lines of the standard error (split at
;;;;   #\Newline, a #\Return ending a line dropped, no empty line for a final
;;;;   newline), joined with #\Newline.
;;;;   Both conditions are signalled inside two restarts:
;;;;   * BROWSER-PROTOCOL::RETRY (BROWSER-PROTOCOL:INVOKE-RETRY): start again,
;;;;     finding the program again the same way (an ffmpeg installed since is
;;;;     found);
;;;;   * USE-VALUE program: start again with PROGRAM instead.
;;;;   A failure after either restart signals again, inside the same restarts.

(in-package #:browser-protocol/record)

(defun find-ffmpeg ()
  "The ffmpeg program to run, or NIL (file header)."
  (%br1-pending 'find-ffmpeg))

(defun ffmpeg-arguments (concat-file output &key (fps +default-fps+) slots audio-file)
  "The ffmpeg command line WRITE-VIDEO runs, after the program (file header)."
  (declare (ignore concat-file output fps slots audio-file))
  (%br1-pending 'ffmpeg-arguments))

(defun run-ffmpeg (arguments &key program)
  "Run ffmpeg with ARGUMENTS; its standard error, or FFMPEG-ERROR (file header)."
  (declare (ignore arguments program))
  (%br1-pending 'run-ffmpeg))
