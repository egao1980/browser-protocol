;;;; The model. Given in the contract: not stubbed.
;;;;
;;;; Constants and parameters
;;;;   +AUDIO-BINDING-NAME+   "__browserProtocolRecordAudio": the Runtime binding
;;;;                          the page tap calls with each PCM chunk (tap.lisp).
;;;;   +AUDIO-TAP-GLOBAL+     "__browserProtocolRecord": the page global (not
;;;;                          enumerable) whose start() / stop() the recording
;;;;                          calls (tap.lisp).
;;;;   +AUDIO-TAP-BUFFER-SIZE+ 2048: frames per chunk (the ScriptProcessorNode's
;;;;                          buffer size): 42.7 ms at 48 kHz.
;;;;   +DEFAULT-FPS+          30: WRITE-VIDEO's frame rate.
;;;;   +DEFAULT-SAMPLE-RATE+  48000: the mix's sample rate (Hz).
;;;;   +FFMPEG-STDERR-TAIL-LINES+ 20: lines of ffmpeg's standard error an
;;;;                          FFMPEG-ERROR keeps.
;;;;   *FFMPEG-PROGRAM*       NIL, or the ffmpeg program RUN-FFMPEG runs (a
;;;;                          pathname designator); NIL means FIND-FFMPEG.
;;;;   *FFMPEG-EXECUTABLE-CANDIDATES* absolute paths FIND-FFMPEG tries last.
;;;;   *RECORDING-PUMP-INTERVAL* 0.2: seconds the recording's reader thread
;;;;                          waits for a message before it looks whether the
;;;;                          recording was stopped (recording.lisp).
;;;;
;;;; RECORDING-FRAME (structure, read-only slots), one screencast frame:
;;;;   TIMESTAMP  a real, seconds since 1970 on the browser's clock: the frame's
;;;;              Page.screencastFrame metadata.timestamp as JSON decoded it.
;;;;              Arithmetic on it uses its exact RATIONAL.
;;;;   PATHNAME   the image file (a JPEG from the screencast).
;;;;   INDEX      its number in arrival order, from 1 (0 when made by hand).
;;;;
;;;; AUDIO-CHUNK (structure, read-only slots), one payload of the page tap,
;;;; PARSE-AUDIO-CHUNK's result (the payload's JSON field in parentheses):
;;;;   TRACK  (track) a string naming the track: one per document and
;;;;          AudioContext.
;;;;   SEQ    (seq) a non-negative integer, the chunk's number in its track.
;;;;   SAMPLE-RATE (rate) a positive integer, the AudioContext's rate.
;;;;   CHANNELS (channels) 1 or 2.
;;;;   FRAME  (frame) an integer: the AudioContext sample frame of the chunk's
;;;;          first sample, the frame at which it reached the destination.
;;;;   CONTEXT-TIME, PERFORMANCE-TIME (contextTime, performanceTime) reals: one
;;;;          getOutputTimestamp() pair, the context time (seconds) heard at a
;;;;          performance.now() time (milliseconds).
;;;;   TIME-ORIGIN (timeOrigin) a real: performance.timeOrigin, milliseconds
;;;;          since 1970.
;;;;   SAMPLES a fresh SAMPLE-VECTOR (audio-protocol), interleaved, the decoded
;;;;          PCM (DECODE-PCM16). (AUDIO-CHUNK-FRAMES chunk) is its frame count.
;;;;
;;;; AUDIO-TRACK (structure): one AudioContext of one document. ID (the chunks'
;;;; TRACK), SAMPLE-RATE and CHANNELS (those of its first chunk), CHUNKS (its
;;;; chunks in increasing SEQ, no two with one SEQ). ADD-AUDIO-CHUNK makes and
;;;; fills tracks.
;;;;
;;;; AUDIO-CLIP (structure, read-only slots), an external WAV file in the mix:
;;;; PATHNAME, BUFFER (the PCM-BUFFER READ-WAV gave), AT (seconds on the
;;;; recording's clock, a real, or NIL) and EPOCH (seconds since 1970 on the
;;;; browser's clock, or NIL). Exactly one of AT and EPOCH is non-NIL.
;;;;
;;;; RECORDING (class). Readers (each returns a fresh list where it returns a
;;;; list, read under the recording's lock, so any thread may call them):
;;;;   RECORDING-BACKEND      the CDP backend, or NIL (MAKE-RECORDING).
;;;;   RECORDING-DIRECTORY    the directory (a directory pathname) holding the
;;;;                          frames, and what WRITE-VIDEO writes next to them.
;;;;   RECORDING-AUDIO-P      true when page audio is captured.
;;;;   RECORDING-ACTIVE-P     true from START-RECORDING until STOP-RECORDING.
;;;;   RECORDING-FRAMES       the frames, in arrival order.
;;;;   RECORDING-AUDIO-TRACKS the page-audio tracks, in the order they started.
;;;;   RECORDING-AUDIO-CLIPS  the external clips, in the order they were added.
;;;;   RECORDING-START-TIME   the smallest frame TIMESTAMP (as stored), or NIL
;;;;                          with no frames: time 0 of the recording's clock.
;;;;   RECORDING-STOP-TIME    seconds since 1970 on the browser's clock when
;;;;                          STOP-RECORDING asked the page (a real), or NIL.
;;;;   RECORDING-WARNINGS     the RECORDING-WARNINGs signalled, oldest first.
;;;;
;;;; (MAKE-RECORDING &key directory frames) -> a recording that is not active
;;;; and has no backend, holding FRAMES (a list of RECORDING-FRAMEs, taken as
;;;; arrival order): saved frames to re-encode with WRITE-VIDEO, or a recording
;;;; to build by hand (ADD-AUDIO-CHUNK, ADD-AUDIO-FILE). DIRECTORY, when given,
;;;; is created if missing and never deleted; else a fresh temporary directory
;;;; is made, which DISCARD-RECORDING deletes. START-RECORDING makes its
;;;; recordings the same way.

(in-package #:browser-protocol/record)

(defparameter +audio-binding-name+ "__browserProtocolRecordAudio"
  "The Runtime binding the page tap calls with each PCM chunk.")

(defparameter +audio-tap-global+ "__browserProtocolRecord"
  "The page global holding the tap's start() and stop().")

(defconstant +audio-tap-buffer-size+ 2048
  "Frames per page-audio chunk: the tap's ScriptProcessorNode buffer size.")

(defconstant +default-fps+ 30
  "WRITE-VIDEO's default frame rate.")

(defconstant +default-sample-rate+ 48000
  "The sample rate of the mix and of the AAC track.")

(defconstant +ffmpeg-stderr-tail-lines+ 20
  "Lines of ffmpeg's standard error an FFMPEG-ERROR keeps.")

(defvar *ffmpeg-program* nil
  "NIL, or the ffmpeg program RUN-FFMPEG runs (NIL: FIND-FFMPEG).")

(defparameter *ffmpeg-executable-candidates*
  '("/opt/homebrew/bin/ffmpeg" "/usr/local/bin/ffmpeg" "/usr/bin/ffmpeg"
    "C:/ffmpeg/bin/ffmpeg.exe" "C:/ProgramData/chocolatey/bin/ffmpeg.exe")
  "Absolute paths FIND-FFMPEG tries after FFMPEG_PATH and PATH.")

(defparameter *recording-pump-interval* 0.2
  "Seconds the recording's reader thread waits before it looks at the recording's state.")

;;; --- frames ---------------------------------------------------------------

(defstruct (recording-frame (:constructor make-recording-frame (&key timestamp pathname (index 0)))
                            (:copier nil))
  "One screencast frame: its browser timestamp and its image file."
  (timestamp 0 :type real :read-only t)
  (pathname nil :read-only t)
  (index 0 :type (integer 0) :read-only t))

;;; --- page audio -----------------------------------------------------------

(defstruct (audio-chunk (:copier nil))
  "One PCM chunk from the page tap (model.lisp header)."
  (track "" :type string :read-only t)
  (seq 0 :type (integer 0) :read-only t)
  (sample-rate 48000 :type (integer 1) :read-only t)
  (channels 2 :type (integer 1 2) :read-only t)
  (frame 0 :type integer :read-only t)
  (context-time 0 :type real :read-only t)
  (performance-time 0 :type real :read-only t)
  (time-origin 0 :type real :read-only t)
  (samples (make-array 0 :element-type 'single-float) :type audio-protocol:sample-vector
           :read-only t))

(defun audio-chunk-frames (chunk)
  "The number of frames CHUNK holds."
  (check-type chunk audio-chunk)
  (floor (length (audio-chunk-samples chunk)) (audio-chunk-channels chunk)))

(defstruct (audio-track (:constructor %make-audio-track (id sample-rate channels))
                        (:copier nil))
  "One AudioContext of one document: its chunks in increasing SEQ."
  (id "" :type string :read-only t)
  (sample-rate 48000 :type (integer 1) :read-only t)
  (channels 2 :type (integer 1 2) :read-only t)
  (chunks '() :type list))

;;; --- external clips -------------------------------------------------------

(defstruct (audio-clip (:copier nil))
  "An external WAV file placed on the recording's clock."
  (pathname nil :read-only t)
  (buffer nil :read-only t)
  (at nil :type (or null real) :read-only t)
  (epoch nil :type (or null real) :read-only t))

;;; --- recordings -----------------------------------------------------------

(defclass recording ()
  ((backend :initarg :backend :initform nil :reader recording-backend)
   (directory :initarg :directory :initform nil :reader recording-directory)
   (temporary-p :initarg :temporary-p :initform nil :accessor %recording-temporary-p
                :documentation "True when the recording made DIRECTORY itself.")
   (audio-p :initarg :audio-p :initform nil :reader recording-audio-p)
   (max-width :initarg :max-width :initform nil :reader %recording-max-width)
   (max-height :initarg :max-height :initform nil :reader %recording-max-height)
   (quality :initarg :quality :initform 80 :reader %recording-quality)
   (state :initarg :state :initform :stopped :accessor %recording-state
          :documentation ":RECORDING or :STOPPED.")
   (frames :initarg :frames :initform '() :accessor %recording-frames
           :documentation "Newest first.")
   (frame-count :initform 0 :accessor %recording-frame-count
                :documentation "Frames written so far: the next file is number (1+ this).")
   (tracks :initform '() :accessor %recording-tracks :documentation "Newest first.")
   (clips :initform '() :accessor %recording-clips :documentation "Newest first.")
   (stop-time :initform nil :accessor %recording-stop-time)
   (warnings :initform '() :accessor %recording-warnings :documentation "Newest first.")
   (handlers :initform '() :accessor %recording-handlers
             :documentation "(method . handler) pairs given to ON-CDP-EVENT.")
   (script-identifier :initform nil :accessor %recording-script-identifier
                      :documentation "Page.addScriptToEvaluateOnNewDocument's identifier.")
   (pump :initform nil :accessor %recording-pump
         :documentation "The reader thread, or NIL.")
   (pump-condition :initform nil :accessor %recording-pump-condition
                   :documentation "The condition that ended the reader thread, or NIL.")
   (lock :initform (bt2:make-lock :name "browser-protocol recording") :reader %recording-lock))
  (:documentation "A page recording: screencast frames, page-audio tracks and external clips (model.lisp)."))

(defun recording-p (object)
  (typep object 'recording))

(defmethod print-object ((recording recording) stream)
  (print-unreadable-object (recording stream :type t :identity t)
    (format stream "~:[stopped~;active~], ~D frame~:P"
            (recording-active-p recording) (length (recording-frames recording)))))

(defmacro %with-recording-lock ((recording) &body body)
  `(bt2:with-lock-held ((%recording-lock ,recording)) ,@body))

(defun recording-active-p (recording)
  "True from START-RECORDING until STOP-RECORDING."
  (%with-recording-lock (recording)
    (eq (%recording-state recording) :recording)))

(defun recording-frames (recording)
  "RECORDING's frames, in arrival order (a fresh list)."
  (%with-recording-lock (recording)
    (reverse (%recording-frames recording))))

(defun recording-audio-tracks (recording)
  "RECORDING's page-audio tracks, in the order they started (a fresh list)."
  (%with-recording-lock (recording)
    (reverse (%recording-tracks recording))))

(defun recording-audio-clips (recording)
  "RECORDING's external clips, in the order they were added (a fresh list)."
  (%with-recording-lock (recording)
    (reverse (%recording-clips recording))))

(defun recording-warnings (recording)
  "The RECORDING-WARNINGs RECORDING signalled, oldest first (a fresh list)."
  (%with-recording-lock (recording)
    (reverse (%recording-warnings recording))))

(defun recording-stop-time (recording)
  "Seconds since 1970 (browser clock) when STOP-RECORDING asked the page, or NIL."
  (%with-recording-lock (recording)
    (%recording-stop-time recording)))

(defun recording-start-time (recording)
  "The smallest frame timestamp: time 0 of RECORDING's clock. NIL with no frames."
  (let ((frames (recording-frames recording)))
    (when frames
      (recording-frame-timestamp
       (reduce (lambda (a b)
                 (if (< (rational (recording-frame-timestamp b))
                        (rational (recording-frame-timestamp a)))
                     b
                     a))
               frames)))))

(defun %make-temporary-directory ()
  "A fresh, empty directory under the system's temporary directory."
  (let ((random (make-random-state t)))
    (loop
      (let ((dir (uiop:ensure-directory-pathname
                  (merge-pathnames (format nil "browser-protocol-recording-~36r-~36r"
                                           (get-universal-time)
                                           (random (expt 36 8) random))
                                   (uiop:temporary-directory)))))
        (unless (probe-file dir)
          (ensure-directories-exist dir)
          (return dir))))))

(defun %recording-directory-for (directory)
  "(values directory temporary-p) for a recording given DIRECTORY (or NIL)."
  (if directory
      (let ((dir (uiop:ensure-directory-pathname directory)))
        (ensure-directories-exist dir)
        (values dir nil))
      (values (%make-temporary-directory) t)))

(defun make-recording (&key directory frames)
  "A recording that is not active, has no backend and holds FRAMES (model.lisp)."
  (check-type frames list)
  (dolist (frame frames)
    (check-type frame recording-frame))
  (multiple-value-bind (dir temporary-p) (%recording-directory-for directory)
    (make-instance 'recording :directory dir :temporary-p temporary-p
                              :frames (reverse frames) :state :stopped)))
