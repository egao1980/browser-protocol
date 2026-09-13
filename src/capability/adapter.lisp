(in-package #:browser-protocol)

;;; :world projection. capability-protocol 0.2.1 has no :browser vocab —
;;; extend a live :world catalogue when the slot is writable, else a blackboard.

(defclass browser-adapter (capability-protocol:capability)
  ((backend :initarg :backend :accessor browser-adapter-backend :initform nil))
  (:default-initargs :name :browser
                     :description "Headless browser / computer use.")
  (:documentation "Implements :world browser ops via browser-protocol GFs."))

(defun make-browser-adapter (&key backend)
  (make-instance 'browser-adapter :backend backend))

(defun %cap-backend (cap)
  (or (browser-adapter-backend cap)
      *browser-backend*
      (error 'browser-error
             :message "browser adapter has no backend — pass :backend or bind *browser-backend*")))

(defmethod capability-protocol:capability-operations ((cap browser-adapter))
  (list (capability-protocol:make-capability-operation
         :name 'navigate :params '((url t)) :returns t
         :doc "Navigate to URL.")
        (capability-protocol:make-capability-operation
         :name 'screenshot :params nil :returns t
         :doc "PNG octets.")
        (capability-protocol:make-capability-operation
         :name 'dom-snapshot :params nil :returns t
         :doc "DOM string or node plist.")
        (capability-protocol:make-capability-operation
         :name 'eval-js :params '((expression t)) :returns t
         :doc "Evaluate JS.")
        (capability-protocol:make-capability-operation
         :name 'computer-use :params '((goal t)) :returns t
         :doc "Computer-use loop.")))

(defmethod navigate ((cap browser-adapter) url)
  (navigate (%cap-backend cap) url))

(defmethod screenshot ((cap browser-adapter) &key)
  (screenshot (%cap-backend cap)))

(defmethod dom-snapshot ((cap browser-adapter))
  (dom-snapshot (%cap-backend cap)))

(defmethod click ((cap browser-adapter) &key selector x y)
  (click (%cap-backend cap) :selector selector :x x :y y))

(defmethod type-text ((cap browser-adapter) text &key selector x y)
  (type-text (%cap-backend cap) text :selector selector :x x :y y))

(defmethod scroll ((cap browser-adapter) &key selector x y dx dy)
  (scroll (%cap-backend cap) :selector selector :x x :y y :dx dx :dy dy))

(defmethod eval-js ((cap browser-adapter) expression)
  (eval-js (%cap-backend cap) expression))

(defmethod print-pdf ((cap browser-adapter) &key)
  (print-pdf (%cap-backend cap)))

(defmethod connect-browser ((cap browser-adapter) &key url ws-url)
  (connect-browser (%cap-backend cap) :url url :ws-url ws-url))

(defmethod close-browser ((cap browser-adapter))
  (close-browser (%cap-backend cap)))

(defmethod list-targets ((cap browser-adapter))
  (list-targets (%cap-backend cap)))

(defmethod computer-use ((cap browser-adapter) goal &key llm-backend
                         max-steps (screenshot t))
  (computer-use (%cap-backend cap) goal
                :llm-backend llm-backend
                :max-steps max-steps
                :screenshot screenshot))

(defun %try-extend-world-vocab (cat)
  (unless (member :browser (capability-protocol:catalogue-defined-names cat))
    (handler-case
        (setf (slot-value cat 'capability-protocol::defined-names)
              (append (capability-protocol:catalogue-defined-names cat)
                      (list :browser)))
      (error () nil)))
  cat)

(defun %register-on-world (adapter)
  (let ((cat (%try-extend-world-vocab
              (capability-protocol:make-catalogue :world))))
    (handler-case
        (progn
          (capability-protocol:register-capability cat adapter)
          cat)
      (capability-protocol:unknown-capability ()
        nil)
      (capability-protocol:capability-error ()
        nil))))

(defun make-browser-catalogue (&optional backend)
  "Live :world catalogue (or blackboard) with a BROWSER-ADAPTER registered."
  (let ((adapter (make-browser-adapter :backend backend)))
    (or (and (find-package :capability-protocol)
             (capability-protocol:find-catalogue :world)
             (or (when (capability-protocol:catalogue-defines-p :world :browser)
                   (let ((cat (capability-protocol:make-catalogue :world)))
                     (capability-protocol:register-capability cat adapter)
                     cat))
                 (%register-on-world adapter)))
        (register-browser-backend
         (blackboard-protocol:make-blackboard) backend))))

(defun register-browser-backend (host &optional backend)
  "Register a browser adapter for BACKEND on HOST (catalogue or blackboard)."
  (capability-protocol:register-capability
   host (or (and (browser-adapter-p backend) backend)
            (make-browser-adapter :backend backend)))
  host)

(defun browser-adapter-p (object)
  (typep object 'browser-adapter))
