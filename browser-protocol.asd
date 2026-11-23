(defsystem "browser-protocol"
  :version "0.1.0"
  :description "CLOS browser protocol for cl-stack (CDP client + computer-use loop)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("llm-protocol")
  :properties (:cl-repo
               (:ci (:with ("browser-protocol/capability"))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "protocol")
               (:file "cdp")
               (:file "mock")
               (:file "computer-use"))
  :in-order-to ((test-op (test-op "browser-protocol/tests"))))

(defsystem "browser-protocol/capability"
  :version "0.1.0"
  :description "capability-protocol :world adapter over browser-protocol"
  :author "egao1980"
  :license "MIT"
  :depends-on ("browser-protocol" "capability-protocol")
  :serial t
  :pathname "src/capability"
  :components ((:file "adapter"))
  :in-order-to ((test-op (test-op "browser-protocol/tests"))))

(defsystem "browser-protocol/tests"
  :depends-on ("browser-protocol"
               "browser-protocol/capability"
               "llm-protocol"
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
               (:file "launch-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
