(in-package #:browser-protocol/record/tests)

;;; AUDIO-TAP-SCRIPT, statically. What it does in a page is checked by the
;;; live tests (a strict-CSP page in headless Chrome).

(deftest audio-tap-script-is-stable-text
  (let ((a (rec:audio-tap-script))
        (b (rec:audio-tap-script)))
    (ok (stringp a))
    (ok (string= a b) "the same text on every call")))

(deftest audio-tap-script-uses-the-named-binding-and-global
  (let ((js (rec:audio-tap-script)))
    (ok (search rec:+audio-binding-name+ js))
    (ok (search rec:+audio-tap-global+ js))))

(deftest audio-tap-script-chooses-a-script-processor
  ;; The method locked by the brief: a ScriptProcessorNode of
  ;; +AUDIO-TAP-BUFFER-SIZE+ frames, timed by getOutputTimestamp, patched in
  ;; through AudioNode.prototype.connect. Nothing a strict CSP refuses.
  (let ((js (rec:audio-tap-script)))
    (ok (search "createScriptProcessor" js))
    (ok (search (princ-to-string rec:+audio-tap-buffer-size+) js))
    (ok (search "getOutputTimestamp" js))
    (ok (search "playbackTime" js))
    (ok (search "AudioNode.prototype" js))
    (ok (search "AudioDestinationNode" js))
    (ok (not (search "audioWorklet" js)) "no AudioWorklet module")
    (ok (not (search "blob:" js)) "no blob: URL")
    (ok (not (search "createObjectURL" js)))
    (ok (not (search "new Worker" js)))
    (ok (not (search "MediaRecorder" js)) "PCM, not MediaRecorder")))
