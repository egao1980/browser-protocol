(in-package #:browser-protocol)

(define-condition browser-error (error)
  ((message :initarg :message :reader browser-error-message :initform nil)
   (url :initarg :url :reader browser-error-url :initform nil)
   (method :initarg :method :reader browser-error-method :initform nil)
   (cause :initarg :cause :reader browser-error-cause :initform nil
          :documentation "The wrapped condition (JSON, websocket, process), if any."))
  (:report (lambda (c s)
             (format s "browser error~@[ (~a)~]~@[: ~a~]"
                     (browser-error-method c)
                     (browser-error-message c)))))

(define-condition browser-timeout (browser-error)
  ((limit :initarg :limit :reader browser-timeout-limit :initform nil))
  (:report (lambda (c s)
             (format s "browser timeout~@[ (~as)~]~@[: ~a~]"
                     (browser-timeout-limit c)
                     (browser-error-message c)))))

(define-condition browser-disconnected (browser-error)
  ()
  (:report (lambda (c s)
             (format s "browser disconnected~@[: ~a~]"
                     (browser-error-message c)))))

(defun call-with-browser-restarts (thunk)
  "Establish RETRY / USE-VALUE around THUNK."
  (tagbody
   :retry
     (return-from call-with-browser-restarts
       (restart-case (funcall thunk)
         (retry ()
           :report "Retry the browser operation"
           (go :retry))
         (use-value (value)
           :report "Use a supplied value instead"
           :interactive (lambda ()
                          (format *query-io* "Value to use: ")
                          (force-output *query-io*)
                          (list (read *query-io*)))
           value)))))

(defmacro with-browser-restarts (&body body)
  `(call-with-browser-restarts (lambda () ,@body)))

(defun invoke-retry (&optional condition)
  (let ((r (find-restart 'retry condition)))
    (when r (invoke-restart r))))
