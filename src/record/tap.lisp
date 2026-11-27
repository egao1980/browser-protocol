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
;;;;    Each time the processor is wired to the destination (when the tap is
;;;;    made, and by start()) the tap notes W = Math.round(ctx.currentTime *
;;;;    rate), the seq s0 of the next event, and puts a marker on the bus: a
;;;;    ConstantSourceNode of offset 256 (exact in float32) started at (M -
;;;;    0.25) / rate and stopped at (M + 0.75) / rate, so it plays the one
;;;;    context frame M = W + 1536. Only the processor hears it: the bus feeds
;;;;    nothing else and the processor's output is silent.
;;;; 4. Each audioprocess event while the tap is active. N is
;;;;    +AUDIO-TAP-BUFFER-SIZE+. The frames of its input buffer: Chrome fills
;;;;    the processor's two buffers in turn with consecutive context frames and
;;;;    fires one event per filled buffer, in order (checked on Chrome 158
;;;;    with handlers of up to 100 ms: none is skipped), so the event of seq s
;;;;    holds the N frames from
;;;;      FRAME = BASE + (s - s0) * N.
;;;;    BASE is W until the marker is seen: then, for the first event whose
;;;;    channel 0 has a sample >= 128 (at index i), M - i - (s - s0) * N when
;;;;    that is at most M and at least W - 128 (W - N after a restart: Chrome
;;;;    resumes filling the buffer it was filling at stop(), so the first
;;;;    buffer after start() begins with older frames and the marker may come
;;;;    one event later; until it is seen, a restarted tap sends nothing). In
;;;;    the events where it is seen, 256 is taken off the marker's samples in
;;;;    both channels. So FRAME is the
;;;;    context frame of the chunk's first sample as the context's own
;;;;    scheduling counts it (a source started at time T is heard from frame
;;;;    T * rate). It is not playbackTime's: Chrome sets playbackTime to
;;;;    currentTime + N / rate when the main thread dispatches the event, so
;;;;    Math.round(playbackTime * rate) - 2 * N is late by however long the
;;;;    main thread took (GitHub's macOS runner: one event 1792 frames late, a
;;;;    37 ms hole in the tone; Windows, 44.1 kHz: -256 .. +640 frames around
;;;;    the true frame from one event to the next, which moved the pitch).
;;;;    It does tell how late the event is: LATE = Math.round(playbackTime *
;;;;    rate) - 2 * N - FRAME. From frame FRAME + 2N on Chrome refills this
;;;;    buffer with newer frames, so the first LATE + 3 * 128 - N samples (a
;;;;    render quantum in progress and a margin) may be newer and count as
;;;;    silent, and so do the samples of frames before W (a buffer begun
;;;;    before a stop()). When that is all N, the event sends nothing.
;;;;    The samples are encoded as interleaved signed 16-bit little-endian
;;;;    codes, code = Math.round(x * 32768) clamped to -32768 .. 32767 (NaN ->
;;;;    0), then base64 (btoa). An all-zero chunk is not sent. Otherwise, when
;;;;    window[+AUDIO-BINDING-NAME+] is a function, it is called with
;;;;    JSON.stringify of
;;;;      {v: 1, track, seq, rate: ctx.sampleRate, channels: 2, frame: FRAME,
;;;;       contextTime, performanceTime, timeOrigin: performance.timeOrigin,
;;;;       pcm}
;;;;    where contextTime / performanceTime is ctx.getOutputTimestamp(), or,
;;;;    when its performanceTime is not > 0 (the output has not started),
;;;;    ctx.currentTime and performance.now(). A chunk goes out as soon as it
;;;;    is produced, so a DOM swap loses nothing and a navigation at most the
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
   "  var Q = 128;"
   "  var LEAD = 1536;"
   "  var MARK = 256;"
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
   "  function mark(t) {"
   "    var ctx = t.ctx;"
   "    var rate = ctx.sampleRate;"
   "    var w = Math.round(ctx.currentTime * rate);"
   "    t.wiredAt = w;"
   "    t.base = w;"
   "    t.seq0 = t.seq;"
   "    t.marker = w + LEAD;"
   "    t.marking = 0;"
   "    t.restarted = t.wirings > 0;"
   "    t.wirings = t.wirings + 1;"
   "    try {"
   "      var source = ctx.createConstantSource();"
   "      source.offset.value = MARK;"
   "      connect0.call(source, t.bus);"
   "      source.start((t.marker - 0.25) / rate);"
   "      source.stop((t.marker + 0.75) / rate);"
   "      t.marking = 1;"
   "    } catch (x) {}"
   "  }"
   "  function wire(t) {"
   "    if (!t.wired) { mark(t); connect0.call(t.proc, t.ctx.destination); t.wired = true; }"
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
   "    var ctx = t.ctx;"
   "    var rate = ctx.sampleRate;"
   "    var input = e.inputBuffer;"
   "    var n = input.length;"
   "    var left = input.getChannelData(0);"
   "    var right = input.numberOfChannels > 1 ? input.getChannelData(1) : left;"
   "    var cycle = seq - t.seq0;"
   "    var at = -1;"
   "    if (t.marking > 0) {"
   "      for (var i = 0; i < n; i++) { if (left[i] >= MARK / 2) { at = i; break; } }"
   "      if (at >= 0 && t.marking === 1) {"
   "        var base = t.marker - at - cycle * N;"
   "        if (base <= t.marker && base >= t.wiredAt - (t.restarted ? N : Q)) { t.base = base; }"
   "        t.marking = 2;"
   "      } else if (at < 0 && t.marking === 2) {"
   "        t.marking = 0;"
   "      }"
   "    }"
   "    if (t.restarted && t.marking === 1) { return; }"
   "    var frame = t.base + cycle * N;"
   "    var late = Math.round(e.playbackTime * rate) - 2 * N - frame;"
   "    var from = Math.max(0, t.wiredAt - frame, late + 3 * Q - N);"
   "    if (from >= n) { return; }"
   "    var bytes = new Uint8Array(n * 4);"
   "    var view = new DataView(bytes.buffer);"
   "    var heard = false;"
   "    for (var p = from; p < n; p++) {"
   "      var x = left[p];"
   "      var y = right[p];"
   "      if (at >= 0 && x >= MARK / 2) { x -= MARK; y -= MARK; }"
   "      var a = code(x);"
   "      var b = code(y);"
   "      if (a !== 0 || b !== 0) { heard = true; }"
   "      view.setInt16(4 * p, a, true);"
   "      view.setInt16(4 * p + 2, b, true);"
   "    }"
   "    if (!heard) { return; }"
   "    var binding = window[B];"
   "    if (typeof binding !== 'function') { return; }"
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
   "      frame: frame, diag: {w: t.wiredAt, base: t.base, at: at, late: late, from: from, cycle: cycle,"
   "        ct: ctx.currentTime, now: performance.now(), tstart: (window.tone && window.tone.start) || null},"
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
   "             track: doc + '/' + (taps.length + 1),"
   "             base: 0, seq0: 0, wiredAt: 0, marker: 0, marking: 0,"
   "             wirings: 0, restarted: false};"
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
