(in-package #:browser-protocol/tests)

;;; browser-protocol#2. FAKE-CHROME answers like Chrome on one page session
;;; (traced from Chrome 142 headless, 2026-11-23):
;;;  - Target.setDiscoverTargets: one Target.targetCreated event per existing
;;;    target, then the reply.
;;;  - Page.navigate: the reply as soon as the navigation commits. Page events
;;;    follow only when Page.enable was sent; lifecycle events only after
;;;    Page.setLifecycleEventsEnabled.
;;;  - document.readyState is "complete" once the load event has been sent.
;;; Messages are hash-tables, so the JSON decoder (#1) is not involved.

(defun %h (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k h) v))
    h))

(defun %event (method &rest params)
  (%h "method" method "params" (apply #'%h params)))

(defclass fake-chrome ()
  ((queue :initform '() :accessor fake-queue)
   (enabled :initform '() :accessor fake-enabled)
   (ready-state :initform "complete" :accessor fake-ready-state)
   (title :initform "" :accessor fake-title)
   (loaders :initform 0 :accessor fake-loaders)))

(defun %emit (peer &rest messages)
  (setf (fake-queue peer) (append (fake-queue peer) messages)))

(defun %evaluate (peer expression)
  (cond
    ((equal expression "document.readyState") (fake-ready-state peer))
    ((equal expression "document.title") (fake-title peer))
    (t (let ((sum (ignore-errors
                   (let ((plus (position #\+ expression)))
                     (+ (parse-integer expression :end plus)
                        (parse-integer expression :start (1+ plus)))))))
         (or sum :unsupported)))))

(defun %title-of (url)
  (let ((start (search "<title>" url))
        (end (search "</title>" url)))
    (if (and start end) (subseq url (+ start 7) end) "")))

(defun fake-chrome-handle (peer cmd)
  (let* ((id (gethash "id" cmd))
         (method (gethash "method" cmd))
         (params (or (gethash "params" cmd) (%h)))
         (reply (lambda (result) (%h "id" id "result" result))))
    (cond
      ((equal method "Target.setDiscoverTargets")
       (dolist (target '("PAGE1" "SW1" "SW2"))
         (%emit peer (%event "Target.targetCreated"
                             "targetInfo" (%h "targetId" target "type" "page"
                                              "url" "about:blank"))))
       (%emit peer (funcall reply (%h))))
      ((member method '("Page.enable" "Page.setLifecycleEventsEnabled")
               :test #'equal)
       (pushnew method (fake-enabled peer) :test #'equal)
       (%emit peer (funcall reply (%h))))
      ((equal method "Runtime.evaluate")
       (%emit peer (funcall reply
                            (%h "result" (%h "type" "string"
                                             "value" (%evaluate peer (gethash "expression" params)))))))
      ((equal method "Page.navigate")
       (let* ((url (gethash "url" params))
              (loader (format nil "L~d" (incf (fake-loaders peer))))
              (page (member "Page.enable" (fake-enabled peer) :test #'equal))
              (life (member "Page.setLifecycleEventsEnabled" (fake-enabled peer)
                            :test #'equal)))
         (setf (fake-ready-state peer) "interactive"
               (fake-title peer) (%title-of url))
         (%emit peer (funcall reply (%h "frameId" "F1" "loaderId" loader "isDownload" nil)))
         (when page
           (%emit peer (%event "Page.domContentEventFired" "timestamp" 1)))
         (when life
           (%emit peer (%event "Page.lifecycleEvent" "frameId" "F1" "loaderId" loader
                               "name" "load" "timestamp" 2)))
         (when page
           (%emit peer (%event "Page.loadEventFired" "timestamp" 2)
                  (%event "Page.frameStoppedLoading" "frameId" "F1")))))
      (t (%emit peer (funcall reply (%h)))))))

(defun %load-event-p (message)
  (let ((method (gethash "method" message)))
    (or (equal method "Page.loadEventFired")
        (and (equal method "Page.lifecycleEvent")
             (equal "load" (gethash "name" (gethash "params" message)))))))

(defun fake-chrome-backend (&optional (peer (make-instance 'fake-chrome)))
  "A CDP backend wired to PEER. RECV-FN signals BROWSER-TIMEOUT when nothing
   is pending (a real socket would block forever)."
  (values
   (browser-protocol:make-cdp-browser-backend
    :send-fn (lambda (cmd)
               (fake-chrome-handle peer (browser-protocol:decode-cdp-message cmd)))
    :recv-fn (lambda ()
               (let ((m (pop (fake-queue peer))))
                 (unless m
                   (error 'browser-protocol:browser-timeout
                          :message "fake Chrome: no message pending"))
                 (when (%load-event-p m)
                   (setf (fake-ready-state peer) "complete"))
                 m)))
   peer))

(deftest cdp-call-skips-events-before-its-reply
  ;; Real Chrome, browser-protocol 0.1.0: CONNECT-BROWSER takes the first
  ;; Target.targetCreated event as its reply, then each EVAL-JS reads the
  ;; next event and returns NIL.
  (let ((b (fake-chrome-backend)))
    (browser-protocol:connect-browser b)
    (ok (eql 2 (browser-protocol:eval-js b "1+1"))
        "eval-js 1+1 after connect-browser → 2")
    (ok (eql 4 (browser-protocol:eval-js b "2+2"))
        "eval-js 2+2 → 4")))

(deftest navigate-waits-for-load
  ;; Playwright's page.goto waits for "load" by default. Today NAVIGATE returns
  ;; on the Page.navigate reply, while document.readyState is "interactive".
  (let ((b (fake-chrome-backend)))
    (browser-protocol:navigate b "data:text/html,<title>slow</title>")
    (ok (equal "complete" (browser-protocol:eval-js b "document.readyState"))
        "document.readyState right after navigate")
    (ok (equal "slow" (browser-protocol:eval-js b "document.title"))
        "document.title is the new page's")))
