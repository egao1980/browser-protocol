(in-package #:browser-protocol)

;;; browser-protocol/launch (#2): Chrome / Chromium / Edge over CDP on a
;;; websocket (ws-protocol), started as a process (process-protocol).
;;; Playwright's chromium.launch() / new_page() and connect_over_cdp().
;;;
;;; LAUNCH-BROWSER starts the browser headless with its own temporary profile
;;; and --remote-debugging-port=0, reads the port from DevToolsActivePort in
;;; the profile, opens the browser websocket and attaches (flatten) to a page
;;; target: one socket, page commands carry the sessionId. CLOSE-BROWSER sends
;;; Browser.close, stops the process tree and deletes the temporary files.

(defparameter *browser-executable-candidates*
  '("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
    "C:/Program Files/Google/Chrome/Application/chrome.exe"
    "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe")
  "Absolute paths FIND-BROWSER-EXECUTABLE tries after CHROME_PATH.")

(defparameter *browser-executable-names*
  '("google-chrome" "google-chrome-stable" "chromium" "chromium-browser"
    "chrome" "microsoft-edge")
  "Program names FIND-BROWSER-EXECUTABLE looks up on PATH.")

(defun %on-path (name)
  (let ((file (if (uiop:os-windows-p) (concatenate 'string name ".exe") name)))
    (loop for dir in (uiop:split-string (or (uiop:getenv "PATH") "")
                                        :separator (if (uiop:os-windows-p) ";" ":"))
          for found = (and (plusp (length dir))
                           (probe-file
                            (uiop:merge-pathnames*
                             (uiop:parse-unix-namestring file)
                             (uiop:ensure-directory-pathname
                              (uiop:parse-native-namestring dir)))))
          when found
            return found)))

(defun find-browser-executable ()
  "Chrome, Chromium or Edge: $CHROME_PATH, then *BROWSER-EXECUTABLE-CANDIDATES*,
   then *BROWSER-EXECUTABLE-NAMES* on PATH. → native namestring, or NIL."
  (let* ((env (uiop:getenv "CHROME_PATH"))
         (found (or (and env (plusp (length env)) (probe-file env))
                    (some #'probe-file *browser-executable-candidates*)
                    (some #'%on-path *browser-executable-names*))))
    (and found (uiop:native-namestring found))))

;;; --- websocket transport -------------------------------------------------

(defstruct (%inbox (:constructor %make-inbox ()))
  "Messages the websocket reader thread hands to the thread reading CDP."
  (lock (bt2:make-lock :name "browser-protocol cdp inbox"))
  (ready (bt2:make-condition-variable :name "browser-protocol cdp inbox"))
  (head '())
  (tail '())
  (closed nil))

(defun %inbox-push (inbox message)
  (bt2:with-lock-held ((%inbox-lock inbox))
    (let ((cell (list message)))
      (if (%inbox-tail inbox)
          (setf (cdr (%inbox-tail inbox)) cell)
          (setf (%inbox-head inbox) cell))
      (setf (%inbox-tail inbox) cell))
    (bt2:condition-notify (%inbox-ready inbox))))

(defun %inbox-close (inbox reason)
  (bt2:with-lock-held ((%inbox-lock inbox))
    (unless (%inbox-closed inbox)
      (setf (%inbox-closed inbox) (or reason "closed")))
    (bt2:condition-broadcast (%inbox-ready inbox))))

(defun %inbox-pop (inbox timeout)
  "→ the next message. BROWSER-TIMEOUT after TIMEOUT seconds (NIL: wait),
   BROWSER-DISCONNECTED once the socket closed and nothing is left."
  (let ((deadline (%deadline timeout)))
    (bt2:with-lock-held ((%inbox-lock inbox))
      (loop
        (let ((cell (%inbox-head inbox)))
          (when cell
            (setf (%inbox-head inbox) (cdr cell))
            (unless (cdr cell)
              (setf (%inbox-tail inbox) nil))
            (return (car cell))))
        (when (%inbox-closed inbox)
          (error 'browser-disconnected
                 :message (format nil "the CDP websocket closed (~a)" (%inbox-closed inbox))))
        (let ((left (%seconds-left deadline)))
          (when (and left (<= left 0))
            (error 'browser-timeout
                   :limit timeout
                   :message (format nil "no CDP message within ~,1fs" timeout)))
          (bt2:condition-wait (%inbox-ready inbox) (%inbox-lock inbox)
                              :timeout (and left (float left 1d0))))))))

(defclass chrome-browser-backend (cdp-browser-backend)
  ((connection :initform nil :accessor %chrome-connection)
   (process :initarg :process :initform nil :accessor chrome-browser-process
            :documentation "process-protocol handle when LAUNCH-BROWSER started it.")
   (profile :initarg :profile :initform nil :accessor chrome-browser-profile
            :documentation "The --user-data-dir.")
   (run-directory :initarg :run-directory :initform nil :accessor %chrome-run-directory
                  :documentation "Temporary directory (profile, log) removed on close.")
   (target-id :initform nil :accessor chrome-browser-target-id))
  (:documentation
   "CDP over a websocket to Chrome / Chromium / Edge. From LAUNCH-BROWSER
    (CLOSE-BROWSER closes the browser) or CONNECT-CDP (CLOSE-BROWSER detaches
    and leaves the browser running)."))

(defun chrome-browser-backend-p (object)
  (typep object 'chrome-browser-backend))

(defun %open-transport (backend ws-url ws-backend)
  (let* ((inbox (%make-inbox))
         (conn (handler-case
                   (ws:connect ws-url
                               :backend (or ws-backend
                                            (ws-backend-websocket-driver:make-websocket-driver-backend))
                               :transport :http/1.1)
                 (ws-protocol:ws-error (c)
                   (error 'browser-disconnected
                          :url ws-url :cause c
                          :message (format nil "cannot open ~a: ~a" ws-url c))))))
    (ws:on conn :message
           (lambda (message)
             (%inbox-push inbox (if (stringp message)
                                    message
                                    (encoding-protocol:decode message)))))
    (ws:on conn :close
           (lambda (&rest args)
             (%inbox-close inbox (format nil "~{~a~^ ~}" args))))
    (ws:on conn :error
           (lambda (&rest args)
             (%inbox-close inbox (format nil "error~{ ~a~}" args))))
    (setf (%chrome-connection backend) conn
          (cdp-ws-url backend) ws-url
          (cdp-send-fn backend)
          (lambda (cmd)
            (handler-case (ws:send conn (%encode-json-string cmd))
              (ws-protocol:ws-error (c)
                (error 'browser-disconnected
                       :url ws-url :cause c :method (gethash "method" cmd)
                       :message (format nil "cannot send on ~a: ~a" ws-url c)))))
          (cdp-recv-fn backend)
          (lambda () (%inbox-pop inbox *cdp-receive-timeout*)))
    backend))

(defun %close-transport (backend)
  (let ((conn (%chrome-connection backend)))
    (setf (%chrome-connection backend) nil
          (cdp-send-fn backend) nil
          (cdp-recv-fn backend) nil)
    (when conn
      (handler-case (ws:close conn)
        (ws-protocol:ws-error () nil)))))

(defun %attach-page (backend)
  "Browser endpoint: attach (flatten) to the first page target, creating one
   when there is none. Page commands then carry the session id."
  (let* ((infos (%jget (%cdp-browser-call backend "Target.getTargets") "targetInfos"))
         (page (find-if (lambda (info) (equal "page" (%jget info "type")))
                        (and infos (coerce infos 'list))))
         (target-id (if page
                        (%jget page "targetId")
                        (%jget (%cdp-browser-call backend "Target.createTarget"
                                                  (%ht "url" "about:blank"))
                               "targetId")))
         (session (%jget (%cdp-browser-call backend "Target.attachToTarget"
                                            (%ht "targetId" target-id "flatten" t))
                         "sessionId")))
    (setf (chrome-browser-target-id backend) target-id
          (cdp-session-id backend) session)
    backend))

(defun %connect-backend (backend ws-url ws-backend)
  "Open WS-URL, attach to a page unless WS-URL is already a page endpoint,
   CONNECT-BROWSER. Closes the socket again when any step fails."
  (let ((done nil))
    (unwind-protect
         (progn
           (%open-transport backend ws-url ws-backend)
           (unless (search "/devtools/page/" ws-url)
             (%attach-page backend))
           (connect-browser backend :ws-url ws-url)
           (setf done t)
           backend)
      (unless done
        (%close-transport backend)))))

(defun connect-cdp (ws-url &key (timeout 30) ws-backend)
  "Connect to a running browser's DevTools websocket WS-URL: the browser
   endpoint ws://HOST:PORT/devtools/browser/ID (DevToolsActivePort,
   /json/version) or a page endpoint ws://HOST:PORT/devtools/page/ID.
   → a connected CHROME-BROWSER-BACKEND on a page. TIMEOUT is the per-command
   limit in seconds. WS-BACKEND defaults to a websocket-driver backend.
   CLOSE-BROWSER detaches and leaves the browser running."
  (%connect-backend (make-instance 'chrome-browser-backend :timeout timeout)
                    ws-url ws-backend))

(defun %root-p ()
  #+(and sbcl unix) (zerop (sb-unix:unix-getuid))
  #-(and sbcl unix) nil)

(defun %temporary-directory ()
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "browser-protocol-~36r-~36r"
                                       (get-universal-time)
                                       (random (expt 36 6) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defun %devtools-ws-url (profile process timeout log)
  "Poll PROFILE/DevToolsActivePort (port, then the browser websocket path)."
  (let ((file (merge-pathnames "DevToolsActivePort" profile))
        (deadline (%deadline timeout)))
    (loop
      (let ((lines (and (probe-file file)
                        (handler-case (uiop:read-file-lines file)
                          (file-error () nil)))))
        (when (and (>= (length lines) 2)
                   (plusp (length (second lines))))
          (let ((port (parse-integer (first lines) :junk-allowed t)))
            (when port
              (return (format nil "ws://127.0.0.1:~d~a" port (second lines)))))))
      (unless (stack-process:alive-p process)
        (error 'browser-error
               :message (format nil "the browser exited (code ~a) before DevTools was ready; see ~a"
                                (stack-process:exit-code process) (uiop:native-namestring log))))
      (let ((left (%seconds-left deadline)))
        (when (and left (<= left 0))
          (error 'browser-timeout
                 :limit timeout
                 :message (format nil "no DevToolsActivePort within ~as; see ~a"
                                  timeout (uiop:native-namestring log)))))
      (sleep 0.05))))

(defun launch-browser (&key executable (headless t) args user-data-dir
                         (url "about:blank") (timeout 30)
                         (sandbox (not (%root-p))) ws-backend)
  "Start Chrome / Chromium / Edge with remote debugging and → a connected
   CHROME-BROWSER-BACKEND on its page (Playwright's chromium.launch() +
   new_page()). EXECUTABLE defaults to FIND-BROWSER-EXECUTABLE. HEADLESS
   adds --headless=new. USER-DATA-DIR defaults to a temporary profile,
   deleted on CLOSE-BROWSER. ARGS are extra command-line flags; URL is the
   first page. TIMEOUT (seconds) bounds the start and each command. SANDBOX
   NIL adds --no-sandbox (the default when running as root, where Chrome
   refuses to start sandboxed). The browser's output goes to chrome.log in
   the temporary directory."
  (let* ((exe (or executable
                  (find-browser-executable)
                  (error 'browser-error
                         :message "no Chrome / Chromium / Edge found: pass :executable or set CHROME_PATH")))
         (run-dir (%temporary-directory))
         (profile (uiop:ensure-directory-pathname
                   (or user-data-dir (merge-pathnames "profile/" run-dir))))
         (log (merge-pathnames "chrome.log" run-dir))
         (port-file (merge-pathnames "DevToolsActivePort" profile))
         (argv (append (list (uiop:native-namestring exe))
                       (when headless (list "--headless=new"))
                       (list "--remote-debugging-port=0"
                             (format nil "--user-data-dir=~a" (uiop:native-namestring profile))
                             "--no-first-run"
                             "--no-default-browser-check"
                             "--disable-background-networking"
                             "--disable-sync")
                       (unless sandbox (list "--no-sandbox"))
                       args
                       (list url)))
         (backend (make-instance 'chrome-browser-backend
                                 :timeout timeout :profile profile :run-directory run-dir))
         (done nil))
    (ensure-directories-exist profile)
    ;; A reused profile keeps the file of its last run, with a dead port.
    (when (probe-file port-file)
      (delete-file port-file))
    (unwind-protect
         (progn
           (setf (chrome-browser-process backend)
                 (handler-case
                     (stack-process:launch argv :output log :error-output :output
                                                :process-group t)
                   (stack-process:process-error (c)
                     (error 'browser-error
                            :cause c
                            :message (format nil "cannot start ~a: ~a" exe c)))))
           (%connect-backend backend
                             (%devtools-ws-url profile (chrome-browser-process backend)
                                               timeout log)
                             ws-backend)
           (setf done t)
           backend)
      (unless done
        (%stop-browser-process backend)
        (%remove-run-directory backend)))))

(defun %stop-browser-process (backend)
  "Wait a moment for the browser to exit, then stop its whole process group."
  (let ((process (chrome-browser-process backend)))
    (when process
      (setf (chrome-browser-process backend) nil)
      (handler-case (stack-process:wait process :timeout 5)
        (stack-process:process-error () nil))
      ;; Renderer / GPU helpers share the group, also after the parent exited.
      (handler-case (stack-process:kill process :tree t :force t)
        (stack-process:process-error () nil))
      (handler-case (stack-process:wait process :timeout 5)
        (stack-process:process-error () nil)))))

(defun %remove-run-directory (backend)
  (let ((dir (%chrome-run-directory backend)))
    (when dir
      (setf (%chrome-run-directory backend) nil)
      (handler-case
          (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)
        (file-error (c)
          (warn "browser-protocol: could not remove ~a: ~a" dir c))))))

(defmethod close-browser ((backend chrome-browser-backend))
  (unwind-protect
       (cond
         ;; Launched: Browser.close (CDP-BROWSER-BACKEND's method).
         ((chrome-browser-process backend) (call-next-method))
         ;; Connected: leave the browser running, drop our session.
         ((and (cdp-session-id backend) (%chrome-connection backend))
          (handler-case
              (%cdp-browser-call backend "Target.detachFromTarget"
                                 (%ht "sessionId" (cdp-session-id backend)) 5)
            (browser-error () nil))))
    (%close-transport backend)
    (%stop-browser-process backend)
    (%remove-run-directory backend)
    (setf (cdp-connected-p backend) nil))
  t)

(defmacro with-browser ((var &rest options) &body body)
  "Bind VAR, and *BROWSER-BACKEND*, to (LAUNCH-BROWSER ,@OPTIONS) around BODY;
   CLOSE-BROWSER on the way out."
  `(let* ((,var (launch-browser ,@options))
          (*browser-backend* ,var))
     (unwind-protect (progn ,@body)
       (close-browser ,var))))
