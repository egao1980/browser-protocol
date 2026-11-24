(in-package #:browser-protocol/tests)

;;; Prosecution round 2 for #2: NAVIGATE :load can end on the load event of
;;; the previous document. %CDP-FORGET-EVENTS drops only the buffered events;
;;; a Page.loadEventFired that Chrome sent for the last page and nobody has
;;; read yet is still on the socket. The next NAVIGATE reads it while it
;;; waits for its Page.navigate reply, files it in the buffer, and
;;; WAIT-FOR-CDP-EVENT takes it as the new page's load. So every
;;; navigate after one with :wait-until :domcontentloaded or :commit (and
;;; after any navigation the page started itself) returns before the new
;;; document has loaded. Playwright's page.goto(url) waits for the load of the
;;; document that navigation committed (lifecycle events per loaderId).
;;;
;;; TWO-PAGE-PEER answers like Chrome on one page session and keeps track of
;;; which navigation each event belongs to: document.readyState is
;;; "complete" only once the client has read the load event of the current
;;; navigation. It also sends what a loaderId-based fix needs:
;;; Page.frameStartedLoading, Page.frameNavigated (with the loaderId) and,
;;; after Page.setLifecycleEventsEnabled, Page.lifecycleEvent per loaderId.

(defclass two-page-peer ()
  ((queue :initform '() :accessor peer-queue
          :documentation "(message . url-it-loads-or-nil), oldest first.")
   (enabled :initform '() :accessor peer-enabled)
   (url :initform "about:blank" :accessor peer-url)
   (loaded :initform (make-hash-table :test 'equal) :accessor peer-loaded)
   (loaders :initform 0 :accessor peer-loaders)))

(defun %peer-emit (peer message &optional loads-url)
  (setf (peer-queue peer)
        (append (peer-queue peer) (list (cons message loads-url)))))

(defun %peer-enabled-p (peer method)
  (member method (peer-enabled peer) :test #'equal))

(defun two-page-peer-handle (peer cmd)
  (let* ((id (gethash "id" cmd))
         (method (gethash "method" cmd))
         (params (or (gethash "params" cmd) (%h)))
         (reply (lambda (result) (%h "id" id "result" result))))
    (cond
      ((member method '("Page.enable" "Page.setLifecycleEventsEnabled"
                        "Runtime.enable" "Network.enable")
               :test #'equal)
       (pushnew method (peer-enabled peer) :test #'equal)
       (%peer-emit peer (funcall reply (%h))))
      ((equal method "Runtime.evaluate")
       (let ((expression (gethash "expression" params)))
         (%peer-emit peer
                     (funcall reply
                              (%h "result"
                                  (%h "type" "string"
                                      "value"
                                      (cond
                                        ((equal expression "document.readyState")
                                         (if (gethash (peer-url peer) (peer-loaded peer))
                                             "complete"
                                             "interactive"))
                                        ((equal expression "location.href") (peer-url peer))
                                        (t "?"))))))))
      ((equal method "Page.navigate")
       (let* ((url (gethash "url" params))
              (loader (format nil "L~d" (incf (peer-loaders peer))))
              (page (%peer-enabled-p peer "Page.enable"))
              (life (%peer-enabled-p peer "Page.setLifecycleEventsEnabled")))
         (setf (peer-url peer) url)
         (when page
           (%peer-emit peer (%event "Page.frameStartedLoading" "frameId" "F1")))
         (%peer-emit peer (funcall reply (%h "frameId" "F1" "loaderId" loader
                                             "isDownload" nil)))
         (when page
           (%peer-emit peer (%event "Page.frameNavigated"
                                    "frame" (%h "id" "F1" "loaderId" loader "url" url)))
           (%peer-emit peer (%event "Page.domContentEventFired" "timestamp" 1)))
         (when life
           (%peer-emit peer (%event "Page.lifecycleEvent" "frameId" "F1" "loaderId" loader
                                    "name" "DOMContentLoaded" "timestamp" 1))
           (%peer-emit peer (%event "Page.lifecycleEvent" "frameId" "F1" "loaderId" loader
                                    "name" "load" "timestamp" 2)
                       url))
         (when page
           (%peer-emit peer (%event "Page.loadEventFired" "timestamp" 2) url)
           (%peer-emit peer (%event "Page.frameStoppedLoading" "frameId" "F1")))))
      (t (%peer-emit peer (funcall reply (%h)))))))

(defun two-page-peer-backend (&optional (peer (make-instance 'two-page-peer)))
  "A CDP backend wired to PEER. RECV-FN signals BROWSER-TIMEOUT when nothing
   is pending, as a real socket with nothing to read would time out."
  (values
   (browser-protocol:make-cdp-browser-backend
    :timeout 2
    :send-fn (lambda (cmd)
               (two-page-peer-handle peer (browser-protocol:decode-cdp-message cmd)))
    :recv-fn (lambda ()
               (let ((entry (pop (peer-queue peer))))
                 (unless entry
                   (error 'browser-protocol:browser-timeout
                          :message "two-page peer: no message pending"))
                 (when (cdr entry)
                   (setf (gethash (cdr entry) (peer-loaded peer)) t))
                 (car entry))))
   peer))

(defun %navigate-then-ready-state (first-wait)
  "NAVIGATE to page zero (:load, so Page events are on, as in any session
   that navigated before), to page one with :wait-until FIRST-WAIT, then to
   page two with the default (:load). → document.readyState right after,
   or the error."
  (let ((b (two-page-peer-backend)))
    (handler-case
        (progn
          (browser-protocol:navigate b "https://ex.test/zero")
          (browser-protocol:navigate b "https://ex.test/one" :wait-until first-wait)
          (browser-protocol:navigate b "https://ex.test/two")
          (browser-protocol:eval-js b "document.readyState"))
      (error (c) (list :error (type-of c) (princ-to-string c))))))

(deftest navigate-after-domcontentloaded-waits-for-the-new-load
  ;; Playwright: page.goto(one, wait_until="domcontentloaded"); page.goto(two)
  ;; returns once two has loaded.
  (let ((got (%navigate-then-ready-state :domcontentloaded)))
    (ok (equal "complete" got)
        (format nil "document.readyState after navigate(two) → ~s (want \"complete\": ~
                     navigate took page one's Page.loadEventFired)" got))))

(deftest navigate-after-commit-waits-for-the-new-load
  (let ((got (%navigate-then-ready-state :commit)))
    (ok (equal "complete" got)
        (format nil "document.readyState after navigate(two) → ~s (want \"complete\")" got))))

(deftest navigate-after-load-still-waits-for-load
  ;; Control: when page one's load was read, navigate(two) waits for two's.
  (let ((got (%navigate-then-ready-state :load)))
    (ok (equal "complete" got)
        (format nil "document.readyState after navigate(two) → ~s" got))))

(deftest navigate-waits-for-its-own-load-on-real-chrome
  ;; Fetch.enable pauses the image of page two and nothing continues it, so
  ;; page two never loads: NAVIGATE :load must time out (or, at the least,
  ;; not return before document.readyState is "complete"). Page one is
  ;; opened with :wait-until :domcontentloaded, so its load event is still
  ;; unread on the socket.
  (let ((chrome (%chrome-executable)))
    (if (null chrome)
        (skip "no Chrome/Chromium (set CHROME_PATH)")
        (let ((b (browser-protocol:launch-browser :timeout 10))
              (two "data:text/html,<title>two</title><img src='http://hang.invalid/x.png'>"))
          (unwind-protect
               (progn
                 (browser-protocol:cdp-call b "Fetch.enable"
                                            (%h "patterns" (vector (%h "urlPattern" "*hang.invalid*"))))
                 (browser-protocol:navigate b "data:text/html,<title>one</title>"
                                            :wait-until :domcontentloaded)
                 (sleep 0.5)
                 (let* ((start (get-internal-real-time))
                        (got (handler-case
                                 (progn (browser-protocol:navigate b two :timeout 3) :returned)
                               (browser-protocol:browser-timeout () :timeout)))
                        (seconds (/ (- (get-internal-real-time) start)
                                    internal-time-units-per-second 1.0))
                        (state (browser-protocol:eval-js b "document.readyState")))
                   (ok (or (eq got :timeout) (equal "complete" state))
                       (format nil "navigate(two) → ~s after ~,2fs with document.readyState ~s ~
                                    (want :timeout: two never loads)"
                               got seconds state))))
            (browser-protocol:close-browser b))))))
