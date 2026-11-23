# browser-protocol

Lispy **CLOS** headless-browser API for [cl-stack](https://github.com/egao1980/cl-stack) — CDP JSON `{id, method, params}`, a mock backend, and a computer-use loop over `llm-protocol`.

| System | Role | Repo |
|--------|------|------|
| `browser-protocol` (`stack-browser`) | Protocol / CDP client / mock / computer-use | this repo |
| `browser-protocol/capability` | `:world` browser adapter | this repo |
| `browser-protocol/launch` | `launch-browser` / `with-browser` / `connect-cdp`: Chrome, Chromium or Edge over a CDP websocket | this repo |

Chromium conceptually runs *inside* an A9 `compute-protocol` sandbox. A compute backend slot is accepted; podman is **not** required. CDP I/O goes through `send-fn` / `recv-fn` (JSON text, hash-tables or plists), so tests need no browser. `browser-protocol/launch` wires them to a real browser.

JSON goes through [`json-protocol`](https://github.com/egao1980/json-protocol) (default backend `json-backend-jzon`: objects → string-key hash-tables, `false` → `NIL`, `null` → `:null`), screenshot / PDF base64 through [`encoding-protocol`](https://github.com/egao1980/encoding-protocol). Malformed JSON or base64 from the browser is a `browser-error` whose `browser-error-cause` is the stack condition.

## Launch a real browser (0.2.0)

```lisp
(asdf:load-system "browser-protocol/launch")

;; Playwright: with sync_playwright() as p: b = p.chromium.launch(); page = b.new_page()
(stack-browser:with-browser (b)                 ; headless, temporary profile
  (stack-browser:navigate b "https://example.com") ; waits for the load event
  (stack-browser:eval-js b "document.title")       ; => "Example Domain"
  (stack-browser:screenshot b))                    ; PNG octets

(let ((b (stack-browser:launch-browser :headless nil :args '("--window-size=1280,800"))))
  (unwind-protect (stack-browser:navigate b "https://example.com" :wait-until :domcontentloaded)
    (stack-browser:close-browser b)))            ; Browser.close, process tree stopped, profile deleted

;; An already running browser (chrome --remote-debugging-port=9222):
(stack-browser:connect-cdp "ws://127.0.0.1:9222/devtools/browser/<id>") ; close-browser only detaches
```

`launch-browser` finds the browser with `find-browser-executable` (``, the usual macOS / Windows install paths, then `google-chrome`, `chromium`, … on `PATH`), starts it with `--remote-debugging-port=0` and a temporary `--user-data-dir`, reads the port from `DevToolsActivePort`, opens the browser websocket (`ws-protocol`, websocket-driver backend) and attaches to a page target with a flattened session. Keys: `:executable` `:headless` (default `t`) `:args` `:user-data-dir` (kept on close) `:url` `:timeout` (seconds, start and each command; default 30) `:sandbox` (`nil` adds `--no-sandbox`; the default as root). The browser's output goes to `chrome.log` in the temporary directory, named in the error when it fails to start. The process runs in its own process group (`process-protocol`), so close stops its helpers too.

**Replies and events.** `cdp-call` sends a command and reads until the reply with its id; events in between go to `on-cdp-event` handlers (`(on-cdp-event b "Network.requestWillBeSent" (lambda (params) …))`, removed with `off-cdp-event`) and to a buffer (`*cdp-event-buffer-limit*`, default 1000) that `wait-for-cdp-event` reads first. A reply to an abandoned command is dropped. Handlers run on the reading thread while a command or a wait reads. `*cdp-receive-timeout*` is bound around each `recv-fn` call so a custom transport can time out; `recv-fn` returning `NIL` means the transport closed (`browser-disconnected`).

**`navigate`** takes Playwright's `:wait-until`: `:load` (default, `Page.loadEventFired`), `:domcontentloaded`, `:commit` / `nil` (return on the `Page.navigate` reply), and `:timeout` (seconds, default `cdp-timeout`). It sends `Page.enable` once per backend. A failed navigation (`errorText`, e.g. `net::ERR_NAME_NOT_RESOLVED`) signals `browser-error` with the URL; a same-document navigation (`#fragment`) has nothing to wait for. Past the timeout: `browser-timeout`.

## Without a browser

```lisp
(asdf:load-system "browser-protocol")

(let ((b (stack-browser:make-mock-browser-backend)))
  (stack-browser:navigate b "https://example.test")
  (stack-browser:click b :selector "#go")
  (stack-browser:screenshot b))

;; CDP commands without Chromium:
(stack-browser:encode-cdp-command 1 "Page.navigate"
                                  '(:url "https://example.test"))

(let ((b (stack-browser:make-cdp-browser-backend
          :send-fn #'send-over-ws
          :recv-fn #'recv-from-ws)))
  (stack-browser:navigate b "https://example.test"))
```

| Role | GF / fn | In-tree |
|------|---------|---------|
| page | `navigate` `dom-snapshot` `screenshot` `click` `type-text` `scroll` `eval-js` `print-pdf` | `mock-browser-backend`, `cdp-browser-backend` |
| session | `connect-browser` `close-browser` `list-targets` | same |
| CDP | `encode-cdp-command` / `decode-cdp-message` | hash-table `{id, method, params}` |
| computer use | `computer-use-step` / `computer-use-loop` | screenshot → `llm-image-part` → action tools |
| capability | `navigate` / `screenshot` / … on `browser-adapter` | `browser-protocol/capability` |

`screenshot` and `print-pdf` return `(vector (unsigned-byte 8))`. `dom-snapshot` is a string or node plist.

Conditions: `browser-error`, `browser-timeout`, `browser-disconnected`. Operations establish `retry` and `use-value`.

`:world` catalogue does not yet intern `:browser` (capability-protocol 0.2.1). The capability subsystem registers an adapter on a live `:world` catalogue when the vocab can be extended, otherwise on a blackboard:

```lisp
(asdf:load-system "browser-protocol/capability")
(let* ((b (stack-browser:make-mock-browser-backend))
       (host (stack-browser:make-browser-catalogue b)))
  (capability-protocol:invoke-operation
   (capability-protocol:get-capability host :browser)
   'stack-browser:navigate "https://ex.test"))
```

Computer-use tools: `click`, `type`, `scroll`, `navigate`, `done`. Image *input* wire encoding lives in `llm-protocol-openai` / `llm-protocol-anthropic` (`encode-image-part`). Image generation is out of scope.

## License

MIT — see [LICENSE](LICENSE).
