(in-package #:browser-protocol/tests)

(deftest browser-adapter-navigate
  (let* ((backend (browser-protocol:make-mock-browser-backend))
         (cap (browser-protocol:make-browser-adapter :backend backend)))
    (ok (eq :browser (capability-protocol:capability-name cap)))
    (ok (equal "https://ex.test"
               (browser-protocol:navigate cap "https://ex.test")))
    (ok (equal "https://ex.test"
               (browser-protocol:mock-browser-url backend)))
    (ok (typep (browser-protocol:screenshot cap)
               '(vector (unsigned-byte 8))))))

(deftest browser-catalogue-world
  (let* ((backend (browser-protocol:make-mock-browser-backend))
         (host (browser-protocol:make-browser-catalogue backend))
         (cap (capability-protocol:get-capability host :browser)))
    (ok (capability-protocol:capability-supported-p host :browser))
    (ok cap)
    (ok (eq :browser (capability-protocol:capability-name cap)))
    (ok (equal "https://ex.test/cap"
               (capability-protocol:invoke-operation
                cap 'browser-protocol:navigate "https://ex.test/cap")))
    (ok (equal "https://ex.test/cap"
               (browser-protocol:mock-browser-url backend)))))
