(defsystem "browser-protocol"
  :version "0.3.0"
  :description "CLOS browser protocol for cl-stack (CDP client + computer-use loop)"
  :author "egao1980"
  :license "MIT"
  ;; CDP JSON and screenshot / PDF base64 go through the stack protocols (#1).
  ;; bt2 (the stack's concurrency default): replies and events reach their
  ;; waiters across threads and handler re-entry (#2).
  :depends-on ("llm-protocol" "json-protocol" "json-backend-jzon" "encoding-protocol"
               "bordeaux-threads")
  :properties (:cl-repo
               (:ci (:with ("browser-protocol/capability" "browser-protocol/launch"))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "protocol")
               (:file "cdp")
               (:file "mock")
               (:file "computer-use"))
  :in-order-to ((test-op (test-op "browser-protocol/tests"))))

(defsystem "browser-protocol/launch"
  :version "0.3.0"
  :description "Launch / connect Chrome, Chromium or Edge over CDP (ws-protocol + process-protocol)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("browser-protocol" "ws-protocol" "ws-backend-websocket-driver"
               "process-protocol" "process-backend-uiop" "bordeaux-threads")
  :pathname "src"
  :components ((:file "launch"))
  :in-order-to ((test-op (test-op "browser-protocol/tests"))))

(defsystem "browser-protocol/capability"
  :version "0.3.0"
  :description "capability-protocol :world adapter over browser-protocol"
  :author "egao1980"
  :license "MIT"
  :depends-on ("browser-protocol" "capability-protocol")
  :serial t
  :pathname "src/capability"
  :components ((:file "adapter"))
  :in-order-to ((test-op (test-op "browser-protocol/tests"))))

(defsystem "browser-protocol/record"
  :version "0.3.0"
  :description "Record what a browser page shows and plays into one MP4: CDP screencast frames at a constant frame rate, the page's Web Audio through an injected tap (strict CSP pages included), external WAV clips, mixed with audio-protocol and muxed (H.264 + AAC) by ffmpeg through process-protocol"
  :author "egao1980"
  :license "MIT"
  ;; BR1. The core keeps its dependencies: audio (mix, resample, WAV) and
  ;; ffmpeg (process-protocol) only come with this system.
  :depends-on ("browser-protocol" "json-protocol" "encoding-protocol" "bordeaux-threads"
               (:version "audio-protocol" "0.2.0")
               (:version "process-protocol" "0.4.1")
               (:version "process-backend-uiop" "0.3.4"))
  :properties (:cl-repo (:ci (:with ("browser-protocol/launch"))))
  :serial t
  :pathname "src/record"
  :components ((:file "package")
               (:file "conditions")
               (:file "model")
               (:file "video")
               (:file "audio")
               (:file "tap")
               (:file "ffmpeg")
               (:file "recording"))
  :in-order-to ((test-op (test-op "browser-protocol/record/tests"))))

(defsystem "browser-protocol/record/tests"
  :depends-on ("browser-protocol/record"
               "browser-protocol/launch"
               (:version "audio-protocol" "0.2.0")
               "json-protocol"
               "encoding-protocol"
               "process-protocol"
               "bordeaux-threads"
               (:version "rove" "0.11.1"))
  :pathname "tests/record"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "conditions-test")
               (:file "model-test")
               (:file "video-test")
               (:file "pcm-test")
               (:file "track-test")
               (:file "mix-test")
               (:file "tap-test")
               (:file "ffmpeg-test")
               (:file "recording-test")
               (:file "live-test")
               (:static-file "fixtures/tone.html")
               (:static-file "fixtures/tone.css")
               (:static-file "fixtures/tone.js")
               (:static-file "fixtures/blank.html"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))

(defsystem "browser-protocol/tests"
  :depends-on ("browser-protocol"
               "browser-protocol/capability"
               "browser-protocol/launch"
               "llm-protocol"
               "json-protocol"
               "process-protocol"
               "bordeaux-threads"
               "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "protocol-test")
               (:file "cdp-test")
               (:file "computer-use-test")
               (:file "restarts-test")
               (:file "capability-test")
               ;; Evidence for #1 (private JSON / base64) and #2 (launch, ids, load).
               (:file "stack-json-test")
               (:file "cdp-session-test")
               (:file "launch-test")
               ;; Defender edge cases: ids, events, navigate wait, JSON errors.
               (:file "cdp-events-test")
               (:file "cdp-reentrancy-test")
               (:file "stack-json-false-test")
               ;; Defender round 2: threads, handler re-entry, RemoteObject values.
               (:file "cdp-concurrency-test")
               ;; Prosecution round 2: navigate takes the last page's load event.
               (:file "navigate-stale-load-test")
               (:file "navigate-documents-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
