;;;; Tests for browser-protocol/record (slice BR1): the specification of the
;;;; contract. Pure tests need no browser and no ffmpeg (a fake CDP peer stands
;;;; in for Chrome); the live tests in live-test.lisp skip, saying why, when
;;;; Chrome or ffmpeg is missing, and those that check played page audio when
;;;; the machine has no audio output device.

(defpackage #:browser-protocol/record/tests
  (:use #:cl #:rove)
  (:local-nicknames (#:rec #:browser-protocol/record)
                    (#:bp #:browser-protocol)
                    (#:audio #:audio-protocol)
                    (#:dsp #:audio-protocol/dsp)))

(in-package #:browser-protocol/record/tests)
