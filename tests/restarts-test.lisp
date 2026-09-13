(in-package #:browser-protocol/tests)

(deftest missing-backend-signals
  (let ((browser-protocol:*browser-backend* nil))
    (ok (signals (browser-protocol:navigate nil "https://ex.test")
                 'browser-protocol:browser-error))))

(deftest missing-backend-use-value
  (let* ((b (browser-protocol:make-mock-browser-backend))
         (browser-protocol:*browser-backend* nil)
         (got nil))
    (handler-bind ((browser-protocol:browser-error
                    (lambda (c)
                      (use-value b c))))
      (setf got (browser-protocol:navigate nil "https://ex.test/r")))
    (ok (equal "https://ex.test/r" got))
    (ok (equal "https://ex.test/r" (browser-protocol:mock-browser-url b)))))

(deftest timeout-signals
  (let ((b (browser-protocol:make-mock-browser-backend :timeout-p t)))
    (ok (signals (browser-protocol:navigate b "https://ex.test")
                 'browser-protocol:browser-timeout))))

(deftest timeout-use-value
  (let ((b (browser-protocol:make-mock-browser-backend :timeout-p t))
        (got :unset))
    (handler-bind ((browser-protocol:browser-timeout
                    (lambda (c)
                      (use-value "supplied" c))))
      (setf got (browser-protocol:screenshot b)))
    (ok (equal "supplied" got))))

(deftest disconnected-signals
  (let ((b (browser-protocol:make-mock-browser-backend :disconnected-p t)))
    (ok (signals (browser-protocol:click b :selector "#x")
                 'browser-protocol:browser-disconnected))))

(deftest timeout-retry
  (let* ((n 0)
         (b (browser-protocol:make-mock-browser-backend
             :eval-fn (lambda (backend expression)
                        (declare (ignore expression))
                        (incf n)
                        (if (= n 1)
                            (error 'browser-protocol:browser-timeout
                                   :message "slow")
                            (progn
                              (setf (browser-protocol:mock-browser-timeout-p backend)
                                    nil)
                              "ok")))))
         (got nil))
    (setf (browser-protocol:mock-browser-timeout-p b) nil)
    (handler-bind ((browser-protocol:browser-timeout
                    (lambda (c)
                      (browser-protocol:invoke-retry c))))
      (setf got (browser-protocol:eval-js b "1")))
    (ok (= 2 n))
    (ok (equal "ok" got))))
