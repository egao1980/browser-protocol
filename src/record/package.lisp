;;;; browser-protocol/record (slice BR1, 0.3.0): record what a page shows and
;;;; what it plays into one MP4 (H.264 + AAC). Brief: cl-stack
;;;; docs/capabilities/browser.md, section BR1.
;;;;
;;;; Video is a CDP screencast (Page.startScreencast, every frame acked), kept as
;;;; JPEG files with their metadata.timestamp and turned into a constant frame
;;;; rate. Page audio is what the page's Web Audio graph sends to an
;;;; AudioContext's destination, captured in the page by a tap that CDP injects
;;;; (not subject to the page's CSP) and streamed to Lisp as 16-bit PCM chunks
;;;; through a Runtime binding. External WAV files join the mix at a time on the
;;;; recording's clock. audio-protocol mixes; ffmpeg muxes, run through
;;;; process-protocol.
;;;;
;;;; The recording's clock: time 0 is the earliest frame's timestamp (seconds
;;;; since 1970 on the browser's clock, RECORDING-START-TIME). Everything is
;;;; placed on it: frames, page audio, external clips.
;;;;
;;;; Files (in load order):
;;;;   package.lisp     this package
;;;;   conditions.lisp  the condition tree (given); %BR1-PENDING
;;;;   model.lisp       constants, RECORDING-FRAME, AUDIO-CHUNK, AUDIO-TRACK,
;;;;                    AUDIO-CLIP, RECORDING and their accessors (given)
;;;;   video.lisp       VIDEO-SCHEDULE, FFCONCAT-TEXT: frame times to a
;;;;                    constant frame rate
;;;;   audio.lisp       DECODE-PCM16, PARSE-AUDIO-CHUNK, CHUNK-EPOCH,
;;;;                    ADD-AUDIO-CHUNK, TRACK-BUFFER, MIX-PLACED, MIX-RECORDING
;;;;   tap.lisp         AUDIO-TAP-SCRIPT: the page-side Web Audio tap
;;;;   ffmpeg.lisp      FIND-FFMPEG, FFMPEG-ARGUMENTS, RUN-FFMPEG
;;;;   recording.lisp   START-RECORDING, STOP-RECORDING, ADD-AUDIO-FILE,
;;;;                    WRITE-VIDEO, DISCARD-RECORDING, WITH-RECORDING

(defpackage #:browser-protocol/record
  (:use #:cl)
  (:nicknames #:stack-browser/record)
  (:documentation "Page recording with sound for browser-protocol (slice BR1).

START-RECORDING starts a CDP screencast on a CDP backend and, unless :AUDIO is
NIL, a Web Audio tap in the page; STOP-RECORDING ends both. ADD-AUDIO-FILE puts
a WAV file on the recording's clock. WRITE-VIDEO writes one MP4: the frames at a
constant frame rate (libx264, yuv420p, even dimensions) and, when there is any
audio, one AAC track mixed from every page-audio track and clip, aligned to the
first frame. WITH-RECORDING wraps a body. The pure parts (frame timing, PCM
chunks, clock mapping, mixing, the ffmpeg command line) are exported for tests
and for re-encoding saved frames (MAKE-RECORDING).

Conditions are BROWSER-ERRORs: RECORDING-ERROR and below.")
  (:export
   ;; Conditions (conditions.lisp)
   #:recording-error #:recording-error-recording
   #:recording-stopped
   #:recording-no-frames
   #:ffmpeg-error #:ffmpeg-error-program #:ffmpeg-error-arguments
   #:ffmpeg-error-exit-code #:ffmpeg-error-stderr-tail
   #:ffmpeg-not-found
   #:recording-warning #:recording-warning-recording #:recording-warning-reason
   ;; Constants and parameters (model.lisp)
   #:+audio-binding-name+ #:+audio-tap-global+ #:+audio-tap-buffer-size+
   #:+default-fps+ #:+default-sample-rate+ #:+ffmpeg-stderr-tail-lines+
   #:*ffmpeg-program* #:*ffmpeg-executable-candidates* #:*recording-pump-interval*
   ;; Frames (model.lisp)
   #:recording-frame #:make-recording-frame #:recording-frame-p
   #:recording-frame-timestamp #:recording-frame-pathname #:recording-frame-index
   ;; Page audio (model.lisp)
   #:audio-chunk #:make-audio-chunk #:audio-chunk-p
   #:audio-chunk-track #:audio-chunk-seq #:audio-chunk-sample-rate
   #:audio-chunk-channels #:audio-chunk-frame #:audio-chunk-context-time
   #:audio-chunk-performance-time #:audio-chunk-time-origin #:audio-chunk-samples
   #:audio-chunk-frames
   #:audio-track #:audio-track-id #:audio-track-sample-rate #:audio-track-channels
   #:audio-track-chunks
   ;; External clips (model.lisp)
   #:audio-clip #:make-audio-clip #:audio-clip-p #:audio-clip-pathname
   #:audio-clip-buffer #:audio-clip-at #:audio-clip-epoch
   ;; Recordings (model.lisp)
   #:recording #:make-recording #:recording-p
   #:recording-backend #:recording-directory #:recording-audio-p
   #:recording-active-p #:recording-frames #:recording-audio-tracks
   #:recording-audio-clips #:recording-start-time #:recording-stop-time
   #:recording-warnings
   ;; Video timing (video.lisp)
   #:video-schedule #:ffconcat-text
   ;; Audio (audio.lisp)
   #:decode-pcm16 #:parse-audio-chunk #:chunk-epoch #:add-audio-chunk
   #:track-buffer #:mix-placed #:mix-recording
   ;; The page tap (tap.lisp)
   #:audio-tap-script
   ;; ffmpeg (ffmpeg.lisp)
   #:find-ffmpeg #:ffmpeg-arguments #:run-ffmpeg
   ;; Recording (recording.lisp)
   #:start-recording #:stop-recording #:add-audio-file #:write-video
   #:discard-recording #:with-recording))

(in-package #:browser-protocol/record)
