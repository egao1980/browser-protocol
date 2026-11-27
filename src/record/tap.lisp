;;;; The page-side Web Audio tap.
;;;;
;;;; (AUDIO-TAP-SCRIPT) -> a string of JavaScript, the same text on every call.
;;;; START-RECORDING installs it twice: Page.addScriptToEvaluateOnNewDocument
;;;; (every later document, before its own scripts) and Runtime.evaluate (the
;;;; current document). CDP evaluates it, so the page's Content-Security-Policy
;;;; does not apply to it, and it loads nothing: no AudioWorklet module, no
;;;; worker, no blob: or data: URL, which a strict CSP (script-src 'self',
;;;; worker-src 'none') would refuse. It never throws and never touches the DOM.
;;;; Evaluated again in a document that has it, it only calls start().
;;;;
;;;; What it does, as one top-level statement (an IIFE):
;;;; 1. window[+AUDIO-TAP-GLOBAL+] exists: call its start(), nothing else.
;;;;    AudioNode or AudioContext is not a function: nothing.
;;;; 2. Replace AudioNode.prototype.connect and .disconnect, keeping the
;;;;    originals:
;;;;    * connect(destination, output, input) calls the original with all its
;;;;      arguments and returns that result. Then, when destination is an
;;;;      AudioDestinationNode whose context is an AudioContext (not an
;;;;      OfflineAudioContext), it also connects the node, from the same
;;;;      output (default 0), to that context's tap bus (point 3), unless the
;;;;      node is the tap's own bus or processor.
;;;;    * disconnect(destination, ...) calls the original and returns its
;;;;      result; when destination is an AudioDestinationNode whose context has
;;;;      a tap, it also disconnects the node from the tap's bus.
;;;;      disconnect() with no argument drops the tap connection by itself.
;;;;    The tap's own part of both runs inside try/catch: the page's call
;;;;    behaves as it did, errors included.
;;;; 3. A tap per AudioContext, made on its first such connect: a GainNode bus
;;;;    (channelCount 2, channelCountMode 'explicit', channelInterpretation
;;;;    'speakers', so a mono source reaches both channels as the destination
;;;;    would play it) -> createScriptProcessor(+AUDIO-TAP-BUFFER-SIZE+, 2, 2)
;;;;    -> the context's destination (the processor's output stays silent).
;;;;    The tap's track id is the document id (random per document, letters and
;;;;    digits), "/", and the context's number in the document (from 1). Its
;;;;    seq counts the processor's audioprocess events from 0, sent or not.
;;;; 4. Each audioprocess event while the tap is active: the input buffer (N =
;;;;    +AUDIO-TAP-BUFFER-SIZE+ frames, 2 channels) is encoded as interleaved
;;;;    signed 16-bit little-endian codes, code = Math.round(x * 32768) clamped
;;;;    to -32768 .. 32767 (NaN -> 0), then base64 (btoa). An all-zero chunk is
;;;;    not sent. Otherwise, when window[+AUDIO-BINDING-NAME+] is a function,
;;;;    it is called with JSON.stringify of
;;;;      {v: 1, track, seq, rate: ctx.sampleRate, channels: 2,
;;;;       frame: Math.round(e.playbackTime * rate) - 2 * N,
;;;;       contextTime, performanceTime, timeOrigin: performance.timeOrigin,
;;;;       pcm}
;;;;    where contextTime / performanceTime is ctx.getOutputTimestamp(), or,
;;;;    when its performanceTime is not > 0 (the output has not started),
;;;;    ctx.currentTime and performance.now(). The frame rule: Chrome's
;;;;    ScriptProcessorNode is double-buffered, so the input of the event with
;;;;    playbackTime P began at context frame P * rate - 2N, the frame at which
;;;;    those samples reached the destination (measured on Chrome 158 for N =
;;;;    1024, 2048 and 4096: a tone started at frame F shows its first sample
;;;;    at F; the live tests check it). A chunk goes out as soon as it is
;;;;    produced, so a DOM swap loses nothing and a navigation at most the
;;;;    chunk being filled.
;;;; 5. window[+AUDIO-TAP-GLOBAL+] is defined (configurable, not enumerable) as
;;;;    an object with start() (send again; reconnect every tap's processor)
;;;;    and stop() (send nothing more; disconnect every tap's processor, while
;;;;    the page's own graph keeps playing), which returns
;;;;    performance.timeOrigin + performance.now() (milliseconds since 1970).

(in-package #:browser-protocol/record)

(defun audio-tap-script ()
  "The JavaScript of the page's Web Audio tap (file header)."
  (%br1-pending 'audio-tap-script))
