(in-package #:browser-protocol/tests)

(deftest encode-cdp-command-shape
  (let ((cmd (browser-protocol:encode-cdp-command
              1 "Page.navigate" (list :url "https://ex.test"))))
    (ok (hash-table-p cmd))
    (ok (eql 1 (browser-protocol:cdp-message-id cmd)))
    (ok (equal "Page.navigate" (browser-protocol:cdp-message-method cmd)))
    (ok (equal "https://ex.test"
               (browser-protocol:cdp-message-param cmd "url")))))

(deftest encode-cdp-command-hash-params
  (let* ((params (let ((h (make-hash-table :test 'equal)))
                   (setf (gethash "url" h) "https://lisp.org/")
                   h))
         (cmd (browser-protocol:encode-cdp-command 7 "Page.navigate" params)))
    (ok (eql 7 (gethash "id" cmd)))
    (ok (equal "Page.navigate" (gethash "method" cmd)))
    (ok (equal "https://lisp.org/"
               (gethash "url" (gethash "params" cmd))))))

(deftest decode-cdp-message-hash-and-plist
  (let* ((h (browser-protocol:decode-cdp-message
             (browser-protocol:encode-cdp-command 2 "Runtime.evaluate"
                                                  '(:expression "1+1"))))
         (p (browser-protocol:decode-cdp-message
             '(:id 3 :method "Browser.close" :result (:ok t)))))
    (ok (equal "Runtime.evaluate" (browser-protocol:cdp-message-method h)))
    (ok (equal "1+1" (browser-protocol:cdp-message-param h "expression")))
    (ok (eql 3 (browser-protocol:cdp-message-id p)))
    (ok (eq t (gethash "ok" (browser-protocol:cdp-message-result p))))))

(deftest decode-cdp-message-json-string
  (let ((msg (browser-protocol:decode-cdp-message
              "{\"id\":4,\"method\":\"Page.navigate\",\"params\":{\"url\":\"https://ex.test\"}}")))
    (ok (eql 4 (browser-protocol:cdp-message-id msg)))
    (ok (equal "Page.navigate" (browser-protocol:cdp-message-method msg)))
    (ok (equal "https://ex.test" (browser-protocol:cdp-message-param msg "url")))))

(defun %loopback-cdp (&optional replies)
  "SEND-FN records commands; RECV-FN pops REPLY functions or default result."
  (let ((sent '())
        (queue (copy-list replies)))
    (values
     (lambda (cmd)
       (push cmd sent))
     (lambda ()
       (let* ((cmd (first sent))
              (reply (if queue (pop queue) nil)))
         (if (functionp reply)
             (funcall reply cmd)
             (let ((h (make-hash-table :test 'equal)))
               (setf (gethash "id" h) (gethash "id" cmd)
                     (gethash "result" h) (or reply
                                              (let ((r (make-hash-table :test 'equal)))
                                                (setf (gethash "ok" r) t)
                                                r)))
               h))))
     (lambda () (nreverse sent)))))

(deftest cdp-backend-navigate-builds-command
  (multiple-value-bind (send recv sent-fn) (%loopback-cdp)
    (let ((b (browser-protocol:make-cdp-browser-backend
              :send-fn send :recv-fn recv)))
      (browser-protocol:navigate b "https://ex.test/cdp")
      (let ((cmd (first (funcall sent-fn))))
        (ok (equal "Page.navigate" (browser-protocol:cdp-message-method cmd)))
        (ok (equal "https://ex.test/cdp"
                   (browser-protocol:cdp-message-param cmd "url")))))))

(deftest cdp-backend-screenshot-decodes-base64
  (multiple-value-bind (send recv)
      (%loopback-cdp
       (list (lambda (cmd)
               (let ((h (make-hash-table :test 'equal))
                     (r (make-hash-table :test 'equal)))
                 (setf (gethash "data" r) "AQID"
                       (gethash "id" h) (gethash "id" cmd)
                       (gethash "result" h) r)
                 h))))
    (let* ((b (browser-protocol:make-cdp-browser-backend
               :send-fn send :recv-fn recv))
           (png (browser-protocol:screenshot b)))
      (ok (equalp #(1 2 3) png)))))

(deftest cdp-disconnected-without-fns
  (let ((b (browser-protocol:make-cdp-browser-backend)))
    (ok (signals (browser-protocol:navigate b "https://ex.test")
                 'browser-protocol:browser-disconnected))))
