(in-package #:browser-protocol/tests)

;;; browser-protocol#2, first half: Playwright's chromium.launch() / new_page().
;;; LAUNCH-BROWSER starts Chrome or Chromium headless (its own temporary
;;; profile, --remote-debugging-port), finds a page target, opens the
;;; websocket and returns a connected CDP backend. CLOSE-BROWSER stops the
;;; process. WITH-BROWSER does both around a body.
;;;
;;; The real-browser test is skipped unless Chrome or Chromium is installed:
;;; macOS /Applications/Google Chrome.app, or google-chrome / chromium /
;;; chromium-browser on PATH, or CHROME_PATH. Linux CI:
;;;   apt-get install -y chromium   (or: docker run ... zenika/alpine-chrome)

(defun %chrome-executable ()
  "The browser LAUNCH-BROWSER with no arguments is expected to find too:
   CHROME_PATH first, then the usual install locations. Defender: also ask
   FIND-BROWSER-EXECUTABLE, which knows the Windows install paths."
  (let ((env (uiop:getenv "CHROME_PATH")))
    (or (and env (plusp (length env)) (probe-file env) env)
        (find-if #'probe-file
                 '("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                   "/Applications/Chromium.app/Contents/MacOS/Chromium"))
        (loop for name in '("google-chrome" "google-chrome-stable" "chromium"
                            "chromium-browser")
              for path = (ignore-errors
                           (string-trim '(#\Newline #\Space)
                                        (uiop:run-program (list "sh" "-c" (format nil "command -v ~a" name))
                                                          :output :string)))
              when (and path (plusp (length path)))
                return path)
        (let ((find (%browser-fn "FIND-BROWSER-EXECUTABLE")))
          (and find (funcall find))))))

(defun %browser-fn (name)
  (let ((s (find-symbol name :browser-protocol)))
    (and s (fboundp s) s)))

(deftest launch-browser-api-exists
  (ok (%browser-fn "LAUNCH-BROWSER") "browser-protocol:launch-browser is a function")
  (ok (let ((s (find-symbol "WITH-BROWSER" :browser-protocol)))
        (and s (macro-function s)))
      "browser-protocol:with-browser is a macro"))

(deftest launch-browser-drives-real-chrome
  (let ((chrome (%chrome-executable))
        (launch (%browser-fn "LAUNCH-BROWSER")))
    (cond
      ((null chrome)
       (skip "no Chrome/Chromium (set CHROME_PATH)"))
      ((null launch)
       (ok nil "browser-protocol:launch-browser is not defined"))
      (t
       (let ((b (funcall launch)))
         (unwind-protect
              (progn
                (browser-protocol:navigate b "data:text/html,<title>launched</title><p id=p>hi</p>")
                (ok (equal "launched" (browser-protocol:eval-js b "document.title")))
                (ok (equal "complete" (browser-protocol:eval-js b "document.readyState")))
                (ok (equal 2 (browser-protocol:eval-js b "1+1"))))
           (browser-protocol:close-browser b)))))))

;;; Defender edge cases (real browser; skipped without one).

(defmacro with-real-browser ((var &rest options) &body body)
  `(if (null (%chrome-executable))
       (skip "no Chrome/Chromium (set CHROME_PATH)")
       (browser-protocol:with-browser (,var ,@options)
         ,@body)))

(deftest with-browser-binds-and-cleans-up
  (let ((seen nil) (process nil) (profile nil))
    (with-real-browser (b)
      (setf seen (eq b browser-protocol:*browser-backend*)
            process (browser-protocol:chrome-browser-process b)
            profile (browser-protocol:chrome-browser-profile b))
      ;; *BROWSER-BACKEND* serves the NIL-backend methods.
      (ok (equal 7 (browser-protocol:eval-js nil "3+4"))))
    (when process
      (ok seen "*browser-backend* is the launched backend inside WITH-BROWSER")
      (ok (not (stack-process:alive-p process)) "browser process stopped")
      (ok (not (probe-file profile)) "temporary profile removed"))))

(deftest real-browser-screenshot-dom-and-errors
  (with-real-browser (b)
    (browser-protocol:navigate b "data:text/html,<title>shot</title><p id=p>hello</p>")
    (let ((png (browser-protocol:screenshot b)))
      (ok (equalp #(137 80 78 71) (subseq png 0 4)) "screenshot is a PNG"))
    (ok (search "<p id=\"p\">hello</p>" (browser-protocol:dom-snapshot b)))
    (let ((pdf (browser-protocol:print-pdf b)))
      (ok (equalp (map 'vector #'char-code "%PDF") (subseq pdf 0 4)) "print-pdf is a PDF"))
    (handler-case (progn (browser-protocol:navigate b "http://no-such-host.invalid/")
                         (ok nil "no error for an unresolvable host"))
      (browser-protocol:browser-error (c)
        (ok (search "ERR_NAME_NOT_RESOLVED" (princ-to-string c)) (princ-to-string c))))
    ;; Same-document navigation: no load event, NAVIGATE still returns.
    (browser-protocol:navigate b "data:text/html,<title>frag</title><p id=x>x</p>")
    (ok (equal "about:blank#x"
               (progn (browser-protocol:navigate b "about:blank")
                      (browser-protocol:navigate b "about:blank#x")
                      (browser-protocol:eval-js b "location.href"))))))

(deftest connect-cdp-detaches-and-leaves-the-browser-running
  (with-real-browser (b)
    (let ((other (browser-protocol:connect-cdp (browser-protocol:cdp-ws-url b))))
      (ok (equal 2 (browser-protocol:eval-js other "1+1")))
      (browser-protocol:close-browser other)
      (ok (stack-process:alive-p (browser-protocol:chrome-browser-process b)))
      (ok (equal 4 (browser-protocol:eval-js b "2+2")) "the launched backend still works"))))

(deftest launch-browser-missing-executable
  ;; No browser needed: a missing program is a BROWSER-ERROR, not a hang.
  (ok (signals (browser-protocol:launch-browser :executable "/nonexistent/chrome" :timeout 5)
               'browser-protocol:browser-error)))
