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
   CHROME_PATH first, then the usual install locations."
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
                return path))))

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
