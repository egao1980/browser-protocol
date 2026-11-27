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
  (declare (ignore octets))
  (%br1-pending 'decode-pcm16))

(defun parse-audio-chunk (payload)
  "The AUDIO-CHUNK of a page-tap payload (file header)."
  (declare (ignore payload))
  (%br1-pending 'parse-audio-chunk))

(defun chunk-epoch (chunk)
  "Seconds since 1970 at which CHUNK's first sample is heard (file header)."
  (declare (ignore chunk))
  (%br1-pending 'chunk-epoch))

(defun add-audio-chunk (recording chunk)
  "File CHUNK into its track of RECORDING (file header)."
  (declare (ignore recording chunk))
  (%br1-pending 'add-audio-chunk))

(defun track-buffer (track)
  "TRACK's chunks as one buffer, and the epoch of its first frame (file header)."
  (declare (ignore track))
  (%br1-pending 'track-buffer))

(defun mix-placed (placements &key (sample-rate +default-sample-rate+) frames)
  "Buffers placed at start times, summed into one stereo buffer (file header)."
  (declare (ignore placements sample-rate frames))
  (%br1-pending 'mix-placed))

(defun mix-recording (recording &key (sample-rate +default-sample-rate+) frames start)
  "RECORDING's page audio and clips mixed on its clock (file header)."
  (declare (ignore recording sample-rate frames start))
  (%br1-pending 'mix-recording))
