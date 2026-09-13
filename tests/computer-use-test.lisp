(in-package #:browser-protocol/tests)

(deftest computer-use-step-click
  (let* ((browser (browser-protocol:make-mock-browser-backend))
         (llm (llm-protocol:make-mock-llm-backend
               :tool-calls (list (llm-protocol:make-llm-tool-call-part
                                  :id "c1"
                                  :name "click"
                                  :arguments "{\"selector\":\"#go\"}"))))
         (step (browser-protocol:computer-use-step
                browser llm :goal "click the go button")))
    (ok (browser-protocol:computer-use-step-result-p step))
    (ok (not (browser-protocol:computer-use-step-done-p step)))
    (ok (equal "click"
               (getf (first (browser-protocol:computer-use-step-actions step))
                     :name)))
    (ok (equal "#go"
               (getf (first (browser-protocol:mock-browser-clicks browser))
                     :selector)))))

(deftest computer-use-loop-stops-on-done
  (let* ((n 0)
         (browser (browser-protocol:make-mock-browser-backend))
         (llm (llm-protocol:make-mock-llm-backend
               :handler (lambda (backend turns &key &allow-other-keys)
                          (declare (ignore backend turns))
                          (incf n)
                          (llm-protocol:make-llm-response
                           :parts (list (if (>= n 2)
                                            (llm-protocol:make-llm-tool-call-part
                                             :name "done"
                                             :arguments "{}")
                                            (llm-protocol:make-llm-tool-call-part
                                             :name "click"
                                             :arguments "{\"selector\":\"#a\"}")))
                           :finish-reason :tool-use))))
         (steps (browser-protocol:computer-use-loop
                 browser llm :goal "finish" :max-steps 5)))
    (ok (= 2 (length steps)))
    (ok (not (browser-protocol:computer-use-step-done-p (first steps))))
    (ok (browser-protocol:computer-use-step-done-p (second steps)))
    (ok (= 1 (length (browser-protocol:mock-browser-clicks browser))))))

(deftest computer-use-tools-include-actions
  (let ((names (mapcar #'llm-protocol:llm-tool-name
                       (browser-protocol:computer-use-tools))))
    (ok (equal '("click" "type" "scroll" "navigate" "done") names))))
