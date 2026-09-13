# browser-protocol

Lispy **CLOS** headless-browser API for [cl-stack](https://github.com/egao1980/cl-stack) — CDP JSON `{id, method, params}`, a mock backend, and a computer-use loop over `llm-protocol`.

| System | Role | Repo |
|--------|------|------|
| `browser-protocol` (`stack-browser`) | Protocol / CDP client / mock / computer-use | this repo |
| `browser-protocol/capability` | `:world` browser adapter | this repo |

Chromium conceptually runs *inside* an A9 `compute-protocol` sandbox. A compute backend slot is accepted; podman is **not** required. CDP I/O goes through `send-fn` / `recv-fn` (typically `ws-protocol` JSON text) so tests need no browser.

`ws-protocol`, `http-protocol`, and `json-protocol` are **soft-used**. The CDP encoder/decoder works on hash-tables and plists; JSON strings decode via `json-protocol` when `*json-backend*` is bound, else a small built-in parser.

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
