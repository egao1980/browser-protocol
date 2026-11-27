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

(defun %existing-file (pathname)
  "PATHNAME, as given, when it names an existing file (not a directory); else
NIL. Symbolic links are followed only to test, never in the result."
  (and pathname
       (uiop:file-exists-p pathname)
       pathname))

(defun %program-name (name)
  "NAME, with .exe on Windows when it has no type."
  (if (and (uiop:os-windows-p) (null (pathname-type (uiop:parse-unix-namestring name))))
      (concatenate 'string name ".exe")
      name))

(defun %on-path (name)
  "The first existing file NAME in a directory of PATH, in PATH's order, as
built (the directory merged with NAME); NIL when there is none."
  (let ((file (uiop:parse-unix-namestring (%program-name name))))
    (loop for dir in (uiop:split-string (or (uiop:getenv "PATH") "")
                                        :separator (string (uiop:inter-directory-separator)))
          for found = (and (plusp (length dir))
                           (%existing-file
                            (merge-pathnames file (uiop:ensure-directory-pathname
                                                   (uiop:parse-native-namestring dir)))))
          when found
            return found)))

(defun find-ffmpeg ()
  "The ffmpeg program to run, or NIL (file header)."
  (let* ((env (uiop:getenv "FFMPEG_PATH"))
         (found (or (and env (plusp (length env))
                         (%existing-file (uiop:parse-native-namestring env)))
                    (%on-path "ffmpeg")
                    (some (lambda (candidate)
                            (%existing-file (uiop:parse-native-namestring candidate)))
                          *ffmpeg-executable-candidates*))))
    (and found (uiop:native-namestring found))))

(defun %absolute-native (pathname)
  "PATHNAME made absolute, as a native namestring."
  (uiop:native-namestring (merge-pathnames (merge-pathnames pathname) (uiop:getcwd))))

(defun ffmpeg-arguments (concat-file output &key (fps +default-fps+) slots audio-file)
  "The ffmpeg command line WRITE-VIDEO runs, after the program (file header)."
  (check-type fps (integer 1))
  (check-type slots (integer 1))
  (append (list "-nostdin" "-hide_banner" "-loglevel" "error" "-xerror" "-y"
                "-f" "concat" "-safe" "0" "-reinit_filter" "0"
                "-i" (%absolute-native concat-file))
          (when audio-file
            (list "-i" (%absolute-native audio-file) "-map" "0:v:0" "-map" "1:a:0"))
          (list "-vf" "scale=trunc(iw/2)*2:trunc(ih/2)*2:eval=init:out_range=tv,format=yuv420p"
                "-r" (format nil "~d" fps) "-fps_mode" "cfr" "-frames:v" (format nil "~d" slots)
                "-c:v" "libx264" "-pix_fmt" "yuv420p")
          (when audio-file
            (list "-c:a" "aac" "-b:a" "128k"))
          (list "-movflags" "+faststart" (%absolute-native output))))

(defun %stderr-tail (text)
  "The last +FFMPEG-STDERR-TAIL-LINES+ lines of TEXT, without carriage
returns or the empty line a final newline leaves, joined with #\\Newline."
  (let ((lines (mapcar (lambda (line)
                         (let ((n (length line)))
                           (if (and (plusp n) (char= #\Return (char line (1- n))))
                               (subseq line 0 (1- n))
                               line)))
                       (uiop:split-string (or text "") :separator '(#\Newline)))))
    (when (and lines (string= "" (car (last lines))))
      (setf lines (butlast lines)))
    (format nil "~{~a~^~%~}" (last lines +ffmpeg-stderr-tail-lines+))))

(defun %resolve-program (designator)
  "(values pathname tried): the program DESIGNATOR (a pathname designator, or
NIL) names, or NIL when no file; TRIED is what was looked for, a native
namestring, or NIL."
  (if (null designator)
      (values nil nil)
      (let* ((pathname (if (stringp designator)
                           (uiop:parse-native-namestring designator)
                           (pathname designator)))
             (tried (uiop:native-namestring pathname)))
        (values (if (pathname-directory pathname)
                    (%existing-file pathname)
                    (%on-path tried))
                tried))))

(defun %run-ffmpeg-once (arguments program)
  "Run PROGRAM (a designator, or NIL for *FFMPEG-PROGRAM* / FIND-FFMPEG) once:
its standard error, or FFMPEG-NOT-FOUND / FFMPEG-ERROR."
  (multiple-value-bind (pathname tried)
      (%resolve-program (or program *ffmpeg-program* (find-ffmpeg)))
    (unless pathname
      (error 'ffmpeg-not-found :program tried :arguments arguments))
    (let ((native (uiop:native-namestring pathname)))
      (multiple-value-bind (code output stderr)
          (handler-case (stack-process:run (cons native arguments)
                                           :output nil :error-output :string)
            (process-protocol:process-error (c)
              (error 'ffmpeg-not-found
                     :program native :arguments arguments :cause c
                     :message (format nil "cannot start ~a: ~a" native c))))
        (declare (ignore output))
        (unless (eql code 0)
          (error 'ffmpeg-error :program native :arguments arguments :exit-code code
                               :stderr-tail (%stderr-tail stderr)))
        stderr))))

(defun run-ffmpeg (arguments &key program)
  "Run ffmpeg with ARGUMENTS; its standard error, or FFMPEG-ERROR (file header)."
  (check-type arguments list)
  (let ((designator program))
    (loop
      (restart-case (return-from run-ffmpeg (%run-ffmpeg-once arguments designator))
        (browser-protocol::retry ()
          :report "Run ffmpeg again, finding the program again."
          nil)
        (use-value (other)
          :report "Run another ffmpeg program."
          :interactive (lambda ()
                         (format *query-io* "ffmpeg program: ")
                         (force-output *query-io*)
                         (list (read-line *query-io*)))
          (setf designator other))))))
