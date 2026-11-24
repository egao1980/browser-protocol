(in-package #:browser-protocol/tests)

;;; browser-protocol#1. The CDP client carries a private JSON parser (used
;;; whenever no json-protocol backend happens to be bound) and private base64.
;;; The private parser cannot read `false`: PARSE-LITERAL returns the literal's
;;; value, NIL for false, so (or (parse-literal "false" nil) (error ...))
;;; always errors. Chrome's Page.navigate reply carries "isDownload": false.

(defparameter *chrome-navigate-reply*
  ;; Verbatim from Chrome 142 headless (2026-11-23).
  "{\"id\":1,\"result\":{\"frameId\":\"13AAB0BE9ACCA194BE5D8B66BD278795\",\"loaderId\":\"B5DEC2C3688A1476E494B6B15132FBA5\",\"isDownload\":false}}")

(deftest decode-chrome-navigate-reply
  (let ((msg (handler-case (browser-protocol:decode-cdp-message *chrome-navigate-reply*)
               (error (c) (princ-to-string c)))))
    (ok (hash-table-p msg) (format nil "decoded, not ~s" msg))
    (when (hash-table-p msg)
      (let ((result (browser-protocol:cdp-message-result msg)))
        (ok (equal "13AAB0BE9ACCA194BE5D8B66BD278795" (gethash "frameId" result)))
        (multiple-value-bind (value present) (gethash "isDownload" result)
          (ok (and present (member value '(nil :false)))
              (format nil "isDownload is false, got ~s" value)))))))

(defun %json-text-chrome ()
  "SEND-FN / RECV-FN of a websocket: commands leave as JSON text, Chrome's
   answers come back as JSON text. Replies carry the command's id, as Chrome's
   do; Page.navigate answers with the verbatim *CHROME-NAVIGATE-REPLY* and then
   Page.loadEventFired."
  (let ((queue '()))
    (values
     (lambda (cmd)
       (let* ((text (json-protocol:encode cmd))
              (msg (json-protocol:decode text))
              (id (gethash "id" msg)))
         (setf queue
               (append queue
                       (if (equal "Page.navigate" (gethash "method" msg))
                           (list (format nil "{\"id\":~d~a" id
                                         (subseq *chrome-navigate-reply*
                                                 (length "{\"id\":1")))
                                 "{\"method\":\"Page.loadEventFired\",\"params\":{\"timestamp\":2.5}}")
                           (list (format nil "{\"id\":~d,\"result\":{}}" id)))))))
     (lambda ()
       (or (pop queue)
           (error 'browser-protocol:browser-timeout :message "nothing pending"))))))

(deftest navigate-over-a-json-text-transport
  ;; A websocket hands RECV-FN JSON text. With browser-protocol 0.1.0 against
  ;; real Chrome: BROWSER-ERROR "bad JSON false".
  ;; Defender (0.2.0): NAVIGATE now sends Page.enable and waits for the load
  ;; event (#2), so a RECV-FN that returns the id-1 reply forever cannot
  ;; answer it; the first case keeps that transport with :wait-until :commit
  ;; (one command, id 1), the second answers like Chrome.
  (let* ((b (browser-protocol:make-cdp-browser-backend
             :send-fn (lambda (cmd) (declare (ignore cmd)))
             :recv-fn (lambda () *chrome-navigate-reply*)))
         (got (handler-case (browser-protocol:navigate b "data:text/html,<title>x</title>"
                                                       :wait-until :commit)
                (error (c) (format nil "~a: ~a" (type-of c) c)))))
    (ok (equal "data:text/html,<title>x</title>" got)
        (format nil "navigate returned ~s" got)))
  (multiple-value-bind (send recv) (%json-text-chrome)
    (let* ((b (browser-protocol:make-cdp-browser-backend :send-fn send :recv-fn recv))
           (got (handler-case (browser-protocol:navigate b "data:text/html,<title>x</title>")
                  (error (c) (format nil "~a: ~a" (type-of c) c)))))
      (ok (equal "data:text/html,<title>x</title>" got)
          (format nil "navigate (wait for load) returned ~s" got)))))

(deftest depends-on-stack-json-and-encoding
  ;; AGENTS.md "Own stack first": stack protocols are always allowed
  ;; dependencies, so there is no soft use and no fallback.
  (let ((deps (mapcar (lambda (d)
                        (string-downcase
                         (string (if (consp d) (find-if #'stringp d) d))))
                      (asdf:system-depends-on (asdf:find-system "browser-protocol")))))
    (ok (member "json-protocol" deps :test #'equal) "depends on json-protocol")
    (ok (member "encoding-protocol" deps :test #'equal) "depends on encoding-protocol")))

(deftest no-private-json-or-base64
  (dolist (name '("%PARSE-JSON" "%BASE64-ENCODE" "%BASE64-DECODE"))
    (let ((s (find-symbol name :browser-protocol)))
      (ok (not (and s (fboundp s)))
          (format nil "browser-protocol::~a is gone" name)))))
