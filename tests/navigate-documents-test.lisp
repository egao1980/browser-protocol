(in-package #:browser-protocol/tests)

;;; Defender round 3 for #2: NAVIGATE follows the main frame's documents in
;;; the order their events are read (%CDP-TRACK-DOCUMENT). It waits for the
;;; document its own navigation committed (the loaderId of the Page.navigate
;;; reply), or one that replaced it, and never counts an earlier document's
;;; events.

(defun %frame-navigated (frame-id loader-id &optional parent-id)
  (%event "Page.frameNavigated"
          "frame" (%h "id" frame-id "loaderId" loader-id "parentId" parent-id
                      "url" "https://ex.test/")))

(defun %queue-backend (messages &rest keys)
  "A CDP backend whose RECV-FN pops MESSAGES (functions get the last command
   sent) and then signals BROWSER-TIMEOUT. → (values backend left-fn), where
   LEFT-FN → how many messages were not read."
  (let ((queue (copy-list messages))
        (sent nil))
    (values
     (apply #'browser-protocol:make-cdp-browser-backend
            :send-fn (lambda (cmd) (setf sent cmd))
            :recv-fn (lambda ()
                       (unless queue
                         (error 'browser-protocol:browser-timeout
                                :message "queue backend: no message pending"))
                       (let ((m (pop queue)))
                         (if (functionp m) (funcall m sent) m)))
            keys)
     (lambda () (length queue)))))

(deftest navigate-waits-for-the-document-that-replaced-its-own
  ;; The page sets location from script before its load: Playwright's goto
  ;; returns on the load of the document that replaced it.
  (let ((b (%queue-backend
            (list (%reply (%h))         ; Page.enable
                  (%reply (%h "frameId" "F1" "loaderId" "L1"))
                  (%frame-navigated "F1" "L1")
                  (%event "Page.domContentEventFired" "timestamp" 1)
                  (%frame-navigated "F1" "L2")
                  (%event "Page.domContentEventFired" "timestamp" 2)
                  (%event "Page.loadEventFired" "timestamp" 3))
            :timeout 0.5)))
    (let ((got (handler-case (browser-protocol:navigate b "https://ex.test/a")
                 (error (c) (list :error (type-of c) (princ-to-string c))))))
      (ok (equal "https://ex.test/a" got) (format nil "navigate → ~s" got)))))

(deftest subframe-events-are-not-the-main-document
  ;; An iframe's frameNavigated (parentId) and its lifecycle load come before
  ;; the main document's load: NAVIGATE ends only on the main one.
  (multiple-value-bind (b left)
      (%queue-backend
       (list (%reply (%h))
             (%reply (%h "frameId" "F1" "loaderId" "L1"))
             (%frame-navigated "F1" "L1")
             (%frame-navigated "F2" "S1" "F1")
             (%event "Page.lifecycleEvent" "frameId" "F2" "loaderId" "S1" "name" "load")
             (%event "Network.dataReceived" "dataLength" 1)
             (%event "Page.lifecycleEvent" "frameId" "F1" "loaderId" "L1" "name" "load")
             (%event "Page.frameStoppedLoading" "frameId" "F1"))
       :timeout 0.5)
    (browser-protocol:navigate b "https://ex.test/frames")
    (ok (= 1 (funcall left))
        (format nil "~d message(s) left unread (want 1: navigate read through the main load)"
                (funcall left)))))

(deftest stale-document-events-before-the-commit-do-not-count
  ;; Everything an earlier navigation left on the socket, its own commit
  ;; included, is read before this navigation's commit and does not count.
  (multiple-value-bind (b left)
      (%queue-backend
       (list (%reply (%h))
             (%frame-navigated "F1" "L0")
             (%event "Page.domContentEventFired" "timestamp" 1)
             (%event "Page.loadEventFired" "timestamp" 2)
             (%reply (%h "frameId" "F1" "loaderId" "L1"))
             (%event "Page.loadEventFired" "timestamp" 3) ; L0's, read late
             (%frame-navigated "F1" "L1")
             (%event "Page.domContentEventFired" "timestamp" 4)
             (%event "Page.loadEventFired" "timestamp" 5))
       :timeout 0.5)
    (let ((got (handler-case (browser-protocol:navigate b "https://ex.test/b")
                 (error (c) (list :error (type-of c) (princ-to-string c))))))
      (ok (equal "https://ex.test/b" got) (format nil "navigate → ~s" got))
      (ok (zerop (funcall left))
          (format nil "~d message(s) left unread (want 0: the wait ends on L1's load)"
                  (funcall left))))))

(deftest navigate-leaves-no-load-event-for-a-later-wait
  ;; As before: once NAVIGATE returns, WAIT-FOR-CDP-EVENT waits for the next
  ;; load event, not the one NAVIGATE waited for.
  (let ((b (two-page-peer-backend)))
    (browser-protocol:navigate b "https://ex.test/zero")
    (ok (signals (browser-protocol:wait-for-cdp-event b "Page.loadEventFired" :timeout 0.2)
                 'browser-protocol:browser-timeout))))

(deftest navigate-timeout-names-the-lifecycle-event
  (let ((b (%queue-backend
            (list (%reply (%h))
                  (%reply (%h "frameId" "F1" "loaderId" "L1"))
                  (%frame-navigated "F1" "L1")
                  (%event "Page.domContentEventFired" "timestamp" 1))
            :timeout 0.3)))
    (handler-case (progn (browser-protocol:navigate b "https://ex.test/slow")
                         (ok nil "no timeout"))
      (browser-protocol:browser-timeout (c)
        (ok (search "fired no load" (princ-to-string c)) (princ-to-string c))
        (ok (equal "https://ex.test/slow" (browser-protocol:browser-error-url c)))))))

(deftest navigate-after-commit-loads-the-new-page-on-real-chrome
  ;; Page one opened with :commit, so its whole load is still unread when
  ;; NAVIGATE goes to page three, which loads: NAVIGATE returns once three
  ;; has loaded, and the title is three's.
  (let ((chrome (%chrome-executable)))
    (if (null chrome)
        (skip "no Chrome/Chromium (set CHROME_PATH)")
        (let ((b (browser-protocol:launch-browser :timeout 10)))
          (unwind-protect
              (progn
                (browser-protocol:navigate b "data:text/html,<title>one</title>" :wait-until :commit)
                (browser-protocol:navigate b "data:text/html,<title>three</title><p>3</p>")
                (let ((state (browser-protocol:eval-js b "document.readyState"))
                      (title (browser-protocol:eval-js b "document.title")))
                  (ok (and (equal "complete" state) (equal "three" title))
                      (format nil "after navigate(three): readyState ~s, title ~s" state title)))
                ;; Ten in a row, :commit and :load in turn: each :load
                ;; navigation returns on its own document, not the last one's.
                (let ((seen (loop for n below 10
                                  for wait = (if (evenp n) :commit :load)
                                  do (browser-protocol:navigate
                                      b (format nil "data:text/html,<title>t~d</title>" n)
                                      :wait-until wait)
                                  when (eq wait :load)
                                    collect (list (browser-protocol:eval-js b "document.title")
                                                  (browser-protocol:eval-js b "document.readyState")))))
                  (ok (equal '(("t1" "complete") ("t3" "complete") ("t5" "complete")
                               ("t7" "complete") ("t9" "complete"))
                             seen)
                      (format nil "after each :load navigate: ~s" seen))))
            (browser-protocol:close-browser b))))))
