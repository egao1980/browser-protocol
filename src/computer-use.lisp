(in-package #:browser-protocol)

;;; screenshot → llm-image-part → generate with action tools → execute.

(defun %tool-schema (&rest properties)
  "PROPERTIES is a plist of name → (type description)."
  (let ((props (%ht))
        (required '()))
    (loop for (name type description required-p) on properties by #'cddddr
          do (setf (gethash name props)
                   (%ht "type" type "description" description))
             (when required-p
               (push name required)))
    (%ht "type" "object"
         "properties" props
         "required" (map 'vector #'identity (nreverse required)))))

(defun computer-use-tools ()
  "LLM-TOOL descriptors for click / type / scroll / navigate / done."
  (list
   (llm-protocol:make-llm-tool
    :name "click"
    :description "Click a CSS selector or page coordinates."
    :parameters (%tool-schema
                 "selector" "string" "CSS selector" nil
                 "x" "number" "X coordinate" nil
                 "y" "number" "Y coordinate" nil))
   (llm-protocol:make-llm-tool
    :name "type"
    :description "Type text into a selector or at coordinates."
    :parameters (%tool-schema
                 "text" "string" "Text to type" t
                 "selector" "string" "CSS selector" nil
                 "x" "number" "X coordinate" nil
                 "y" "number" "Y coordinate" nil))
   (llm-protocol:make-llm-tool
    :name "scroll"
    :description "Scroll a selector or the viewport."
    :parameters (%tool-schema
                 "selector" "string" "CSS selector" nil
                 "x" "number" "X coordinate" nil
                 "y" "number" "Y coordinate" nil
                 "dx" "number" "Horizontal delta" nil
                 "dy" "number" "Vertical delta" nil))
   (llm-protocol:make-llm-tool
    :name "navigate"
    :description "Navigate the browser to a URL."
    :parameters (%tool-schema
                 "url" "string" "Absolute URL" t))
   (llm-protocol:make-llm-tool
    :name "done"
    :description "Goal is complete. Stop the computer-use loop."
    :parameters (%tool-schema
                 "reason" "string" "Why the goal is done" nil))))

(defun %arg (args key)
  (%jget args key))

(defun %parse-tool-args (arguments)
  (cond
    ((null arguments) (%ht))
    ((hash-table-p arguments) arguments)
    ((and (consp arguments) (keywordp (car arguments)))
     (%plist-to-ht arguments))
    ((stringp arguments)
     (if (plusp (length (string-trim '(#\Space #\Tab #\Newline) arguments)))
         (handler-case (%decode-json-string arguments)
           (browser-error () (%ht "raw" arguments)))
         (%ht)))
    (t arguments)))

(defun %action-name (call)
  (let ((name (llm-protocol:llm-tool-call-part-name call)))
    (when name (string-downcase (string name)))))

(defun execute-computer-action (backend call)
  "Run one LLM-TOOL-CALL-PART against BACKEND. → (:name … :result …) plist."
  (let* ((name (%action-name call))
         (args (%parse-tool-args
                (llm-protocol:llm-tool-call-part-arguments call)))
         (result
           (cond
             ((equal name "click")
              (click backend
                     :selector (%arg args "selector")
                     :x (%arg args "x")
                     :y (%arg args "y")))
             ((or (equal name "type") (equal name "type-text")
                  (equal name "type_text"))
              (type-text backend (or (%arg args "text") "")
                         :selector (%arg args "selector")
                         :x (%arg args "x")
                         :y (%arg args "y")))
             ((equal name "scroll")
              (scroll backend
                      :selector (%arg args "selector")
                      :x (%arg args "x")
                      :y (%arg args "y")
                      :dx (%arg args "dx")
                      :dy (%arg args "dy")))
             ((equal name "navigate")
              (navigate backend (%arg args "url")))
             ((equal name "done")
              :done)
             (t
              (error 'browser-error
                     :message (format nil "unknown computer-use action ~s" name))))))
    (list :name name :arguments args :result result
          :done-p (eq result :done))))

(defclass computer-use-step-result ()
  ((response :initarg :response :reader computer-use-step-response :initform nil)
   (actions :initarg :actions :reader computer-use-step-actions :initform nil)
   (done-p :initarg :done-p :reader computer-use-step-done-p :initform nil)
   (goal :initarg :goal :reader computer-use-step-goal :initform nil)))

(defun computer-use-step-result-p (object)
  (typep object 'computer-use-step-result))

(defun %image-part (octets)
  (llm-protocol:make-llm-image-part
   :data octets
   :media-type "image/png"))

(defun computer-use-step (backend llm-backend &key goal (screenshot t) turns)
  "One computer-use turn: optional screenshot → GENERATE with action tools → execute.
   GOAL is the user instruction. TURNS, when given, are extra prior LLM-TURN objects."
  (let* ((backend (%ensure-backend backend))
         (octets (when screenshot (screenshot backend)))
         (parts (append (and goal (list (llm-protocol:make-llm-text-part
                                         :text goal)))
                        (and octets (list (%image-part octets)))))
         (user (llm-protocol:make-llm-turn :role :user :parts parts))
         (all (append (llm-protocol:coerce-turns turns) (list user)))
         (response (llm-protocol:generate llm-backend all
                                          :tools (computer-use-tools)))
         (calls (llm-protocol:llm-response-tool-calls response))
         (actions (mapcar (lambda (call)
                            (execute-computer-action backend call))
                          calls))
         (done (or (find-if (lambda (a) (getf a :done-p)) actions)
                   (null calls))))
    (make-instance 'computer-use-step-result
                   :response response
                   :actions actions
                   :done-p (and done t)
                   :goal goal)))

(defun computer-use-loop (backend llm-backend &key goal (max-steps 8)
                          (screenshot t))
  "Repeat COMPUTER-USE-STEP until done or MAX-STEPS. → list of step results."
  (check-type max-steps (integer 1 *))
  (let ((steps '()))
    (loop for i from 1 to max-steps
          for step = (computer-use-step backend llm-backend
                                        :goal goal
                                        :screenshot screenshot)
          do (push step steps)
          when (computer-use-step-done-p step)
            do (return))
    (nreverse steps)))

(defgeneric computer-use (backend goal &key llm-backend max-steps screenshot)
  (:documentation "Run COMPUTER-USE-LOOP on BACKEND for GOAL."))

(defmethod computer-use ((backend browser-backend) goal &key llm-backend
                         max-steps (screenshot t))
  (computer-use-loop backend llm-backend
                     :goal goal
                     :max-steps (or max-steps 8)
                     :screenshot screenshot))
