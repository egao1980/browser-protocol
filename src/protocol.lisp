(in-package #:browser-protocol)

;;; Headless browser GFs. Chromium conceptually runs inside an A9 sandbox
;;; (compute-protocol). A compute backend is optional — not required.

(defclass browser-backend ()
  ((compute-backend :initarg :compute-backend :accessor browser-compute-backend
                    :initform nil)
   (sandbox-spec :initarg :sandbox-spec :accessor browser-sandbox-spec
                 :initform nil))
  (:documentation
   "Headless browser. COMPUTE-BACKEND / SANDBOX-SPEC are optional A9 handles;
    this protocol does not launch podman."))

(defun browser-backend-p (object)
  (typep object 'browser-backend))

(defvar *browser-backend* nil
  "Current BROWSER-BACKEND, or NIL.")

(defun %ensure-backend (&optional (backend *browser-backend*))
  (or backend
      (restart-case
          (error 'browser-error
                 :message "*browser-backend* is nil — bind a backend")
        (use-value (supplied)
          :report "Use a supplied browser backend"
          :interactive (lambda ()
                         (format *query-io* "Browser backend: ")
                         (force-output *query-io*)
                         (list (read *query-io*)))
          supplied))))

(defclass browser-target ()
  ((id :initarg :id :accessor browser-target-id :initform nil)
   (type :initarg :type :accessor browser-target-type :initform "page")
   (url :initarg :url :accessor browser-target-url :initform nil)
   (title :initarg :title :accessor browser-target-title :initform nil)))

(defun browser-target-p (object)
  (typep object 'browser-target))

(defun make-browser-target (&key id (type "page") url title)
  (make-instance 'browser-target :id id :type type :url url :title title))

(defgeneric navigate (backend url)
  (:documentation "Navigate BACKEND to URL."))

(defgeneric dom-snapshot (backend)
  (:documentation "Current DOM as a string or node plist."))

(defgeneric screenshot (backend &key)
  (:documentation "PNG octets (vector of unsigned-byte 8)."))

(defgeneric click (backend &key selector x y)
  (:documentation "Click SELECTOR or coordinates X/Y."))

(defgeneric type-text (backend text &key selector x y)
  (:documentation "Type TEXT into SELECTOR or at X/Y."))

(defgeneric scroll (backend &key selector x y dx dy)
  (:documentation "Scroll SELECTOR or the viewport by DX/DY."))

(defgeneric eval-js (backend expression)
  (:documentation "Evaluate JS EXPRESSION. → result."))

(defgeneric print-pdf (backend &key)
  (:documentation "Print the current page to PDF octets."))

(defgeneric connect-browser (backend &key url ws-url)
  (:documentation "Attach to a browser. URL / WS-URL are optional CDP endpoints."))

(defgeneric close-browser (backend)
  (:documentation "Detach / close the browser session."))

(defgeneric list-targets (backend)
  (:documentation "→ list of BROWSER-TARGET."))

(defmacro %define-browser-around (name extra-keys)
  (let ((ignored (loop for k in extra-keys
                       unless (member k '(&key &allow-other-keys))
                         collect (if (consp k) (car k) k))))
    `(defmethod ,name :around (backend ,@extra-keys)
       ,@(when ignored `((declare (ignore ,@ignored))))
       (call-with-browser-restarts (lambda () (call-next-method))))))

(%define-browser-around navigate (url))
(%define-browser-around dom-snapshot ())
(%define-browser-around screenshot (&key))
(%define-browser-around click (&key selector x y))
(%define-browser-around type-text (text &key selector x y))
(%define-browser-around scroll (&key selector x y dx dy))
(%define-browser-around eval-js (expression))
(%define-browser-around print-pdf (&key))
(%define-browser-around connect-browser (&key url ws-url))
(%define-browser-around close-browser ())
(%define-browser-around list-targets ())

(defmethod navigate ((backend null) url)
  (navigate (%ensure-backend backend) url))

(defmethod dom-snapshot ((backend null))
  (dom-snapshot (%ensure-backend backend)))

(defmethod screenshot ((backend null) &key)
  (screenshot (%ensure-backend backend)))

(defmethod click ((backend null) &key selector x y)
  (click (%ensure-backend backend) :selector selector :x x :y y))

(defmethod type-text ((backend null) text &key selector x y)
  (type-text (%ensure-backend backend) text :selector selector :x x :y y))

(defmethod scroll ((backend null) &key selector x y dx dy)
  (scroll (%ensure-backend backend) :selector selector :x x :y y :dx dx :dy dy))

(defmethod eval-js ((backend null) expression)
  (eval-js (%ensure-backend backend) expression))

(defmethod print-pdf ((backend null) &key)
  (print-pdf (%ensure-backend backend)))

(defmethod connect-browser ((backend null) &key url ws-url)
  (connect-browser (%ensure-backend backend) :url url :ws-url ws-url))

(defmethod close-browser ((backend null))
  (close-browser (%ensure-backend backend)))

(defmethod list-targets ((backend null))
  (list-targets (%ensure-backend backend)))

;;; --- shared helpers --------------------------------------------------------

(defun %ht (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          unless (or (null k) (eq v :omit) (null v))
            do (setf (gethash k h) v))
    h))

(defun %keyword-name (key)
  (cond
    ((stringp key) key)
    ((or (keywordp key) (symbolp key))
     (string-downcase (symbol-name key)))
    (t (princ-to-string key))))

(defun %jget (object key)
  "Lookup KEY on a JSON object (hash-table string keys, or plist/alist)."
  (let ((keys (etypecase key
                (string (list key
                              (intern (string-upcase key) :keyword)))
                (symbol (list (string-downcase (symbol-name key))
                              (symbol-name key)
                              key)))))
    (cond
      ((hash-table-p object)
       (dolist (k keys)
         (multiple-value-bind (val present) (gethash k object)
           (when present (return-from %jget val))))
       nil)
      ((and (consp object) (keywordp (car object)))
       (getf object (if (keywordp key)
                        key
                        (intern (string-upcase (string key)) :keyword))))
      ((listp object)
       (dolist (k keys)
         (let ((cell (assoc k object :test #'equal)))
           (when cell (return-from %jget (cdr cell)))))
       nil)
      (t nil))))

(defun %plist-to-ht (plist)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (%keyword-name k) h)
                   (cond
                     ((and (consp v) (keywordp (car v))) (%plist-to-ht v))
                     ((and (listp v) (consp (car v)) (keywordp (caar v)))
                      (mapcar #'%plist-to-ht v))
                     (t v))))
    h))

(defun %as-json-object (params)
  (cond
    ((null params) (%ht))
    ((hash-table-p params) params)
    ((and (consp params) (keywordp (car params))) (%plist-to-ht params))
    ((and (consp params) (consp (car params)))
     (let ((h (make-hash-table :test 'equal)))
       (dolist (pair params h)
         (setf (gethash (%keyword-name (car pair)) h) (cdr pair)))))
    (t params)))

(defun %find-symbol (package name)
  (let ((pkg (find-package package)))
    (and pkg (find-symbol name pkg))))

(defun %decode-json-string (source)
  (let* ((decode (%find-symbol :json-protocol "DECODE"))
         (backend (%find-symbol :json-protocol "*JSON-BACKEND*")))
    (if (and decode (fboundp decode) backend (boundp backend)
             (symbol-value backend))
        (funcall decode source)
        (%parse-json source))))
