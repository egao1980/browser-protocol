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

**Replies and events.** `cdp-call` sends a command and returns the result of the reply with its id. Whoever reads the transport files what it reads: a reply goes to the command waiting for that id (a reply to an abandoned command is dropped), an event goes to a buffer (`*cdp-event-buffer-limit*`, default 1000) and then to its `on-cdp-event` handlers (`(on-cdp-event b "Network.requestWillBeSent" (lambda (params) …))`, removed with `off-cdp-event`). `wait-for-cdp-event` takes its event from that buffer. One thread reads at a time; other threads wait until it files something, each until its own deadline. Handlers run on the reading thread with no lock held, so a handler may send commands itself (Playwright's `page.route` + `route.continue_()` is a `Fetch.requestPaused` handler that calls `Fetch.continueRequest`): replies and events it reads still reach the commands and waits they belong to, and several threads can share one backend. An error from a handler propagates from the call that read the event. `*cdp-receive-timeout*` is bound around each `recv-fn` call so a custom transport can time out; `recv-fn` returning `NIL` means the transport closed (`browser-disconnected`).

**JavaScript values.** `eval-js` (and `dom-snapshot`) evaluate with `returnByValue` and map the RemoteObject: its value as json-protocol decodes it (`false` → `NIL`, `null` → `:null`, arrays → vectors, objects → hash-tables), `undefined` → `NIL`, a BigInt → an integer, `-0` → `-0.0d0`, `NaN` / `Infinity` / `-Infinity` → `:nan` / `:infinity` / `:-infinity`; a value Chrome cannot serialize (a function) comes back as the RemoteObject hash-table. A JavaScript exception signals `browser-error` with its text, as Playwright's `evaluate` raises; `click` / `type-text` on a selector that matches nothing signal it too. To send JSON `false` in `cdp-call` params use `NIL` (json-protocol's convention).

**`navigate`** takes Playwright's `:wait-until`: `:load` (default), `:domcontentloaded`, `:commit` / `nil` (return on the `Page.navigate` reply), and `:timeout` (seconds, default `cdp-timeout`). It sends `Page.enable` once per backend. It waits for the document its own navigation committed: the backend follows the main frame's documents in the order their events are read. A main-frame `Page.frameNavigated` starts a document with its `loaderId`, and the `Page.domContentEventFired` / `Page.loadEventFired` that follow (or a `Page.lifecycleEvent` with that `loaderId`) belong to it. So the load event of the previous page, still unread after a `:commit` or `:domcontentloaded` navigation, does not end the next navigation. If a script replaces the document before it loads, `navigate` waits for the new document's load, like Playwright's `goto`. A peer that never sends a main-frame `Page.frameNavigated` cannot be followed this way; for it, the first load event read after the reply ends the wait. A failed navigation (`errorText`, e.g. `net::ERR_NAME_NOT_RESOLVED`) signals `browser-error` with the URL; a same-document navigation (`#fragment`) has nothing to wait for. Past the timeout: `browser-timeout`. Once `navigate` returns, its load events are no longer in the buffer, so a later `wait-for-cdp-event` waits for the next one.

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
