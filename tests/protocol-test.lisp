(in-package #:browser-protocol/tests)

(deftest mock-navigate-and-click
  (let ((b (browser-protocol:make-mock-browser-backend)))
    (ok (equal "https://ex.test/a"
               (browser-protocol:navigate b "https://ex.test/a")))
    (ok (equal "https://ex.test/a" (browser-protocol:mock-browser-url b)))
    (ok (browser-protocol:click b :selector "#go"))
    (let ((click (first (browser-protocol:mock-browser-clicks b))))
      (ok (equal "#go" (getf click :selector))))
    (ok (browser-protocol:click b :x 10 :y 20))
    (ok (= 2 (length (browser-protocol:mock-browser-clicks b))))))

(deftest mock-screenshot-octets
  (let* ((b (browser-protocol:make-mock-browser-backend))
         (png (browser-protocol:screenshot b)))
    (ok (typep png '(vector (unsigned-byte 8))))
    (ok (>= (length png) 8))
    (ok (= 137 (aref png 0)))
    (ok (= 80 (aref png 1)))))

(deftest mock-type-scroll-eval-pdf
  (let ((b (browser-protocol:make-mock-browser-backend
            :eval-fn (lambda (backend expression)
                       (declare (ignore backend))
                       (format nil "ok:~a" expression)))))
    (browser-protocol:type-text b "hi" :selector "#in")
    (ok (equal "hi" (getf (first (browser-protocol:mock-browser-typed b)) :text)))
    (browser-protocol:scroll b :dy 40)
    (ok (eql 40 (getf (first (browser-protocol:mock-browser-scrolls b)) :dy)))
    (ok (equal "ok:1+1" (browser-protocol:eval-js b "1+1")))
    (ok (equal "1+1" (first (browser-protocol:mock-browser-evals b))))
    (let ((pdf (browser-protocol:print-pdf b)))
      (ok (typep pdf '(vector (unsigned-byte 8))))
      (ok (= 37 (aref pdf 0))))))

(deftest mock-dom-snapshot
  (let ((b (browser-protocol:make-mock-browser-backend
            :dom "<html><body>hi</body></html>")))
    (ok (equal "<html><body>hi</body></html>"
               (browser-protocol:dom-snapshot b)))))

(deftest mock-targets-and-session
  (let ((b (browser-protocol:make-mock-browser-backend)))
    (ok (browser-protocol:connect-browser b :url "https://ex.test"))
    (ok (browser-protocol:mock-browser-connected-p b))
    (let ((targets (browser-protocol:list-targets b)))
      (ok (= 1 (length targets)))
      (ok (browser-protocol:browser-target-p (first targets))))
    (browser-protocol:close-browser b)
    (ok (not (browser-protocol:mock-browser-connected-p b)))))
