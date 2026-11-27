(in-package #:browser-protocol/record/tests)

;;; DECODE-PCM16, PARSE-AUDIO-CHUNK, CHUNK-EPOCH.

(deftest decode-pcm16-codes
  (let ((v (rec:decode-pcm16 (%octets 0 0  0 64  0 192  255 127  0 128  1 0  255 255))))
    (ok (typep v 'audio:sample-vector))
    (ok (equalp (vector 0.0 0.5 -0.5 (/ 32767 32768.0) -1.0 (/ 1 32768.0) (/ -1 32768.0)) v)
        (format nil "~s" v))))

(deftest decode-pcm16-empty-and-odd
  (ok (equalp #() (rec:decode-pcm16 (%octets))))
  (ok (signals (rec:decode-pcm16 (%octets 1 2 3)) 'bp:browser-error))
  (ok (signals (rec:decode-pcm16 "abcd") 'type-error)))

(deftest parse-audio-chunk-fields
  (let ((c (%chunk :track "d1/2" :seq 7 :rate 44100 :channels 2 :frame -4096
                   :context-time 0.5d0 :performance-time 1234.5d0 :time-origin 1700000000000
                   :samples '(0.25 -0.25 0.5 -0.5))))
    (ok (rec:audio-chunk-p c))
    (ok (equal "d1/2" (rec:audio-chunk-track c)))
    (ok (= 7 (rec:audio-chunk-seq c)))
    (ok (= 44100 (rec:audio-chunk-sample-rate c)))
    (ok (= 2 (rec:audio-chunk-channels c)))
    (ok (= -4096 (rec:audio-chunk-frame c)))
    (ok (= 0.5d0 (rec:audio-chunk-context-time c)))
    (ok (= 1234.5d0 (rec:audio-chunk-performance-time c)))
    (ok (= 1700000000000 (rec:audio-chunk-time-origin c)))
    (ok (equalp (vector 0.25 -0.25 0.5 -0.5) (rec:audio-chunk-samples c)))
    (ok (= 2 (rec:audio-chunk-frames c)))))

(deftest parse-audio-chunk-mono-and-extra-members
  (let* ((h (json-protocol:decode (%chunk-payload :channels 1 :samples '(0.5 0.25 0.125))))
         (_ (setf (gethash "extra" h) "ignored"))
         (c (rec:parse-audio-chunk (json-protocol:encode h))))
    (declare (ignore _))
    (ok (= 1 (rec:audio-chunk-channels c)))
    (ok (= 3 (rec:audio-chunk-frames c)))))

(deftest-parametrize parse-audio-chunk-rejects
    ((payload)
     :ids ("not-json" "not-object" "array" "version-2" "no-track" "empty-track" "track-number"
           "no-seq" "negative-seq" "float-seq" "no-rate" "zero-rate" "channels-3" "channels-0"
           "frame-float" "no-frame" "context-time-string" "no-performance-time" "no-time-origin"
           "no-pcm" "pcm-not-base64" "pcm-empty" "pcm-odd-bytes" "pcm-half-frame")
     ("{\"v\":1,")
     ("42")
     ("[1,2]")
     ((%chunk-payload :version 2))
     ((%chunk-payload :omit '("track")))
     ((%chunk-payload :track ""))
     ((%chunk-payload :track 12))
     ((%chunk-payload :omit '("seq")))
     ((%chunk-payload :seq -1))
     ((%chunk-payload :seq 1.5d0))
     ((%chunk-payload :omit '("rate")))
     ((%chunk-payload :rate 0))
     ((%chunk-payload :channels 3 :samples '(0 0 0)))
     ((%chunk-payload :channels 0))
     ((%chunk-payload :frame 1.5d0))
     ((%chunk-payload :omit '("frame")))
     ((%chunk-payload :context-time "0"))
     ((%chunk-payload :omit '("performanceTime")))
     ((%chunk-payload :omit '("timeOrigin")))
     ((%chunk-payload :omit '("pcm")))
     ((%chunk-payload :pcm "@@@@"))
     ((%chunk-payload :pcm ""))
     ((%chunk-payload :pcm (%b64 (%octets 1 2 3))))
     ((%chunk-payload :channels 2 :pcm (%b64 (%octets 1 2 3 4 5 6)))))
  (ok (signals (rec:parse-audio-chunk payload) 'bp:browser-error)))

(deftest parse-audio-chunk-keeps-the-cause
  (handler-case (progn (rec:parse-audio-chunk "{\"v\":") (ok nil "no error"))
    (bp:browser-error (c)
      (ok (typep (bp:browser-error-cause c) 'json-protocol:json-error))))
  (handler-case (progn (rec:parse-audio-chunk (%chunk-payload :pcm "@@@@")) (ok nil "no error"))
    (bp:browser-error (c)
      (ok (typep (bp:browser-error-cause c) 'encoding-protocol:encoding-error))))
  (ok (signals (rec:parse-audio-chunk 42) 'bp:browser-error) "a payload that is not a string"))

(deftest chunk-epoch-exact
  ;; (timeOrigin + performanceTime) / 1000 + frame / rate - contextTime
  (ok (= (+ (/ (+ 1000000 1500) 1000) (/ 24000 48000) -1/4)
         (rec:chunk-epoch (%chunk :time-origin 1000000 :performance-time 1500
                                  :frame 24000 :rate 48000 :context-time 0.25d0))))
  (ok (= (+ (/ (+ (rational 1795797870000.125d0) (rational 744.1d0)) 1000)
            (/ 30720 48000)
            (- (rational 0.57526d0)))
         (rec:chunk-epoch (%chunk :time-origin 1795797870000.125d0 :performance-time 744.1d0
                                  :frame 30720 :rate 48000 :context-time 0.57526d0)))
      "every member as its exact rational")
  (ok (typep (rec:chunk-epoch (%chunk :context-time 0.1d0)) 'rational))
  (ok (= (- 1001 (/ 2048 48000))
         (rec:chunk-epoch (%chunk :time-origin 1000000 :performance-time 1000
                                  :frame -2048 :rate 48000 :context-time 0)))
      "a negative frame (the input buffer began before frame 0)"))
