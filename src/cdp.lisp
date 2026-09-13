(in-package #:browser-protocol)

;;; CDP JSON: {id, method, params} / {id, result|error}.
;;; cdp-browser-backend talks through SEND-FN / RECV-FN so tests need no Chromium.

(defun encode-cdp-command (id method &optional params)
  "Return a CDP command object (hash-table with string keys id/method/params)."
  (check-type id integer)
  (let ((h (%ht "id" id
                "method" (if (stringp method)
                             method
                             (substitute #\. #\- (string method))))))
    (when params
      (setf (gethash "params" h) (%as-json-object params)))
    h))

(defun decode-cdp-message (message)
  "Accept a hash-table, plist, or JSON string → hash-table."
  (cond
    ((hash-table-p message) message)
    ((stringp message) (%decode-json-string message))
    ((and (consp message) (keywordp (car message))) (%plist-to-ht message))
    ((null message) (%ht))
    (t (error 'browser-error
              :message (format nil "not a CDP message: ~s" (type-of message))))))

(defun cdp-message-id (message)
  (%jget (decode-cdp-message message) "id"))

(defun cdp-message-method (message)
  (%jget (decode-cdp-message message) "method"))

(defun cdp-message-params (message)
  (%jget (decode-cdp-message message) "params"))

(defun cdp-message-param (message key)
  (%jget (cdp-message-params message) key))

(defun cdp-message-result (message)
  (%jget (decode-cdp-message message) "result"))

(defun cdp-message-error (message)
  (%jget (decode-cdp-message message) "error"))

;;; --- tiny JSON (when json-protocol is unbound) -----------------------------

(defun %parse-json (string)
  (let ((i 0)
        (n (length string)))
    (labels ((peek ()
               (and (< i n) (char string i)))
             (skip-ws ()
               (loop while (and (< i n)
                                (member (char string i)
                                        '(#\Space #\Tab #\Newline #\Return)))
                     do (incf i)))
             (eat (ch)
               (skip-ws)
               (unless (eql (peek) ch)
                 (error 'browser-error
                        :message (format nil "JSON expected ~s at ~d" ch i)))
               (incf i))
             (parse-string ()
               (eat #\")
               (let ((out (make-string-output-stream)))
                 (loop
                   (let ((ch (peek)))
                     (cond
                       ((null ch)
                        (error 'browser-error :message "unterminated JSON string"))
                       ((char= ch #\")
                        (incf i)
                        (return (get-output-stream-string out)))
                       ((char= ch #\\)
                        (incf i)
                        (let ((esc (or (peek)
                                       (error 'browser-error
                                              :message "bad JSON escape"))))
                          (incf i)
                          (write-char
                           (case esc
                             (#\" #\")
                             (#\\ #\\)
                             (#\/ #\/)
                             (#\b #\Backspace)
                             (#\f #\Page)
                             (#\n #\Newline)
                             (#\r #\Return)
                             (#\t #\Tab)
                             (#\u
                              (if (<= (+ i 4) n)
                                  (prog1 (or (code-char
                                              (parse-integer string :start i
                                                                   :end (+ i 4)
                                                                   :radix 16))
                                             #\?)
                                    (incf i 4))
                                  #\?))
                             (t esc))
                           out)))
                       (t
                        (write-char ch out)
                        (incf i)))))))
             (parse-number ()
               (skip-ws)
               (let ((start i))
                 (when (eql (peek) #\-) (incf i))
                 (loop while (and (< i n) (digit-char-p (char string i)))
                       do (incf i))
                 (when (eql (peek) #\.)
                   (incf i)
                   (loop while (and (< i n) (digit-char-p (char string i)))
                         do (incf i)))
                 (when (and (< i n) (member (char string i) '(#\e #\E)))
                   (incf i)
                   (when (member (peek) '(#\+ #\-)) (incf i))
                   (loop while (and (< i n) (digit-char-p (char string i)))
                         do (incf i)))
                 (let ((token (subseq string start i)))
                   (if (find-if (lambda (c) (member c '(#\. #\e #\E))) token)
                       (read-from-string token)
                       (parse-integer token)))))
             (parse-array ()
               (eat #\[)
               (skip-ws)
               (if (eql (peek) #\])
                   (progn (incf i) (vector))
                   (let ((items '()))
                     (loop
                       (push (parse-value) items)
                       (skip-ws)
                       (cond
                         ((eql (peek) #\])
                          (incf i)
                          (return (map 'vector #'identity (nreverse items))))
                         ((eql (peek) #\,) (incf i))
                         (t (error 'browser-error
                                   :message "bad JSON array")))))))
             (parse-object ()
               (eat #\{)
               (skip-ws)
               (let ((h (make-hash-table :test 'equal)))
                 (when (eql (peek) #\})
                   (incf i)
                   (return-from parse-object h))
                 (loop
                   (skip-ws)
                   (let ((k (parse-string)))
                     (skip-ws)
                     (eat #\:)
                     (setf (gethash k h) (parse-value)))
                   (skip-ws)
                   (cond
                     ((eql (peek) #\}) (incf i) (return h))
                     ((eql (peek) #\,) (incf i))
                     (t (error 'browser-error :message "bad JSON object"))))))
             (parse-literal (lit value)
               (when (and (<= (+ i (length lit)) n)
                          (string= string lit :start1 i :end1 (+ i (length lit))))
                 (incf i (length lit))
                 value))
             (parse-value ()
               (skip-ws)
               (case (peek)
                 (#\" (parse-string))
                 (#\{ (parse-object))
                 (#\[ (parse-array))
                 (#\t (or (parse-literal "true" t)
                          (error 'browser-error :message "bad JSON true")))
                 (#\f (or (parse-literal "false" nil)
                          (error 'browser-error :message "bad JSON false")))
                 (#\n (or (parse-literal "null" :null)
                          (error 'browser-error :message "bad JSON null")))
                 (t
                  (if (or (eql (peek) #\-) (and (peek) (digit-char-p (peek))))
                      (parse-number)
                      (error 'browser-error
                             :message (format nil "bad JSON at ~d" i)))))))
      (let ((value (parse-value)))
        (skip-ws)
        value))))

;;; --- base64 (RFC 4648) for screenshot / PDF data ---------------------------

(defparameter +b64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun %usb8 (seq)
  (coerce seq '(simple-array (unsigned-byte 8) (*))))

(defun %base64-encode (octets)
  (let* ((octets (%usb8 octets))
         (n (length octets))
         (out (make-string (* 4 (ceiling n 3)) :initial-element #\=)))
    (loop with j = 0
          for i from 0 below n by 3
          for b0 = (aref octets i)
          for b1 = (if (< (1+ i) n) (aref octets (1+ i)) 0)
          for b2 = (if (< (+ i 2) n) (aref octets (+ i 2)) 0)
          for triple = (logior (ash b0 16) (ash b1 8) b2)
          do (setf (char out j) (char +b64-alphabet+ (ldb (byte 6 18) triple))
                   (char out (1+ j)) (char +b64-alphabet+ (ldb (byte 6 12) triple)))
             (when (< (1+ i) n)
               (setf (char out (+ j 2))
                     (char +b64-alphabet+ (ldb (byte 6 6) triple))))
             (when (< (+ i 2) n)
               (setf (char out (+ j 3))
                     (char +b64-alphabet+ (ldb (byte 6 0) triple))))
             (incf j 4))
    out))

(defun %b64-value (ch)
  (cond
    ((char<= #\A ch #\Z) (- (char-code ch) (char-code #\A)))
    ((char<= #\a ch #\z) (+ 26 (- (char-code ch) (char-code #\a))))
    ((char<= #\0 ch #\9) (+ 52 (- (char-code ch) (char-code #\0))))
    ((char= ch #\+) 62)
    ((char= ch #\/) 63)
    (t nil)))

(defun %base64-decode (string)
  (let* ((chars (remove-if (lambda (c)
                             (member c '(#\= #\Space #\Newline #\Return #\Tab)))
                           string))
         (n (length chars))
         (out (make-array (* 3 (ceiling n 4))
                          :element-type '(unsigned-byte 8)
                          :fill-pointer 0)))
    (loop for i from 0 below n by 4
          for v0 = (or (%b64-value (char chars i)) 0)
          for v1 = (if (< (1+ i) n) (or (%b64-value (char chars (1+ i))) 0) 0)
          for v2 = (if (< (+ i 2) n) (or (%b64-value (char chars (+ i 2))) 0) 0)
          for v3 = (if (< (+ i 3) n) (or (%b64-value (char chars (+ i 3))) 0) 0)
          for triple = (logior (ash v0 18) (ash v1 12) (ash v2 6) v3)
          do (vector-push (ldb (byte 8 16) triple) out)
             (when (< (+ i 2) n) (vector-push (ldb (byte 8 8) triple) out))
             (when (< (+ i 3) n) (vector-push (ldb (byte 8 0) triple) out)))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun %octets-from-b64 (value)
  (cond
    ((null value) (make-array 0 :element-type '(unsigned-byte 8)))
    ((and (vectorp value) (not (stringp value))) (%usb8 value))
    ((stringp value) (%base64-decode value))
    (t (error 'browser-error
              :message (format nil "not base64/octets: ~s" (type-of value))))))

(defun %js-string (value)
  (with-output-to-string (s)
    (write-char #\' s)
    (loop for ch across (if (stringp value) value (princ-to-string value))
          do (case ch
               (#\\ (write-string "\\\\" s))
               (#\' (write-string "\\'" s))
               (#\Newline (write-string "\\n" s))
               (#\Return (write-string "\\r" s))
               (t (write-char ch s))))
    (write-char #\' s)))

;;; --- CDP backend -----------------------------------------------------------

(defclass cdp-browser-backend (browser-backend)
  ((send-fn :initarg :send-fn :accessor cdp-send-fn :initform nil)
   (recv-fn :initarg :recv-fn :accessor cdp-recv-fn :initform nil)
   (next-id :initarg :next-id :accessor cdp-next-id :initform 0)
   (session-id :initarg :session-id :accessor cdp-session-id :initform nil)
   (ws-url :initarg :ws-url :accessor cdp-ws-url :initform nil)
   (connected-p :initarg :connected-p :accessor cdp-connected-p :initform nil)
   (targets :initarg :targets :accessor cdp-targets :initform nil))
  (:documentation
   "Builds CDP commands and exchanges them via SEND-FN / RECV-FN.
    SEND-FN is called with a command hash-table; RECV-FN returns a message."))

(defun cdp-browser-backend-p (object)
  (typep object 'cdp-browser-backend))

(defun make-cdp-browser-backend (&key send-fn recv-fn compute-backend
                                   sandbox-spec ws-url session-id)
  (make-instance 'cdp-browser-backend
                 :send-fn send-fn
                 :recv-fn recv-fn
                 :compute-backend compute-backend
                 :sandbox-spec sandbox-spec
                 :ws-url ws-url
                 :session-id session-id))

(defun use-cdp-browser-backend (&rest args &key &allow-other-keys)
  (setf *browser-backend* (apply #'make-cdp-browser-backend args)))

(defun %cdp-ensure-io (backend)
  (unless (and (cdp-send-fn backend) (cdp-recv-fn backend))
    (error 'browser-disconnected
           :message "CDP send-fn/recv-fn missing — no websocket")))

(defun cdp-call (backend method &optional params)
  (%cdp-ensure-io backend)
  (let* ((id (incf (cdp-next-id backend)))
         (cmd (encode-cdp-command id method params)))
    (when (cdp-session-id backend)
      (setf (gethash "sessionId" cmd) (cdp-session-id backend)))
    (funcall (cdp-send-fn backend) cmd)
    (let ((msg (decode-cdp-message (funcall (cdp-recv-fn backend)))))
      (let ((err (cdp-message-error msg)))
        (when err
          (error 'browser-error
                 :method method
                 :message (or (%jget err "message")
                              (princ-to-string err)))))
      (cdp-message-result msg))))

(defun %eval-result (result)
  (or (%jget result "result") result))

(defun %value-of (result)
  (let ((inner (%eval-result result)))
    (or (%jget inner "value") inner)))

(defun %js-click (selector)
  (format nil "(function(){var e=document.querySelector(~a); if(!e) throw 'no element'; e.click(); return true;})()"
          (%js-string selector)))

(defun %js-type (selector text)
  (format nil "(function(){var e=document.querySelector(~a); if(!e) throw 'no element'; e.focus(); e.value=(e.value||'')+~a; return true;})()"
          (%js-string selector) (%js-string text)))

(defun %js-scroll (selector dx dy)
  (format nil "(function(){var e=~a; e.scrollBy(~a,~a); return true;})()"
          (if selector
              (format nil "document.querySelector(~a)" (%js-string selector))
              "window")
          (or dx 0) (or dy 0)))

(defmethod navigate ((backend cdp-browser-backend) url)
  (cdp-call backend "Page.navigate" (%ht "url" url))
  url)

(defmethod dom-snapshot ((backend cdp-browser-backend))
  (%value-of
   (cdp-call backend "Runtime.evaluate"
             (%ht "expression" "document.documentElement.outerHTML"
                  "returnByValue" t))))

(defmethod screenshot ((backend cdp-browser-backend) &key)
  (let ((result (cdp-call backend "Page.captureScreenshot" (%ht))))
    (%octets-from-b64 (%jget result "data"))))

(defmethod click ((backend cdp-browser-backend) &key selector x y)
  (cond
    (selector
     (cdp-call backend "Runtime.evaluate"
               (%ht "expression" (%js-click selector) "returnByValue" t)))
    ((and x y)
     (cdp-call backend "Input.dispatchMouseEvent"
               (%ht "type" "mousePressed" "x" x "y" y "button" "left" "clickCount" 1))
     (cdp-call backend "Input.dispatchMouseEvent"
               (%ht "type" "mouseReleased" "x" x "y" y "button" "left" "clickCount" 1)))
    (t (error 'browser-error :message "click needs :selector or :x/:y")))
  t)

(defmethod type-text ((backend cdp-browser-backend) text &key selector x y)
  (when (or selector (and x y))
    (click backend :selector selector :x x :y y))
  (if selector
      (cdp-call backend "Runtime.evaluate"
                (%ht "expression" (%js-type selector text) "returnByValue" t))
      (cdp-call backend "Input.insertText" (%ht "text" text)))
  text)

(defmethod scroll ((backend cdp-browser-backend) &key selector x y dx dy)
  (declare (ignore x y))
  (cdp-call backend "Runtime.evaluate"
            (%ht "expression" (%js-scroll selector (or dx 0) (or dy 0))
                 "returnByValue" t))
  t)

(defmethod eval-js ((backend cdp-browser-backend) expression)
  (%value-of
   (cdp-call backend "Runtime.evaluate"
             (%ht "expression" expression "returnByValue" t))))

(defmethod print-pdf ((backend cdp-browser-backend) &key)
  (let ((result (cdp-call backend "Page.printToPDF" (%ht))))
    (%octets-from-b64 (%jget result "data"))))

(defmethod connect-browser ((backend cdp-browser-backend) &key url ws-url)
  (when ws-url (setf (cdp-ws-url backend) ws-url))
  (when url
    (setf (cdp-ws-url backend) (or ws-url url)))
  (%cdp-ensure-io backend)
  (cdp-call backend "Target.setDiscoverTargets" (%ht "discover" t))
  (setf (cdp-connected-p backend) t)
  backend)

(defmethod close-browser ((backend cdp-browser-backend))
  (when (and (cdp-send-fn backend) (cdp-recv-fn backend))
    (handler-case (cdp-call backend "Browser.close")
      (browser-error () nil)))
  (setf (cdp-connected-p backend) nil)
  t)

(defun %coerce-target (item)
  (cond
    ((browser-target-p item) item)
    ((hash-table-p item)
     (make-browser-target :id (%jget item "targetId")
                          :type (or (%jget item "type") "page")
                          :url (%jget item "url")
                          :title (%jget item "title")))
    ((and (consp item) (keywordp (car item)))
     (apply #'make-browser-target item))
    (t (error 'browser-error :message (format nil "not a target: ~s" item)))))

(defmethod list-targets ((backend cdp-browser-backend))
  (let* ((result (cdp-call backend "Target.getTargets"))
         (raw (or (%jget result "targetInfos")
                  (%jget result "targetInfo")
                  result)))
    (mapcar #'%coerce-target
            (cond
              ((and (vectorp raw) (not (stringp raw))) (coerce raw 'list))
              ((listp raw) raw)
              (t (list raw))))))
