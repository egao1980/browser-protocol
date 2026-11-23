(in-package #:browser-protocol/tests)

;;; Prosecution round 1 for #2: a command sent from an ON-CDP-EVENT handler.
;;; Handlers run inside the read loop of the command (or WAIT-FOR-CDP-EVENT)
;;; that read the event. A CDP-CALL made by the handler reads the transport
;;; itself, so:
;;;  - the reply to the outer command, when it comes first, is dropped as
;;;    "a reply to a command given up on", and the outer command times out;
;;;  - an event the outer WAIT-FOR-CDP-EVENT wants (Page.loadEventFired) goes
;;;    to the buffer, which the wait checks only before its first read, so
;;;    NAVIGATE times out on a page that has loaded.
;;; Playwright's page.route("**/*", r => r.continue_()) is exactly this:
;;; Fetch.requestPaused → Fetch.continueRequest from the handler, and Chrome
;;; pauses a page's subresources in a burst, so the handlers nest.

(deftest handler-command-keeps-the-outer-reply
  ;; Outer Runtime.evaluate (id 1). Chrome sends an event, the handler sends
  ;; Page.handleJavaScriptDialog (id 2), and the reply to id 1 arrives before
  ;; the reply to id 2.
  (let ((b (%scripted-backend
            (list (%h "method" "Page.javascriptDialogOpening"
                      "params" (%h "type" "alert" "message" "hi"))
                  (%h "id" 1 "result" (%h "result" (%h "type" "number" "value" 42)))
                  (%h "id" 2 "result" (%h)))
            :timeout 0.5))
        (inner nil))
    (browser-protocol:on-cdp-event
     b "Page.javascriptDialogOpening"
     (lambda (params)
       (declare (ignore params))
       (setf inner (browser-protocol:cdp-call b "Page.handleJavaScriptDialog"
                                              (%h "accept" t)))))
    (let ((got (handler-case (browser-protocol:eval-js b "alert('hi'); 42")
                 (error (c) (list :error (type-of c) (princ-to-string c))))))
      (ok (equal 42 got) (format nil "eval-js → ~s (want 42)" got)))
    (ok (hash-table-p inner) "the handler's command got its reply")))

(deftest load-event-read-by-a-handler-command-ends-navigate
  ;; NAVIGATE waits for Page.loadEventFired. A handler on an earlier event
  ;; sends a command; Chrome fires the load event before that reply.
  (let ((b (%scripted-backend
            (list (%reply (%h))         ; Page.enable
                  (%reply (%h "frameId" "F1" "loaderId" "L1")) ; Page.navigate
                  (%h "method" "Page.domContentEventFired" "params" (%h "timestamp" 1))
                  (%h "method" "Page.loadEventFired" "params" (%h "timestamp" 2))
                  (%reply (%h "result" (%h "type" "boolean" "value" t))))
            :timeout 0.5)))
    (browser-protocol:on-cdp-event
     b "Page.domContentEventFired"
     (lambda (params)
       (declare (ignore params))
       (browser-protocol:cdp-call b "Runtime.evaluate" (%h "expression" "true"))))
    (let ((got (handler-case (browser-protocol:navigate b "https://ex.test/")
                 (error (c) (list :error (type-of c) (princ-to-string c))))))
      (ok (equal "https://ex.test/" got)
          (format nil "navigate → ~s (want the URL: the load event came before the handler's reply)" got)))))

(deftest route-continue-during-navigate-on-real-chrome
  ;; Fetch.enable on every URL, Fetch.continueRequest from the
  ;; Fetch.requestPaused handler (page.route + route.continue_), then
  ;; NAVIGATE to a page with six images. Port 9 refuses, so each image fails
  ;; fast and the page loads.
  (let ((chrome (%chrome-executable)))
    (if (null chrome)
        (skip "no Chrome/Chromium (set CHROME_PATH)")
        (let ((b (browser-protocol:launch-browser :timeout 10))
              (continued 0)
              (page (format nil "data:text/html,<title>imgs</title>~{<img src='http://127.0.0.1:9/~d.png'>~}"
                            '(0 1 2 3 4 5))))
          (unwind-protect
               (progn
                 (browser-protocol:cdp-call b "Fetch.enable"
                                            (%h "patterns" (vector (%h "urlPattern" "*"))))
                 (browser-protocol:on-cdp-event
                  b "Fetch.requestPaused"
                  (lambda (params)
                    (browser-protocol:cdp-call b "Fetch.continueRequest"
                                               (%h "requestId" (gethash "requestId" params)))
                    (incf continued)))
                 (let ((got (handler-case (browser-protocol:navigate b page)
                              (error (c) (list :error (type-of c) (princ-to-string c))))))
                   (ok (equal page got)
                       (format nil "navigate → ~a"
                               (if (consp got) (subseq (third got) 0 (min 120 (length (third got)))) got))))
                 (ok (= 6 continued) (format nil "~d of 6 requests continued" continued))
                 (ok (equal "complete" (browser-protocol:eval-js b "document.readyState"))))
            (browser-protocol:close-browser b))))))
