(defpackage #:browser-protocol
  (:use #:cl)
  (:nicknames #:stack-browser)
  (:export #:browser-error
           #:browser-error-message
           #:browser-error-url
           #:browser-error-method
           #:browser-error-cause
           #:browser-timeout
           #:browser-timeout-limit
           #:browser-disconnected
           #:call-with-browser-restarts
           #:with-browser-restarts
           #:invoke-retry

           #:browser-backend
           #:browser-backend-p
           #:*browser-backend*
           #:browser-compute-backend
           #:browser-sandbox-spec

           #:navigate
           #:dom-snapshot
           #:screenshot
           #:click
           #:type-text
           #:scroll
           #:eval-js
           #:print-pdf
           #:connect-browser
           #:close-browser
           #:list-targets

           #:browser-target
           #:browser-target-p
           #:make-browser-target
           #:browser-target-id
           #:browser-target-type
           #:browser-target-url
           #:browser-target-title

           #:encode-cdp-command
           #:decode-cdp-message
           #:cdp-message-id
           #:cdp-message-method
           #:cdp-message-params
           #:cdp-message-param
           #:cdp-message-result
           #:cdp-message-error

           #:cdp-browser-backend
           #:cdp-browser-backend-p
           #:make-cdp-browser-backend
           #:use-cdp-browser-backend
           #:cdp-send-fn
           #:cdp-recv-fn
           #:cdp-session-id
           #:cdp-ws-url
           #:cdp-timeout
           #:cdp-call
           #:on-cdp-event
           #:off-cdp-event
           #:wait-for-cdp-event
           #:*cdp-receive-timeout*
           #:*cdp-event-buffer-limit*

           ;; browser-protocol/launch
           #:launch-browser
           #:with-browser
           #:connect-cdp
           #:find-browser-executable
           #:*browser-executable-candidates*
           #:*browser-executable-names*
           #:chrome-browser-backend
           #:chrome-browser-backend-p
           #:chrome-browser-process
           #:chrome-browser-profile
           #:chrome-browser-target-id

           #:mock-browser-backend
           #:mock-browser-backend-p
           #:make-mock-browser-backend
           #:use-mock-browser-backend
           #:mock-browser-url
           #:mock-browser-dom
           #:mock-browser-screenshot
           #:mock-browser-pdf
           #:mock-browser-clicks
           #:mock-browser-typed
           #:mock-browser-scrolls
           #:mock-browser-evals
           #:mock-browser-targets
           #:mock-browser-connected-p
           #:mock-browser-disconnected-p
           #:mock-browser-timeout-p
           #:mock-browser-eval-fn

           #:computer-use-tools
           #:computer-use-step-result
           #:computer-use-step-result-p
           #:computer-use-step-response
           #:computer-use-step-actions
           #:computer-use-step-done-p
           #:computer-use-step-goal
           #:computer-use-step
           #:computer-use-loop
           #:computer-use

           #:browser-adapter
           #:browser-adapter-p
           #:browser-adapter-backend
           #:make-browser-adapter
           #:make-browser-catalogue
           #:register-browser-backend))

(in-package #:browser-protocol)
