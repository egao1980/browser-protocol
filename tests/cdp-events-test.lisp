(in-package #:browser-protocol/tests)

;;; Defender edge cases for #2 (id matching, events, navigate wait) and #1
;;; (stack JSON / base64 errors). FAKE-CHROME is in cdp-session-test.lisp.

(defun %scripted-backend (messages &rest keys)
  "A CDP backend whose RECV-FN pops MESSAGES (functions are called with the
   last command sent); NIL once they run out. → (values backend sent-fn)."
  (let ((queue (copy-list messages))
        (sent '()))
    (values
     (apply #'browser-protocol:make-cdp-browser-backend
            :send-fn (lambda (cmd) (push cmd sent))
            :recv-fn (lambda ()
                       (let ((m (pop queue)))
                         (if (functionp m) (funcall m (first sent)) m)))
            keys)
     (lambda () (reverse sent)))))

(defun %reply (result)
  "A message function: the reply to the last command, with RESULT."
  (lambda (cmd) (%h "id" (gethash "id" cmd) "result" result)))

(deftest stale-replies-are-dropped
  ;; A reply to a command given up on (id 99) is not taken as ours.
  (let ((b (%scripted-backend (list (%h "id" 99 "result" (%h "value" "stale"))
                                    (%reply (%h "value" "fresh"))))))
    (ok (equal "fresh" (gethash "value" (browser-protocol:cdp-call b "Runtime.evaluate"))))))

(deftest cdp-error-reply-signals-browser-error
  (let ((b (%scripted-backend
            (list (lambda (cmd)
                    (%h "id" (gethash "id" cmd)
                        "error" (%h "code" -32000 "message" "Cannot find context"
                                    "data" "frame detached")))))))
    (handler-case (progn (browser-protocol:cdp-call b "Runtime.evaluate")
                         (ok nil "no error"))
      (browser-protocol:browser-error (c)
        (ok (search "Cannot find context" (princ-to-string c)) (princ-to-string c))
        (ok (search "frame detached" (princ-to-string c)))
        (ok (equal "Runtime.evaluate" (browser-protocol:browser-error-method c)))))))

(deftest closed-transport-is-browser-disconnected
  (let ((b (%scripted-backend '())))
    (ok (signals (browser-protocol:cdp-call b "Runtime.evaluate")
                 'browser-protocol:browser-disconnected))))

(deftest on-cdp-event-sees-events-read-before-a-reply
  (let ((b (fake-chrome-backend))
        (seen '()))
    (browser-protocol:on-cdp-event b "Target.targetCreated"
                                   (lambda (params)
                                     (push (gethash "targetId" (gethash "targetInfo" params)) seen)))
    (browser-protocol:connect-browser b)
    (ok (equal '("PAGE1" "SW1" "SW2") (reverse seen)))
    (browser-protocol:off-cdp-event b "Target.targetCreated")
    (setf seen '())
    (browser-protocol:connect-browser b)
    (ok (null seen) "OFF-CDP-EVENT removes the handler")))

(deftest wait-for-cdp-event-takes-buffered-events-in-order
  (let ((b (fake-chrome-backend)))
    (browser-protocol:connect-browser b)
    (flet ((next-target (&rest keys)
             (gethash "targetId"
                      (gethash "targetInfo"
                               (apply #'browser-protocol:wait-for-cdp-event b
                                      "Target.targetCreated" keys)))))
      (ok (equal "PAGE1" (next-target)))
      (ok (equal "SW2" (next-target :test (lambda (p)
                                            (equal "SW2" (gethash "targetId" (gethash "targetInfo" p)))))))
      (ok (equal "SW1" (next-target)))
      ;; Buffer empty, transport empty: the fake peer's RECV-FN times out.
      (ok (signals (next-target) 'browser-protocol:browser-timeout)))))

(deftest navigate-wait-until-commit-and-domcontentloaded
  (let ((b (fake-chrome-backend)))
    (browser-protocol:navigate b "data:text/html,<title>c</title>" :wait-until :commit)
    (ok (equal "interactive" (browser-protocol:eval-js b "document.readyState"))
        ":commit returns before the load event")
    (browser-protocol:navigate b "data:text/html,<title>d</title>" :wait-until :domcontentloaded)
    (ok (equal "d" (browser-protocol:eval-js b "document.title")))
    (ok (signals (browser-protocol:navigate b "data:," :wait-until :networkidle)
                 'browser-protocol:browser-error)
        "unknown :wait-until")))

(deftest navigate-error-text-signals-browser-error
  (let ((b (%scripted-backend
            (list (%reply (%h))
                  (%reply (%h "frameId" "F1" "loaderId" "L1"
                              "errorText" "net::ERR_NAME_NOT_RESOLVED"))))))
    (handler-case (progn (browser-protocol:navigate b "http://no-such-host.invalid/")
                         (ok nil "no error"))
      (browser-protocol:browser-error (c)
        (ok (equal "http://no-such-host.invalid/" (browser-protocol:browser-error-url c)))
        (ok (search "ERR_NAME_NOT_RESOLVED" (princ-to-string c)))))))

(deftest same-document-navigate-does-not-wait
  ;; No loaderId (a #fragment): Chrome fires no load event. The script ends
  ;; after the reply, so a wait would read NIL and signal.
  (let ((b (%scripted-backend (list (%reply (%h)) (%reply (%h "frameId" "F1"))))))
    (ok (equal "https://ex.test/#part" (browser-protocol:navigate b "https://ex.test/#part")))))

(deftest navigate-times-out-on-a-busy-page
  ;; Events keep coming but never the load event: TIMEOUT still ends it.
  (let* ((calls 0)
         (b (browser-protocol:make-cdp-browser-backend
             :timeout 0.3
             :send-fn (lambda (cmd) (declare (ignore cmd)))
             :recv-fn (let ((replied 0))
                        (lambda ()
                          (incf calls)
                          (cond
                            ((< replied 2)
                             (incf replied)
                             (%h "id" replied "result" (%h "frameId" "F1" "loaderId" "L1")))
                            (t (sleep 0.01)
                               (%event "Network.dataReceived" "dataLength" 1))))))))
    (handler-case (progn (browser-protocol:navigate b "https://slow.test/")
                         (ok nil "no timeout"))
      (browser-protocol:browser-timeout (c)
        (ok (equal "https://slow.test/" (browser-protocol:browser-error-url c)))
        (ok (typep (browser-protocol:browser-error-cause c) 'browser-protocol:browser-timeout))))
    (ok (> calls 5) "kept reading events until the deadline")))

(deftest events-of-other-sessions-are-not-ours
  (let ((b (%scripted-backend
            (list (%reply (%h))
                  (%reply (%h "frameId" "F1" "loaderId" "L1"))
                  (%h "method" "Page.loadEventFired" "sessionId" "OTHER" "params" (%h))
                  (%h "method" "Page.loadEventFired" "sessionId" "S1" "params" (%h "timestamp" 7)))
            :session-id "S1")))
    (browser-protocol:navigate b "https://ex.test/")
    (ok (equal "OTHER" (gethash "sessionId"
                                (find "Page.loadEventFired"
                                      (browser-protocol::%cdp-events b)
                                      :key (lambda (m) (gethash "method" m)) :test #'equal)))
        "the other session's load event stays in the buffer")))

(deftest event-buffer-is-bounded
  (let* ((events (loop for n below 10
                       collect (%h "method" "Log.entryAdded" "params" (%h "n" n))))
         (b (%scripted-backend (append events (list (%reply (%h)))))))
    (let ((browser-protocol:*cdp-event-buffer-limit* 4))
      (browser-protocol:cdp-call b "Runtime.enable"))
    (ok (equal '(6 7 8 9)
               (mapcar (lambda (m) (gethash "n" (gethash "params" m)))
                       (browser-protocol::%cdp-events b))))))

(deftest malformed-json-is-browser-error
  (handler-case (progn (browser-protocol:decode-cdp-message "{\"id\":")
                       (ok nil "no error"))
    (browser-protocol:browser-error (c)
      (ok (typep (browser-protocol:browser-error-cause c) 'json-protocol:json-error)))))

(deftest cdp-json-false-null-and-octets
  ;; json-protocol value mapping: false → NIL (present), null → :NULL.
  (let ((msg (browser-protocol:decode-cdp-message
              "{\"id\":3,\"result\":{\"a\":false,\"b\":null,\"c\":[1,2.5,\"x\"]}}")))
    (multiple-value-bind (a present) (gethash "a" (browser-protocol:cdp-message-result msg))
      (ok (and present (null a))))
    (ok (eq :null (gethash "b" (browser-protocol:cdp-message-result msg))))
    (ok (equalp #(1 2.5d0 "x") (gethash "c" (browser-protocol:cdp-message-result msg)))))
  (ok (equalp #(137 80 78 71)
              (browser-protocol::%octets-from-b64 "iVBORw=="))))

(deftest nil-backend-uses-browser-backend
  ;; #3: the NIL-backend methods use *BROWSER-BACKEND* (WITH-BROWSER binds it).
  (let* ((b (browser-protocol:make-mock-browser-backend))
         (browser-protocol:*browser-backend* b))
    (ok (equal "https://ex.test/nil" (browser-protocol:navigate nil "https://ex.test/nil")))
    (ok (equal "https://ex.test/nil" (browser-protocol:mock-browser-url b)))))
