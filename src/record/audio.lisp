;;;; Page audio and the mix. Pure: no browser, no ffmpeg. Buffers, resampling
;;;; and mixing are audio-protocol's (STACK-AUDIO); base64 is
;;;; encoding-protocol's, JSON json-protocol's.
;;;;
;;;; (DECODE-PCM16 octets) -> a fresh SAMPLE-VECTOR: signed 16-bit
;;;;   little-endian codes, each c / 32768 as a SINGLE-FLOAT (exact). OCTETS is
;;;;   a vector of (UNSIGNED-BYTE 8) (else TYPE-ERROR) of even length (else
;;;;   BROWSER-ERROR). Byte pair (lo hi) is code lo + 256 hi, minus 65536 when
;;;;   that is 32768 or more: (0 128) is -32768 -> -1.0, (255 127) 32767.
;;;;
;;;; (PARSE-AUDIO-CHUNK payload) -> an AUDIO-CHUNK. PAYLOAD is the string a
;;;;   Runtime.bindingCalled event of +AUDIO-BINDING-NAME+ carries: a JSON object
;;;;   (tap.lisp writes it) with these members, all required, others ignored:
;;;;     "v"               1 (the payload version)
;;;;     "track"           a non-empty string
;;;;     "seq"             an integer >= 0
;;;;     "rate"            an integer >= 1
;;;;     "channels"        1 or 2
;;;;     "frame"           an integer (may be negative)
;;;;     "contextTime"     a number
;;;;     "performanceTime" a number
;;;;     "timeOrigin"      a number
;;;;     "pcm"             a string: base64 (RFC 4648, encoding-protocol :BASE64)
;;;;                       of the interleaved S16LE samples, whose length in
;;;;                       bytes is a positive multiple of 2 * channels
;;;;   The chunk's slots are these values (numbers as JSON decoded them) and
;;;;   SAMPLES = (DECODE-PCM16 bytes). A payload that is not a string, not JSON,
;;;;   not an object, or breaks any rule above signals BROWSER-ERROR whose
;;;;   message names the member; for bad JSON or base64 its CAUSE is the
;;;;   json-protocol or encoding-protocol condition.
;;;;
;;;; (CHUNK-EPOCH chunk) -> an exact rational: seconds since 1970 (browser
;;;;   clock) at which the chunk's first sample is heard, by its own
;;;;   getOutputTimestamp pair:
;;;;       (TIME-ORIGIN + PERFORMANCE-TIME) / 1000 + FRAME / SAMPLE-RATE - CONTEXT-TIME
;;;;   every slot taken as its exact RATIONAL.
;;;;
;;;; (ADD-AUDIO-CHUNK recording chunk) -> the chunk's track, or NIL. Files CHUNK
;;;;   (any recording, active or not, under its lock; the CDP handler of
;;;;   START-RECORDING calls it for each payload):
;;;;   * The track is the one whose ID is the chunk's TRACK; when there is none,
;;;;     a new AUDIO-TRACK (that ID, the chunk's SAMPLE-RATE and CHANNELS) is
;;;;     added after the others.
;;;;   * A chunk whose SAMPLE-RATE or CHANNELS differ from its track's is
;;;;     dropped: a RECORDING-WARNING (kept in RECORDING-WARNINGS, then WARN
;;;;     once the lock is released), and the result is NIL.
;;;;   * A chunk whose SEQ the track already has is dropped quietly (the first
;;;;     one stays); the result is the track.
;;;;   * Otherwise it joins the track's CHUNKS, which stay in increasing SEQ.
;;;;
;;;; (TRACK-BUFFER track) -> (values buffer start), or (values NIL NIL) for a
;;;;   track with no chunks. F0 is the smallest chunk FRAME, F1 the largest
;;;;   FRAME + frames. BUFFER is a fresh PCM-BUFFER of the track's SAMPLE-RATE
;;;;   and CHANNELS with F1 - F0 frames: silence, except that frame j of chunk c
;;;;   is buffer frame (FRAME_c - F0 + j). Chunks are written in increasing SEQ,
;;;;   so where two overlap the larger SEQ wins. A gap (a chunk lost, or all
;;;;   zero and not sent) stays silent. START is the exact rational epoch of
;;;;   buffer frame 0, by the mapping of the chunk R of smallest SEQ:
;;;;       (CHUNK-EPOCH R) + (F0 - FRAME_R) / SAMPLE-RATE
;;;;   One mapping per track: within a track, positions are exact context
;;;;   frames, and drift between the audio clock and the browser's clock is not
;;;;   corrected.
;;;;
;;;; (MIX-PLACED placements &key (sample-rate +default-sample-rate+) frames)
;;;;   -> a fresh 2-channel PCM-BUFFER at SAMPLE-RATE, or NIL when PLACEMENTS is
;;;;   empty. PLACEMENTS is a list of (buffer . start): a PCM-BUFFER and a real,
;;;;   seconds (may be negative). SAMPLE-RATE an integer >= 1, FRAMES NIL or an
;;;;   integer >= 0 (else TYPE-ERROR). Each placement, in order:
;;;;   1. resampled to SAMPLE-RATE with AUDIO-PROTOCOL:RESAMPLE when its rate
;;;;      differs, else taken as it is;
;;;;   2. 1 channel: made stereo with that channel on both sides at unity (no
;;;;      pan law: what a page's mono source sounds like through the
;;;;      destination); 2 channels: as it is; any other count is passed on as
;;;;      it is, for MIX to refuse (AUDIO-MISMATCH-ERROR and its restarts);
;;;;   3. placed at frame o = floor(start * SAMPLE-RATE + 1/2), start as its
;;;;      exact RATIONAL (SECONDS-TO-FRAME's rounding, extended to negative
;;;;      starts): o >= 0 puts o frames of silence before it, o < 0 cuts its
;;;;      first -o frames (a placement wholly before 0 is left empty).
;;;;   The placed buffers are summed by (AUDIO-PROTOCOL:MIX placed :channels 2
;;;;   :clip :clip): overlaps add in double-float, in PLACEMENTS order, are
;;;;   rounded once and clamped to -1 .. 1, with one AUDIO-PROTOCOL:SAMPLES-
;;;;   CLIPPED warning when any sample is clamped (it reaches the caller). The
;;;;   result has FRAMES frames (cut, or padded with silence) when FRAMES is
;;;;   given, else as many as the longest placed buffer.
;;;;
;;;; (MIX-RECORDING recording &key (sample-rate +default-sample-rate+) frames
;;;;   start) -> the recording's audio as one buffer (MIX-PLACED), or NIL when
;;;;   it has nothing to mix. T0, time 0 of the clock, is START (seconds since
;;;;   1970, a real) or else (RECORDING-START-TIME recording); when both are NIL:
;;;;   RECORDING-NO-FRAMES. The placements, in this order:
;;;;   * each track of RECORDING-AUDIO-TRACKS with chunks: (buffer . (start - T0))
;;;;     from TRACK-BUFFER;
;;;;   * each clip of RECORDING-AUDIO-CLIPS: (buffer . AT), or (buffer . (EPOCH -
;;;;     T0)) for a clip given by its epoch;
;;;;   all as exact rationals, then (MIX-PLACED placements :sample-rate
;;;;   sample-rate :frames frames).

(in-package #:browser-protocol/record)

(defun decode-pcm16 (octets)
  "Signed 16-bit little-endian PCM to samples (file header)."
  (check-type octets (vector (unsigned-byte 8)))
  (let ((n (length octets)))
    (when (oddp n)
      (error 'browser-protocol:browser-error
             :message (format nil "~d bytes of 16-bit PCM: not a whole number of samples" n)))
    (let ((samples (make-array (floor n 2) :element-type 'single-float)))
      (dotimes (i (length samples) samples)
        (let* ((lo (aref octets (* 2 i)))
               (hi (aref octets (1+ (* 2 i))))
               (code (+ lo (* 256 hi))))
          (when (>= code 32768)
            (decf code 65536))
          (setf (aref samples i) (/ (float code 1f0) 32768f0)))))))

(defun %payload-error (control &rest arguments)
  "Signal the BROWSER-ERROR of a payload that is not a page-tap chunk."
  (error 'browser-protocol:browser-error
         :message (format nil "page audio payload: ~?" control arguments)))

(defun parse-audio-chunk (payload)
  "The AUDIO-CHUNK of a page-tap payload (file header)."
  (unless (stringp payload)
    (%payload-error "not a string but ~s" (type-of payload)))
  (let ((object (handler-case (json-protocol:decode payload)
                  (json-protocol:json-error (c)
                    (error 'browser-protocol:browser-error
                           :message (format nil "page audio payload: not JSON: ~a" c)
                           :cause c)))))
    (unless (hash-table-p object)
      (%payload-error "not a JSON object"))
    (flet ((field (name test what)
             (multiple-value-bind (value present) (gethash name object)
               (unless present
                 (%payload-error "no \"~a\" member" name))
               (unless (funcall test value)
                 (%payload-error "\"~a\" is ~s, not ~a" name value what))
               value)))
      (field "v" (lambda (v) (eql v 1)) "1")
      (let* ((track (field "track" (lambda (v) (and (stringp v) (plusp (length v))))
                           "a non-empty string"))
             (seq (field "seq" (lambda (v) (typep v '(integer 0))) "an integer >= 0"))
             (rate (field "rate" (lambda (v) (typep v '(integer 1))) "an integer >= 1"))
             (channels (field "channels" (lambda (v) (member v '(1 2))) "1 or 2"))
             (frame (field "frame" #'integerp "an integer"))
             (context-time (field "contextTime" #'realp "a number"))
             (performance-time (field "performanceTime" #'realp "a number"))
             (time-origin (field "timeOrigin" #'realp "a number"))
             (pcm (field "pcm" #'stringp "a string"))
             (octets (handler-case (encoding-protocol:decode pcm :encoding :base64)
                       (encoding-protocol:encoding-error (c)
                         (error 'browser-protocol:browser-error
                                :message (format nil "page audio payload: \"pcm\" is not base64: ~a" c)
                                :cause c))))
             (n (length octets)))
        (unless (and (plusp n) (zerop (mod n (* 2 channels))))
          (%payload-error "\"pcm\" holds ~d bytes, not a positive multiple of ~d (~d channel~:p)"
                          n (* 2 channels) channels))
        (make-audio-chunk :track track :seq seq :sample-rate rate :channels channels
                          :frame frame :context-time context-time
                          :performance-time performance-time :time-origin time-origin
                          :samples (decode-pcm16 octets))))))

(defun chunk-epoch (chunk)
  "Seconds since 1970 at which CHUNK's first sample is heard (file header)."
  (check-type chunk audio-chunk)
  (+ (/ (+ (rational (audio-chunk-time-origin chunk))
           (rational (audio-chunk-performance-time chunk)))
        1000)
     (/ (audio-chunk-frame chunk) (audio-chunk-sample-rate chunk))
     (- (rational (audio-chunk-context-time chunk)))))

(defun %recording-warn (recording reason)
  "Keep a RECORDING-WARNING (REASON) in RECORDING's warnings, then WARN it,
with the recording's lock released: a handler of the warning may read the
recording."
  (let ((warning (make-condition 'recording-warning :recording recording :reason reason)))
    (%with-recording-lock (recording)
      (push warning (%recording-warnings recording)))
    (warn warning)
    nil))

(defun add-audio-chunk (recording chunk)
  "File CHUNK into its track of RECORDING (file header)."
  (check-type recording recording)
  (check-type chunk audio-chunk)
  (let ((mismatch nil)
        (result nil))
    (%with-recording-lock (recording)
      (let* ((id (audio-chunk-track chunk))
             (track (or (find id (%recording-tracks recording)
                              :key #'audio-track-id :test #'string=)
                        (let ((new (%make-audio-track id (audio-chunk-sample-rate chunk)
                                                      (audio-chunk-channels chunk))))
                          (push new (%recording-tracks recording))
                          new))))
        (cond
          ((or (/= (audio-chunk-sample-rate chunk) (audio-track-sample-rate track))
               (/= (audio-chunk-channels chunk) (audio-track-channels track)))
           (setf mismatch
                 (format nil "an audio chunk of track ~a at ~d Hz, ~d channel~:p (the track has ~d Hz, ~d channel~:p)"
                         id (audio-chunk-sample-rate chunk) (audio-chunk-channels chunk)
                         (audio-track-sample-rate track) (audio-track-channels track))))
          ((find (audio-chunk-seq chunk) (audio-track-chunks track) :key #'audio-chunk-seq)
           (setf result track))
          (t
           ;; A fresh list: readers take AUDIO-TRACK-CHUNKS without the lock.
           (setf (audio-track-chunks track)
                 (merge 'list (copy-list (audio-track-chunks track)) (list chunk)
                        #'< :key #'audio-chunk-seq)
                 result track)))))
    (when mismatch
      (%recording-warn recording mismatch))
    result))

(defun track-buffer (track)
  "TRACK's chunks as one buffer, and the epoch of its first frame (file header)."
  (check-type track audio-track)
  (let ((chunks (stable-sort (copy-list (audio-track-chunks track)) #'< :key #'audio-chunk-seq)))
    (if (null chunks)
        (values nil nil)
        (let* ((channels (audio-track-channels track))
               (rate (audio-track-sample-rate track))
               (f0 (reduce #'min chunks :key #'audio-chunk-frame))
               (f1 (reduce #'max chunks :key (lambda (c) (+ (audio-chunk-frame c)
                                                            (audio-chunk-frames c)))))
               (buffer (audio-protocol:make-pcm-buffer :sample-rate rate :channels channels
                                                       :frames (- f1 f0)))
               (samples (audio-protocol:pcm-buffer-samples buffer))
               (r (first chunks)))
          (dolist (chunk chunks)
            (replace samples (audio-chunk-samples chunk)
                     :start1 (* channels (- (audio-chunk-frame chunk) f0))))
          (values buffer
                  (+ (chunk-epoch r) (/ (- f0 (audio-chunk-frame r)) rate)))))))

(defun %shifted (buffer offset frames)
  "A fresh buffer of FRAMES frames, BUFFER's rate and channels: BUFFER's frame
j at frame j + OFFSET, silence elsewhere."
  (let* ((channels (audio-protocol:pcm-buffer-channels buffer))
         (out (audio-protocol:make-pcm-buffer
               :sample-rate (audio-protocol:pcm-buffer-sample-rate buffer)
               :channels channels :frames frames))
         (src (max 0 (- offset)))
         (dst (max 0 offset))
         (count (min (- (audio-protocol:pcm-buffer-frames buffer) src) (- frames dst))))
    (when (plusp count)
      (replace (audio-protocol:pcm-buffer-samples out) (audio-protocol:pcm-buffer-samples buffer)
               :start1 (* dst channels)
               :start2 (* src channels) :end2 (* (+ src count) channels)))
    out))

(defun %stereo-at-unity (buffer)
  "BUFFER with 2 channels: a mono buffer's channel on both sides at unity,
any other buffer as it is."
  (if (= 1 (audio-protocol:pcm-buffer-channels buffer))
      (let ((channel (audio-protocol:pcm-channel buffer 0)))
        (audio-protocol:pcm-from-channels (list channel channel)
                                          :sample-rate (audio-protocol:pcm-buffer-sample-rate buffer)))
      buffer))

(defun mix-placed (placements &key (sample-rate +default-sample-rate+) frames)
  "Buffers placed at start times, summed into one stereo buffer (file header)."
  (check-type placements list)
  (check-type sample-rate (integer 1))
  (check-type frames (or null (integer 0)))
  (when placements
    (let* ((placed
             (loop for (buffer . start) in placements
                   for at-rate = (if (= (audio-protocol:pcm-buffer-sample-rate buffer) sample-rate)
                                     buffer
                                     (audio-protocol:resample buffer sample-rate))
                   for stereo = (%stereo-at-unity at-rate)
                   for offset = (floor (+ (* (rational start) sample-rate) 1/2))
                   collect (%shifted stereo offset
                                     (max 0 (+ offset (audio-protocol:pcm-buffer-frames stereo))))))
           (sum (audio-protocol:mix placed :channels 2 :clip :clip)))
      (if (and frames (/= frames (audio-protocol:pcm-buffer-frames sum)))
          (%shifted sum 0 frames)
          sum))))

(defun mix-recording (recording &key (sample-rate +default-sample-rate+) frames start)
  "RECORDING's page audio and clips mixed on its clock (file header)."
  (check-type recording recording)
  (check-type start (or null real))
  (let ((t0 (let ((origin (or start (recording-start-time recording))))
              (unless origin
                (error 'recording-no-frames :recording recording))
              (rational origin)))
        (placements '()))
    (dolist (track (recording-audio-tracks recording))
      (multiple-value-bind (buffer track-start) (track-buffer track)
        (when buffer
          (push (cons buffer (- track-start t0)) placements))))
    (dolist (clip (recording-audio-clips recording))
      (push (cons (audio-clip-buffer clip)
                  (if (audio-clip-epoch clip)
                      (- (rational (audio-clip-epoch clip)) t0)
                      (rational (audio-clip-at clip))))
            placements))
    (mix-placed (nreverse placements) :sample-rate sample-rate :frames frames)))
