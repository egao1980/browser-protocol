(in-package #:browser-protocol/tests)

;;; Prosecution round 1 for #1: Chrome's `false` decodes now (json-protocol:
;;; false → NIL), but EVAL-JS still cannot return it. %VALUE-OF is
;;; (or (%jget inner "value") inner): a false value is NIL, so it falls
;;; through to the whole RemoteObject, a hash-table, which is true in Lisp.
;;; (when (eval-js b "document.querySelector('#missing') !== null") ...)
;;; always runs. Playwright's page.evaluate("1 === 2") is False.

(defparameter *chrome-evaluate-false-reply*
  ;; Chrome's Runtime.evaluate reply for "1 === 2" with returnByValue.
  "{\"id\":1,\"result\":{\"result\":{\"type\":\"boolean\",\"value\":false}}}")

(defun %shown (value)
  "VALUE, with a hash-table shown as its alist."
  (if (hash-table-p value)
      (let ((alist '()))
        (maphash (lambda (k v) (push (cons k v) alist)) value)
        alist)
      value))

(deftest eval-js-false-is-nil
  (let* ((b (%scripted-backend (list *chrome-evaluate-false-reply*)))
         (got (handler-case (browser-protocol:eval-js b "1 === 2")
                (error (c) (list :error (type-of c) (princ-to-string c))))))
    (ok (null got)
        (format nil "eval-js \"1 === 2\" → ~s (want NIL)"
                (%shown got)))))

(deftest eval-js-false-is-nil-on-real-chrome
  (if (null (%chrome-executable))
      (skip "no Chrome/Chromium (set CHROME_PATH)")
      (browser-protocol:with-browser (b :timeout 10)
        (let ((got (browser-protocol:eval-js b "1 === 2")))
          (ok (null got)
              (format nil "eval-js \"1 === 2\" → ~s (want NIL)"
                      (%shown got))))
        (ok (eq t (browser-protocol:eval-js b "1 === 1")) "control: true is T"))))
