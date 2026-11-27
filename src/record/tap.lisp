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

(defun %js-lines (&rest lines)
  "LINES (strings) joined, each ended by a newline."
  (with-output-to-string (s)
    (dolist (line lines)
      (write-string line s)
      (terpri s))))

(defun audio-tap-script ()
  "The JavaScript of the page's Web Audio tap (file header)."
  ;; Single quotes only; built by concatenation, so no FORMAT directives. The
  ;; tap's own wiring uses the saved originals (connect0 / disconnect0): the
  ;; patched methods never see the tap's nodes.
  (%js-lines
   "(function () {"
   (concatenate 'string "  var G = '" +audio-tap-global+ "';")
   (concatenate 'string "  var B = '" +audio-binding-name+ "';")
   (format nil "  var N = ~d;" +audio-tap-buffer-size+)
   "  var taps = [];"
   "  var active = true;"
   "  var connect0 = null;"
   "  var disconnect0 = null;"
   "  var doc = Math.random().toString(36).slice(2, 10) + Date.now().toString(36);"
   "  function isDestination(node) {"
   "    return typeof AudioDestinationNode === 'function' && node instanceof AudioDestinationNode;"
   "  }"
   "  function isLive(ctx) {"
   "    return typeof AudioContext === 'function' && ctx instanceof AudioContext;"
   "  }"
   "  function tapOf(ctx) {"
   "    for (var i = 0; i < taps.length; i++) { if (taps[i].ctx === ctx) { return taps[i]; } }"
   "    return null;"
   "  }"
   "  function isOwn(node) {"
   "    for (var i = 0; i < taps.length; i++) {"
   "      if (taps[i].bus === node || taps[i].proc === node) { return true; }"
   "    }"
   "    return false;"
   "  }"
   "  function wire(t) {"
   "    if (!t.wired) { connect0.call(t.proc, t.ctx.destination); t.wired = true; }"
   "  }"
   "  function unwire(t) {"
   "    if (t.wired) { t.wired = false; disconnect0.call(t.proc); }"
   "  }"
   "  function code(x) {"
   "    var c = Math.round(x * 32768);"
   "    if (c !== c) { return 0; }"
   "    return c > 32767 ? 32767 : (c < -32768 ? -32768 : c);"
   "  }"
   "  function send(t, e) {"
   "    var seq = t.seq;"
   "    t.seq = seq + 1;"
   "    var out = e.outputBuffer;"
   "    for (var k = 0; k < out.numberOfChannels; k++) { out.getChannelData(k).fill(0); }"
   "    if (!active) { return; }"
   "    var input = e.inputBuffer;"
   "    var n = input.length;"
   "    var left = input.getChannelData(0);"
   "    var right = input.numberOfChannels > 1 ? input.getChannelData(1) : left;"
   "    var bytes = new Uint8Array(n * 4);"
   "    var view = new DataView(bytes.buffer);"
   "    var heard = false;"
   "    for (var i = 0; i < n; i++) {"
   "      var a = code(left[i]);"
   "      var b = code(right[i]);"
   "      if (a !== 0 || b !== 0) { heard = true; }"
   "      view.setInt16(4 * i, a, true);"
   "      view.setInt16(4 * i + 2, b, true);"
   "    }"
   "    if (!heard) { return; }"
   "    var binding = window[B];"
   "    if (typeof binding !== 'function') { return; }"
   "    var ctx = t.ctx;"
   "    var rate = ctx.sampleRate;"
   "    var ts = typeof ctx.getOutputTimestamp === 'function' ? ctx.getOutputTimestamp() : null;"
   "    var contextTime, performanceTime;"
   "    if (ts && ts.performanceTime > 0) {"
   "      contextTime = ts.contextTime;"
   "      performanceTime = ts.performanceTime;"
   "    } else {"
   "      contextTime = ctx.currentTime;"
   "      performanceTime = performance.now();"
   "    }"
   "    var binary = '';"
   "    for (var j = 0; j < bytes.length; j += 8192) {"
   "      binary += String.fromCharCode.apply(null, bytes.subarray(j, j + 8192));"
   "    }"
   "    binding(JSON.stringify({"
   "      v: 1, track: t.track, seq: seq, rate: rate, channels: 2,"
   "      frame: Math.round(e.playbackTime * rate) - 2 * N,"
   "      contextTime: contextTime, performanceTime: performanceTime,"
   "      timeOrigin: performance.timeOrigin, pcm: btoa(binary)"
   "    }));"
   "  }"
   "  function makeTap(ctx) {"
   "    var bus = ctx.createGain();"
   "    bus.channelCount = 2;"
   "    bus.channelCountMode = 'explicit';"
   "    bus.channelInterpretation = 'speakers';"
   "    var proc = ctx.createScriptProcessor(N, 2, 2);"
   "    var t = {ctx: ctx, bus: bus, proc: proc, seq: 0, wired: false,"
   "             track: doc + '/' + (taps.length + 1)};"
   "    taps.push(t);"
   "    proc.onaudioprocess = function (e) { try { send(t, e); } catch (x) {} };"
   "    connect0.call(bus, proc);"
   "    if (active) { wire(t); }"
   "    return t;"
   "  }"
   "  function patchedConnect(destination) {"
   "    var result = connect0.apply(this, arguments);"
   "    try {"
   "      if (isDestination(destination) && isLive(destination.context) && !isOwn(this)) {"
   "        var t = tapOf(destination.context) || makeTap(destination.context);"
   "        connect0.call(this, t.bus, arguments[1] === undefined ? 0 : arguments[1]);"
   "      }"
   "    } catch (x) {}"
   "    return result;"
   "  }"
   "  function patchedDisconnect(destination) {"
   "    var result = disconnect0.apply(this, arguments);"
   "    try {"
   "      if (arguments.length > 0 && isDestination(destination) && !isOwn(this)) {"
   "        var t = tapOf(destination.context);"
   "        if (t) {"
   "          if (arguments.length > 1 && arguments[1] !== undefined) {"
   "            disconnect0.call(this, t.bus, arguments[1]);"
   "          } else {"
   "            disconnect0.call(this, t.bus);"
   "          }"
   "        }"
   "      }"
   "    } catch (x) {}"
   "    return result;"
   "  }"
   "  try {"
   "    if (typeof window === 'undefined') { return; }"
   "    if (window[G]) {"
   "      if (typeof window[G].start === 'function') { window[G].start(); }"
   "      return;"
   "    }"
   "    if (typeof AudioNode !== 'function' || typeof AudioContext !== 'function') { return; }"
   "    var proto = AudioNode.prototype;"
   "    connect0 = proto.connect;"
   "    disconnect0 = proto.disconnect;"
   "    proto.connect = patchedConnect;"
   "    proto.disconnect = patchedDisconnect;"
   "    Object.defineProperty(window, G, {"
   "      configurable: true, enumerable: false, writable: false,"
   "      value: {"
   "        start: function () {"
   "          active = true;"
   "          for (var i = 0; i < taps.length; i++) { try { wire(taps[i]); } catch (x) {} }"
   "        },"
   "        stop: function () {"
   "          active = false;"
   "          for (var i = 0; i < taps.length; i++) { try { unwire(taps[i]); } catch (x) {} }"
   "          return performance.timeOrigin + performance.now();"
   "        }"
   "      }"
   "    });"
   "  } catch (x) {}"
   "})();"))
