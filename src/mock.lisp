(in-package #:browser-protocol)

;;; In-memory backend for tests — no Chromium, no websocket.

(defparameter +png-magic+
  (make-array 8 :element-type '(unsigned-byte 8)
              :initial-contents '(137 80 78 71 13 10 26 10)))

(defparameter +pdf-magic+
  (make-array 5 :element-type '(unsigned-byte 8)
              :initial-contents '(37 80 68 70 45)))

(defclass mock-browser-backend (browser-backend)
  ((url :initarg :url :accessor mock-browser-url :initform "about:blank")
   (dom :initarg :dom :accessor mock-browser-dom
        :initform "<html><body></body></html>")
   (screenshot :initarg :screenshot :accessor mock-browser-screenshot
               :initform +png-magic+)
   (pdf :initarg :pdf :accessor mock-browser-pdf :initform +pdf-magic+)
   (clicks :initarg :clicks :accessor mock-browser-clicks :initform nil)
   (typed :initarg :typed :accessor mock-browser-typed :initform nil)
   (scrolls :initarg :scrolls :accessor mock-browser-scrolls :initform nil)
   (evals :initarg :evals :accessor mock-browser-evals :initform nil)
   (eval-fn :initarg :eval-fn :accessor mock-browser-eval-fn :initform nil)
   (targets :initarg :targets :accessor mock-browser-targets :initform nil)
   (connected-p :initarg :connected-p :accessor mock-browser-connected-p
                :initform nil)
   (disconnected-p :initarg :disconnected-p :accessor mock-browser-disconnected-p
                   :initform nil)
   (timeout-p :initarg :timeout-p :accessor mock-browser-timeout-p
              :initform nil)))

(defun mock-browser-backend-p (object)
  (typep object 'mock-browser-backend))

(defun make-mock-browser-backend (&key url dom screenshot pdf clicks typed
                                    scrolls evals eval-fn targets
                                    connected-p disconnected-p timeout-p
                                    compute-backend sandbox-spec)
  (make-instance 'mock-browser-backend
                 :url (or url "about:blank")
                 :dom (or dom "<html><body></body></html>")
                 :screenshot (or screenshot +png-magic+)
                 :pdf (or pdf +pdf-magic+)
                 :clicks clicks
                 :typed typed
                 :scrolls scrolls
                 :evals evals
                 :eval-fn eval-fn
                 :targets (or targets
                              (list (make-browser-target
                                     :id "t1" :type "page"
                                     :url (or url "about:blank")
                                     :title "mock")))
                 :connected-p connected-p
                 :disconnected-p disconnected-p
                 :timeout-p timeout-p
                 :compute-backend compute-backend
                 :sandbox-spec sandbox-spec))

(defun use-mock-browser-backend (&rest args &key &allow-other-keys)
  (setf *browser-backend* (apply #'make-mock-browser-backend args)))

(defun %maybe-fail (backend &optional url)
  (cond
    ((mock-browser-disconnected-p backend)
     (error 'browser-disconnected :url url :message "mock browser disconnected"))
    ((mock-browser-timeout-p backend)
     (error 'browser-timeout :url url :message "mock browser timeout"))))

(defmethod navigate ((backend mock-browser-backend) url)
  (%maybe-fail backend url)
  (setf (mock-browser-url backend) url)
  url)

(defmethod dom-snapshot ((backend mock-browser-backend))
  (%maybe-fail backend)
  (mock-browser-dom backend))

(defmethod screenshot ((backend mock-browser-backend) &key)
  (%maybe-fail backend)
  (let ((octets (mock-browser-screenshot backend)))
    (if (and (vectorp octets) (not (stringp octets)))
        (%usb8 octets)
        (%usb8 +png-magic+))))

(defmethod click ((backend mock-browser-backend) &key selector x y)
  (%maybe-fail backend)
  (setf (mock-browser-clicks backend)
        (append (mock-browser-clicks backend)
                (list (list :selector selector :x x :y y))))
  t)

(defmethod type-text ((backend mock-browser-backend) text &key selector x y)
  (%maybe-fail backend)
  (setf (mock-browser-typed backend)
        (append (mock-browser-typed backend)
                (list (list :text text :selector selector :x x :y y))))
  text)

(defmethod scroll ((backend mock-browser-backend) &key selector x y dx dy)
  (%maybe-fail backend)
  (setf (mock-browser-scrolls backend)
        (append (mock-browser-scrolls backend)
                (list (list :selector selector :x x :y y :dx dx :dy dy))))
  t)

(defmethod eval-js ((backend mock-browser-backend) expression)
  (%maybe-fail backend)
  (setf (mock-browser-evals backend)
        (append (mock-browser-evals backend) (list expression)))
  (if (mock-browser-eval-fn backend)
      (funcall (mock-browser-eval-fn backend) backend expression)
      expression))

(defmethod print-pdf ((backend mock-browser-backend) &key)
  (%maybe-fail backend)
  (let ((octets (mock-browser-pdf backend)))
    (if (and (vectorp octets) (not (stringp octets)))
        (%usb8 octets)
        (%usb8 +pdf-magic+))))

(defmethod connect-browser ((backend mock-browser-backend) &key url ws-url)
  (declare (ignore ws-url))
  (%maybe-fail backend url)
  (when url (setf (mock-browser-url backend) url))
  (setf (mock-browser-connected-p backend) t)
  backend)

(defmethod close-browser ((backend mock-browser-backend))
  (%maybe-fail backend)
  (setf (mock-browser-connected-p backend) nil)
  t)

(defmethod list-targets ((backend mock-browser-backend))
  (%maybe-fail backend)
  (mapcar (lambda (item)
            (if (browser-target-p item)
                item
                (apply #'make-browser-target
                       (if (and (consp item) (keywordp (car item)))
                           item
                           (list :id (princ-to-string item))))))
          (mock-browser-targets backend)))
