(in-package #:browser-protocol/tests)

;;; Defender, round 2 for #2 and #1. Whoever reads a message files it: a
;;; reply goes to the command waiting for its id, an event to the buffer
;;; and its handlers. One thread reads at a time; the others wait until it
;;; files something. And Runtime.evaluate's RemoteObject → a Lisp value.

(defun %in-thread (fn)
  "Run FN in a new thread. → a function that joins it and returns
   (:ok value) or (:error type text): an unhandled error in a thread would
   end a --non-interactive test image."
  (let* ((result nil)
         (thread (bt2:make-thread
                  (lambda ()
                    (setf result
                          (handler-case (list :ok (funcall fn))
                            (error (c) (list :error (type-of c) (princ-to-string c))))))
                  :name "browser-protocol test")))
    (lambda () (bt2:join-thread thread) result)))

(defun %echo (cmd)
  "The reply to CMD: its expression back as \"echo\"."
  (%h "id" (gethash "id" cmd)
      "result" (%h "echo" (gethash "expression" (gethash "params" cmd)))))

(deftest two-threads-each-get-their-own-reply
  ;; Both commands go out before any reply; the replies come newest first,
  ;; to whichever thread reads. Each thread gets the reply with its id.
  (let* ((lock (bt2:make-lock))
         (sent '())
         (answered '())
         (b (browser-protocol:make-cdp-browser-backend
             :timeout 5
             :send-fn (lambda (cmd) (bt2:with-lock-held (lock) (push cmd sent)))
             :recv-fn (lambda ()
                        (loop repeat 400
                              until (bt2:with-lock-held (lock) (= 2 (length sent)))
                              do (sleep 0.005))
                        (let ((cmd (bt2:with-lock-held (lock)
                                     (find-if-not (lambda (c) (member c answered)) sent))))
                          (when cmd
                            (push cmd answered)
                            (%echo cmd))))))
         (joins (loop for i below 2
                      collect (let ((expression (format nil "e~d" i)))
                                (%in-thread
                                 (lambda ()
                                   (gethash "echo"
                                            (browser-protocol:cdp-call
                                             b "Runtime.evaluate"
                                             (%h "expression" expression)))))))))
    (ok (equal '((:ok "e0") (:ok "e1")) (mapcar #'funcall joins)))))

(deftest a-waiting-thread-keeps-its-own-deadline
  ;; Thread A reads (its reply takes 0.6 s). B's command, 0.2 s limit, waits
  ;; for A's read meanwhile: B times out at its own deadline, A still gets
  ;; its reply, and B's late reply is dropped.
  (let* ((lock (bt2:make-lock))
         (sent '())
         (b (browser-protocol:make-cdp-browser-backend
             :timeout 5
             :send-fn (lambda (cmd) (bt2:with-lock-held (lock) (push cmd sent)))
             :recv-fn (let ((n 0))
                        (lambda ()
                          (sleep 0.6)
                          (bt2:with-lock-held (lock)
                            (incf n)
                            ;; Replies in send order.
                            (let ((cmd (nth (- (length sent) n) sent)))
                              (and cmd (%echo cmd))))))))
         (a (%in-thread (lambda ()
                          (gethash "echo" (browser-protocol:cdp-call
                                           b "Runtime.evaluate" (%h "expression" "a")))))))
    ;; Until A is inside RECV-FN.
    (loop repeat 400 until (browser-protocol::%cdp-reader b) do (sleep 0.005))
    (let* ((start (get-internal-real-time))
           (got (handler-case (browser-protocol::%cdp-browser-call
                               b "Runtime.evaluate" (%h "expression" "b") 0.2)
                  (browser-protocol:browser-timeout () :timeout)))
           (took (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
      (ok (eq :timeout got) (format nil "B → ~s" got))
      (ok (< took 0.5) (format nil "B gave up after ~,2fs (limit 0.2s)" took)))
    (ok (equal '(:ok "a") (funcall a)))
    (ok (zerop (hash-table-count (browser-protocol::%cdp-replies b)))
        "B's id is no longer in flight")))

(deftest handler-wait-for-event-sees-later-events
  ;; A handler that waits for an event the outer command reads after it:
  ;; the outer command's read files it, the handler's wait finds it.
  (let ((b (%scripted-backend
            (list (%h "method" "Page.frameNavigated" "params" (%h "n" 1))
                  (%h "method" "Page.loadEventFired" "params" (%h "timestamp" 5))
                  (%h "id" 1 "result" (%h "result" (%h "type" "number" "value" 7))))
            :timeout 0.5))
        (seen nil))
    (browser-protocol:on-cdp-event
     b "Page.frameNavigated"
     (lambda (params)
       (declare (ignore params))
       (setf seen (gethash "timestamp"
                           (browser-protocol:wait-for-cdp-event b "Page.loadEventFired")))))
    (ok (eql 7 (browser-protocol:eval-js b "7")))
    (ok (eql 5 seen))))

(deftest nested-handlers-each-get-their-reply
  ;; Six requestPaused events in a burst, each handler sends a command:
  ;; the handlers nest, every reply reaches its own command.
  (let* ((queue '())
         (b (browser-protocol:make-cdp-browser-backend
             :timeout 1
             :send-fn (lambda (cmd)
                        (let ((method (gethash "method" cmd)))
                          (cond
                            ((equal method "Page.navigate")
                             (setf queue
                                   (append queue
                                           (loop for n below 6
                                                 collect (%h "method" "Fetch.requestPaused"
                                                             "params" (%h "requestId" n)))
                                           (list (%h "id" (gethash "id" cmd) "result" (%h))))))
                            (t ;; continueRequest: the reply after the other events
                             (setf queue (append queue
                                                 (list (%h "id" (gethash "id" cmd)
                                                           "result" (%h)))))))))
             :recv-fn (lambda () (pop queue))))
         (continued '()))
    (browser-protocol:on-cdp-event
     b "Fetch.requestPaused"
     (lambda (params)
       (browser-protocol:cdp-call b "Fetch.continueRequest"
                                  (%h "requestId" (gethash "requestId" params)))
       (push (gethash "requestId" params) continued)))
    (browser-protocol:cdp-call b "Page.navigate" (%h "url" "https://ex.test/"))
    (ok (equal '(0 1 2 3 4 5) (sort (copy-list continued) #'<)))
    (ok (zerop (hash-table-count (browser-protocol::%cdp-replies b)))
        "no command left in flight")))

(defun %evaluate-reply (remote-object &rest more)
  "A message function: Chrome's Runtime.evaluate reply with REMOTE-OBJECT."
  (lambda (cmd)
    (%h "id" (gethash "id" cmd)
        "result" (apply #'%h "result" remote-object more))))

(deftest eval-js-maps-remote-objects
  (flet ((eval-reply (remote-object &rest more)
           (let ((b (%scripted-backend (list (apply #'%evaluate-reply remote-object more)))))
             (handler-case (browser-protocol:eval-js b "x")
               (browser-protocol:browser-error (c) (list :browser-error (princ-to-string c)))))))
    (ok (null (eval-reply (%h "type" "boolean" "value" nil))) "false → NIL")
    (ok (eq t (eval-reply (%h "type" "boolean" "value" t))) "true → T")
    (ok (null (eval-reply (%h "type" "undefined"))) "undefined → NIL")
    (ok (eq :null (eval-reply (%h "type" "object" "subtype" "null" "value" :null)))
        "null → :NULL")
    (ok (equal "" (eval-reply (%h "type" "string" "value" ""))) "\"\" stays a string")
    (ok (eql 0 (eval-reply (%h "type" "number" "value" 0))) "0 stays 0")
    (ok (equalp #() (eval-reply (%h "type" "object" "value" #()))) "[] → #()")
    (ok (eql (expt 10 20) (eval-reply (%h "type" "bigint" "unserializableValue" "100000000000000000000n")))
        "BigInt → integer")
    (ok (eq :nan (eval-reply (%h "type" "number" "unserializableValue" "NaN"))) "NaN")
    (ok (eq :-infinity (eval-reply (%h "type" "number" "unserializableValue" "-Infinity"))))
    (ok (eql -0.0d0 (eval-reply (%h "type" "number" "unserializableValue" "-0"))) "-0")
    (let ((fn (eval-reply (%h "type" "function" "className" "Function"))))
      (ok (and (hash-table-p fn) (equal "function" (gethash "type" fn)))
          "no value: the RemoteObject"))
    (let ((err (eval-reply (%h "type" "object" "subtype" "error" "value" (%h))
                           "exceptionDetails"
                           (%h "text" "Uncaught"
                               "exception" (%h "type" "object" "subtype" "error"
                                               "description" "Error: boom\n    at <anonymous>:1:7")))))
      (ok (and (consp err) (search "Error: boom" (second err)))
          (format nil "exception → ~s" err)))
    (let ((err (eval-reply (%h "type" "string" "value" "no element")
                           "exceptionDetails"
                           (%h "text" "Uncaught" "exception" (%h "type" "string" "value" "no element")))))
      (ok (and (consp err) (search "no element" (second err)))
          (format nil "thrown string → ~s" err)))))

(deftest click-on-a-missing-selector-is-browser-error
  ;; %js-click throws 'no element'; before, CLICK returned T anyway.
  (let ((b (%scripted-backend
            (list (%evaluate-reply (%h "type" "string" "value" "no element")
                                   "exceptionDetails"
                                   (%h "text" "Uncaught"
                                       "exception" (%h "type" "string" "value" "no element")))))))
    (ok (signals (browser-protocol:click b :selector "#missing")
                 'browser-protocol:browser-error))))

(deftest eval-js-values-and-threads-on-real-chrome
  (if (null (%chrome-executable))
      (skip "no Chrome/Chromium (set CHROME_PATH)")
      (browser-protocol:with-browser (b :timeout 10)
        (browser-protocol:navigate b "data:text/html,<title>v</title><button id=go onclick=\"this.textContent='done'\">go</button>")
        (ok (null (browser-protocol:eval-js b "undefined")) "undefined → NIL")
        (ok (eq :null (browser-protocol:eval-js b "null")) "null → :NULL")
        (ok (null (browser-protocol:eval-js b "document.querySelector('#nope') !== null")))
        (ok (eql (expt 10 20) (browser-protocol:eval-js b "10n ** 20n")) "BigInt")
        (ok (eq :nan (browser-protocol:eval-js b "0/0")) "NaN")
        (ok (equalp #(1 nil :null "x") (browser-protocol:eval-js b "[1, false, null, 'x']")))
        (ok (signals (browser-protocol:eval-js b "throw new Error('boom')")
                     'browser-protocol:browser-error))
        (ok (signals (browser-protocol:click b :selector "#missing")
                     'browser-protocol:browser-error))
        (ok (eq t (browser-protocol:click b :selector "#go")))
        (ok (equal "done" (browser-protocol:eval-js b "document.querySelector('#go').textContent")))
        ;; Two threads, 25 evaluations each, on one websocket.
        (let ((joins (loop for i below 2
                           collect (let ((i i))
                                     (%in-thread
                                      (lambda ()
                                        (loop for k below 25
                                              always (eql (+ (* 100 i) k)
                                                          (browser-protocol:eval-js
                                                           b (format nil "~d + ~d" (* 100 i) k))))))))))
          (ok (equal '((:ok t) (:ok t)) (mapcar #'funcall joins))
              "each thread got its own results")))))
