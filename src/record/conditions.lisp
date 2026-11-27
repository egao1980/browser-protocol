;;;; Conditions (CLHS 9). Given in the contract: not stubbed.
;;;;
;;;; Every error is a BROWSER-PROTOCOL:BROWSER-ERROR (message, url, method,
;;;; cause slots and their readers):
;;;;
;;;;   browser-error
;;;;   └── recording-error              RECORDING (or NIL)
;;;;       ├── recording-stopped        STOP-RECORDING on a recording that is not
;;;;       │                            active. Restart CONTINUE: STOP-RECORDING
;;;;       │                            returns the recording unchanged.
;;;;       ├── recording-no-frames      WRITE-VIDEO (or VIDEO-SCHEDULE, or
;;;;       │                            MIX-RECORDING with no :START) with no
;;;;       │                            frames. WRITE-VIDEO's restarts: USE-VALUE
;;;;       │                            (a list of RECORDING-FRAMEs to write
;;;;       │                            instead) and CONTINUE (write nothing,
;;;;       │                            WRITE-VIDEO returns NIL).
;;;;       └── ffmpeg-error             ffmpeg ran and exited with a nonzero code.
;;;;           │                        PROGRAM (the native namestring run),
;;;;           │                        ARGUMENTS (the list of strings after it),
;;;;           │                        EXIT-CODE, STDERR-TAIL (the last
;;;;           │                        +FFMPEG-STDERR-TAIL-LINES+ lines of its
;;;;           │                        standard error, a string). Restarts (in
;;;;           │                        RUN-FFMPEG): BROWSER-PROTOCOL::RETRY (run
;;;;           │                        it again, BROWSER-PROTOCOL:INVOKE-RETRY)
;;;;           │                        and USE-VALUE (run this program instead).
;;;;           └── ffmpeg-not-found     No ffmpeg to run (FIND-FFMPEG found none,
;;;;                                    or the program given is not a file):
;;;;                                    EXIT-CODE and STDERR-TAIL are NIL,
;;;;                                    PROGRAM what was tried (or NIL). Same
;;;;                                    restarts.
;;;;
;;;; RECORDING-WARNING (WARNING) is what a recording drops: a screencast frame or
;;;; an audio payload it cannot use (bad base64, no timestamp, JSON that is not a
;;;; chunk, a chunk whose rate or channels differ from its track's). Slots
;;;; RECORDING and REASON (a string). The event handlers run on whichever thread
;;;; reads the CDP transport (often the recording's own reader thread), so each
;;;; such warning is also kept, oldest first, in RECORDING-WARNINGS; it is
;;;; signalled with WARN (MUFFLE-WARNING) on that thread.

(in-package #:browser-protocol/record)

(define-condition recording-error (browser-protocol:browser-error)
  ((recording :initarg :recording :initform nil :reader recording-error-recording))
  (:report (lambda (c s)
             (format s "recording error~@[: ~a~]" (browser-protocol:browser-error-message c))))
  (:documentation "Root of the conditions browser-protocol/record signals."))

(define-condition recording-stopped (recording-error)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "the recording is not active: it was stopped already")))
  (:documentation "STOP-RECORDING on a recording that is not active (restart CONTINUE)."))

(define-condition recording-no-frames (recording-error)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "the recording has no frames: the page painted nothing while it ran")))
  (:documentation "No screencast frame to make a video of (restarts USE-VALUE, CONTINUE in WRITE-VIDEO)."))

(define-condition ffmpeg-error (recording-error)
  ((program :initarg :program :initform nil :reader ffmpeg-error-program)
   (arguments :initarg :arguments :initform nil :reader ffmpeg-error-arguments)
   (exit-code :initarg :exit-code :initform nil :reader ffmpeg-error-exit-code)
   (stderr-tail :initarg :stderr-tail :initform nil :reader ffmpeg-error-stderr-tail))
  (:report (lambda (c s)
             (format s "ffmpeg~@[ (~a)~] exited with code ~a~@[:~%~a~]"
                     (ffmpeg-error-program c)
                     (ffmpeg-error-exit-code c)
                     (let ((tail (ffmpeg-error-stderr-tail c)))
                       (and tail (plusp (length tail)) tail)))))
  (:documentation "ffmpeg exited with a nonzero code (restarts RETRY, USE-VALUE in RUN-FFMPEG)."))

(define-condition ffmpeg-not-found (ffmpeg-error)
  ()
  (:report (lambda (c s)
             (format s "no ffmpeg to run~@[: ~a is not a program~]; install ffmpeg, put it on PATH, set FFMPEG_PATH or bind *FFMPEG-PROGRAM*"
                     (ffmpeg-error-program c))))
  (:documentation "No ffmpeg program (restarts RETRY, USE-VALUE in RUN-FFMPEG)."))

(define-condition recording-warning (warning)
  ((recording :initarg :recording :initform nil :reader recording-warning-recording)
   (reason :initarg :reason :initform "" :reader recording-warning-reason))
  (:report (lambda (c s)
             (format s "recording: dropped ~a" (recording-warning-reason c))))
  (:documentation "Something a recording received and could not use (kept in RECORDING-WARNINGS)."))
