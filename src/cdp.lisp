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

;;; --- octets: screenshot / PDF data is base64 (encoding-protocol) -------------

(defun %usb8 (seq)
  (coerce seq '(simple-array (unsigned-byte 8) (*))))

(defun %octets-from-b64 (value)
  (cond
   ((null value) (make-array 0 :element-type '(unsigned-byte 8)))
   ((and (vectorp value) (not (stringp value))) (%usb8 value))
   ((stringp value)
    (handler-case (%usb8 (encoding-protocol:decode value :encoding :base64))
      (encoding-protocol:encoding-error (c)
        (error 'browser-error
               :message (format nil "bad base64 from the browser: ~a" c)
               :cause c))))
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
   (targets :initarg :targets :accessor cdp-targets :initform nil)
   (timeout :initarg :timeout :accessor cdp-timeout :initform 30
            :documentation "Seconds a command (or NAVIGATE's wait) may take.")
   (events :initform '() :accessor %cdp-events
           :documentation "Events read while waiting for replies, oldest first.")
   (handlers :initform (make-hash-table :test 'equal) :accessor %cdp-handlers
             :documentation "Event method → list of ON-CDP-EVENT handlers.")
   (page-enabled-p :initform nil :accessor %cdp-page-enabled-p))
  (:documentation
   "Builds CDP commands and exchanges them via SEND-FN / RECV-FN.
    SEND-FN is called with a command hash-table; RECV-FN returns the next
    message (hash-table, plist or JSON text) and should give up after
    *CDP-RECEIVE-TIMEOUT* seconds with BROWSER-TIMEOUT. Replies are matched
    to commands by id; events in between go to ON-CDP-EVENT handlers and a
    bounded buffer that WAIT-FOR-CDP-EVENT reads."))

(defun cdp-browser-backend-p (object)
  (typep object 'cdp-browser-backend))

(defun make-cdp-browser-backend (&key send-fn recv-fn compute-backend
                                      sandbox-spec ws-url session-id (timeout 30))
  (make-instance 'cdp-browser-backend
                 :send-fn send-fn
                 :recv-fn recv-fn
                 :compute-backend compute-backend
                 :sandbox-spec sandbox-spec
                 :ws-url ws-url
                 :session-id session-id
                 :timeout timeout))

(defun use-cdp-browser-backend (&rest args &key &allow-other-keys)
  (setf *browser-backend* (apply #'make-cdp-browser-backend args)))

(defun %cdp-ensure-io (backend)
  (unless (and (cdp-send-fn backend) (cdp-recv-fn backend))
    (error 'browser-disconnected
           :message "CDP send-fn/recv-fn missing — no websocket")))

(defvar *cdp-receive-timeout* nil
  "Seconds left for the RECV-FN call in progress, or NIL for no limit. Bound
   around every RECV-FN call: a transport that can wait with a timeout
   signals BROWSER-TIMEOUT once it passes.")

(defparameter *cdp-event-buffer-limit* 1000
  "Events kept per backend for WAIT-FOR-CDP-EVENT; older ones are dropped.")

(defun %deadline (seconds)
  (and seconds
       (+ (get-internal-real-time)
          (round (* seconds internal-time-units-per-second)))))

(defun %seconds-left (deadline)
  (and deadline
       (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))

(defun %cdp-receive (backend deadline limit what)
  "Next message from RECV-FN as a hash-table. BROWSER-TIMEOUT once DEADLINE
   (LIMIT seconds after the start) passes; BROWSER-DISCONNECTED when RECV-FN
   returns NIL."
  (let ((left (%seconds-left deadline)))
    (when (and left (<= left 0))
      (error 'browser-timeout
             :method what :limit limit
             :message (format nil "nothing for ~a within ~as" what limit)))
    (let ((raw (let ((*cdp-receive-timeout* left))
                 (funcall (cdp-recv-fn backend)))))
      (when (null raw)
        (error 'browser-disconnected
               :method what :message "the CDP transport is closed"))
      (decode-cdp-message raw))))

(defun %cdp-own-session-p (backend message)
  "MESSAGE has no sessionId (browser target, or a page connection) or
   BACKEND's."
  (let ((session (%jget message "sessionId")))
    (or (null session) (equal session (cdp-session-id backend)))))

(defun %cdp-dispatch (backend message)
  (let ((params (or (cdp-message-params message) (%ht))))
    (dolist (handler (reverse (gethash (cdp-message-method message)
                                       (%cdp-handlers backend))))
      (funcall handler params))))

(defun %cdp-note-event (backend message)
  "Hand MESSAGE (an event) to its handlers, then keep it in the buffer."
  (%cdp-dispatch backend message)
  (let* ((events (nconc (%cdp-events backend) (list message)))
         (excess (- (length events) *cdp-event-buffer-limit*)))
    (setf (%cdp-events backend)
          (if (plusp excess) (nthcdr excess events) events))))

(defun %cdp-reply-result (message method)
  (let ((err (cdp-message-error message)))
    (when err
      (error 'browser-error
             :method method
             :message (format nil "~a~@[ (~a)~]"
                              (or (%jget err "message") (princ-to-string err))
                              (%jget err "data")))))
  (cdp-message-result message))

(defun %cdp-command (backend method params session-id timeout)
  "Send one command (on SESSION-ID, NIL = the connection's own target) and
   read until the reply with its id. Replies to other ids (commands given
   up on) are dropped; events are noted."
  (%cdp-ensure-io backend)
  (let* ((id (incf (cdp-next-id backend)))
         (cmd (encode-cdp-command id method params))
         (limit (or timeout (cdp-timeout backend)))
         (deadline (%deadline limit)))
    (when session-id
      (setf (gethash "sessionId" cmd) session-id))
    (funcall (cdp-send-fn backend) cmd)
    (loop
      (let ((msg (%cdp-receive backend deadline limit method)))
        (cond
         ((eql id (cdp-message-id msg))
          (return (%cdp-reply-result msg method)))
         ((cdp-message-method msg)
          (%cdp-note-event backend msg)))))))

(defun %cdp-browser-call (backend method &optional params timeout)
  "CDP-CALL on the browser target: no sessionId."
  (%cdp-command backend method params nil timeout))

(defun on-cdp-event (backend method handler)
  "Call HANDLER with the params (hash-table) of every METHOD event BACKEND
   reads. Events are read while a command waits for its reply or
   WAIT-FOR-CDP-EVENT waits, on that thread. → HANDLER."
  (check-type method string)
  (push handler (gethash method (%cdp-handlers backend)))
  handler)

(defun off-cdp-event (backend method &optional handler)
  "Remove HANDLER (every handler when NIL) for METHOD events."
  (if handler
      (setf (gethash method (%cdp-handlers backend))
            (remove handler (gethash method (%cdp-handlers backend))))
      (remhash method (%cdp-handlers backend)))
  nil)

(defun %event-matches-p (backend message method test)
  (and (equal method (cdp-message-method message))
       (%cdp-own-session-p backend message)
       (or (null test)
           (funcall test (or (cdp-message-params message) (%ht))))))

(defun %cdp-forget-events (backend method)
  "Drop buffered METHOD events of BACKEND's session (stale for a new wait)."
  (setf (%cdp-events backend)
        (remove-if (lambda (m) (%event-matches-p backend m method nil))
                   (%cdp-events backend))))

(defun wait-for-cdp-event (backend method &key test timeout)
  "→ the params of the first METHOD event of BACKEND's session for which
   TEST (if given) is true of the params. Takes it from the event buffer,
   else reads the transport. BROWSER-TIMEOUT after TIMEOUT seconds (default
   (CDP-TIMEOUT BACKEND))."
  (check-type method string)
  (let ((buffered (find-if (lambda (m) (%event-matches-p backend m method test))
                           (%cdp-events backend))))
    (when buffered
      (setf (%cdp-events backend) (remove buffered (%cdp-events backend) :count 1))
      (return-from wait-for-cdp-event
        (or (cdp-message-params buffered) (%ht)))))
  (%cdp-ensure-io backend)
  (let* ((limit (or timeout (cdp-timeout backend)))
         (deadline (%deadline limit)))
    (loop
      (let ((msg (%cdp-receive backend deadline limit method)))
        (when (cdp-message-method msg)
          (cond
           ((%event-matches-p backend msg method test)
            (%cdp-dispatch backend msg)
            (return (or (cdp-message-params msg) (%ht))))
           (t (%cdp-note-event backend msg))))))))

(defun cdp-call (backend method &optional params)
  "Send METHOD with PARAMS (hash-table, plist or alist) on BACKEND's session.
   → the reply's result (hash-table). Events that arrive first go to the
   ON-CDP-EVENT handlers and the event buffer. A CDP error reply signals
   BROWSER-ERROR; no reply within (CDP-TIMEOUT BACKEND) seconds signals
   BROWSER-TIMEOUT."
  (%cdp-command backend method params (cdp-session-id backend) nil))

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

(defparameter +navigate-wait-events+
  '((:load . "Page.loadEventFired")
    (:domcontentloaded . "Page.domContentEventFired"))
  "NAVIGATE :wait-until → the Page event that ends the wait.")

(defun %ensure-page-events (backend)
  "Page.enable once per backend: without it Chrome sends no Page events."
  (unless (%cdp-page-enabled-p backend)
    (cdp-call backend "Page.enable")
    (setf (%cdp-page-enabled-p backend) t)))

(defmethod navigate ((backend cdp-browser-backend) url &key (wait-until :load) timeout)
  (let* ((event (cond
                 ((member wait-until '(nil :commit)) nil)
                 ((cdr (assoc wait-until +navigate-wait-events+)))
                 (t (error 'browser-error
                           :url url :method "Page.navigate"
                           :message (format nil "wait-until ~s: want :load, :domcontentloaded or :commit"
                                            wait-until)))))
         (limit (or timeout (cdp-timeout backend)))
         (deadline (%deadline limit)))
    (when event
      (%ensure-page-events backend)
      (%cdp-forget-events backend event))
    (let* ((result (%cdp-command backend "Page.navigate" (%ht "url" url)
                                 (cdp-session-id backend) limit))
           (error-text (%jget result "errorText")))
      (when (and (stringp error-text) (plusp (length error-text)))
        (error 'browser-error
               :url url :method "Page.navigate"
               :message (format nil "navigation to ~a failed: ~a" url error-text)))
      ;; No loaderId: a same-document navigation (#fragment) fires no load event.
      (when (and event (%jget result "loaderId") (not (%jget result "isDownload")))
        (handler-case
            (wait-for-cdp-event backend event
                                :timeout (and deadline (max 0 (%seconds-left deadline))))
          (browser-timeout (c)
            (error 'browser-timeout
                   :url url :method "Page.navigate" :limit limit :cause c
                   :message (format nil "~a: no ~a within ~as" url event limit)))))
      url)))

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
  ;; A browser-target command: Target.* events then reach every session.
  (%cdp-browser-call backend "Target.setDiscoverTargets" (%ht "discover" t))
  (setf (cdp-connected-p backend) t)
  backend)

(defmethod close-browser ((backend cdp-browser-backend))
  (when (and (cdp-send-fn backend) (cdp-recv-fn backend))
    ;; Chrome may close the socket before it replies.
    (handler-case (%cdp-browser-call backend "Browser.close" nil 5)
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
  (let* ((result (%cdp-browser-call backend "Target.getTargets"))
         (raw (or (%jget result "targetInfos")
                  (%jget result "targetInfo")
                  result)))
    (mapcar #'%coerce-target
            (cond
              ((and (vectorp raw) (not (stringp raw))) (coerce raw 'list))
              ((listp raw) raw)
              (t (list raw))))))
