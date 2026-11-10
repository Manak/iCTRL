# Stage 2: the MCP layer on localhost

Status on 2026-11-10: built, unit-tested on the Mac (52 tests), and run on an
iPhone on iOS 27.2 over a USB port forward. Results are under "Tested on the
phone" below.

## What it is

An MCP server (Streamable HTTP, stateless JSON responses) that runs inside the
iCTRL runner and listens on `127.0.0.1:8220` only. It is off by default; with
it off the runner behaves exactly like upstream.

```
POST /<secret>/mcp ─▶ BridgeHTTPServer (loopback only)
                      └▶ BridgeMCPServer   auth, then initialize / tools/list / tools/call
                         └▶ BridgeTools    argument checks, rate limit, action log
                            └▶ BridgeGuard check foreground ▶ act ▶ check again
                               └▶ iCTRL's in-process RPC dispatcher (the raw API)
```

The raw API is never proxied. Each tool builds its own raw call from validated
arguments.

## Tools

| Tool | During lockout | Notes |
|---|---|---|
| `phone_status` | works | State (`ready`, `locked_out`, `phone_locked`), battery, thermal state. Never names a non-allowlisted app. |
| `list_allowed_apps` | works | The allowlist. Read-only. |
| `go_home` | works | Returns to the home screen. The way out of lockout. |
| `screenshot` | refused | JPEG. At scale 1, pixels equal tap points. |
| `read_ui` | refused | Visible UI tree with frames, optional `filter_text`. |
| `tap` | refused | x, y in points. |
| `swipe` | refused | Refuses starts within 40 pt of the top edge or 50 pt of the bottom edge (system gestures). |
| `type_text` | refused | Refused in apps marked read-only. |
| `launch_app` | refused | Allowlisted bundle ids only. |
| `open_url` | refused | Only URL schemes and link hosts that belong to an allowlisted app. |

There is no tool that changes the allowlist.

## Rules enforced

- **Before and after every action** the bridge reads the foreground app
  (`device_info`). Home screen, system search or an allowlisted app: proceed.
  Anything else, including an app the runner cannot name: lockout.
- **"Home" is verified, not assumed.** SpringBoard also hosts the app
  switcher, which shows other apps' screens. When SpringBoard is in front the
  bridge reads SpringBoard's own UI tree and accepts it as home only if the
  icon grid (`Home screen icons`) is there and no app-switcher element is.
- **System search is allowed like the home screen.** On iOS 27 the pull-down
  search is a separate process, "Siri AI", bundle id `com.apple.campo`. It can
  be in front, but `launch_app` will not open it and it is not in the
  editable allowlist. Note that search can show results from any app.
- **Lockout** returns only `locked: non-allowlisted app in foreground…`. No app
  name, no screen content. If an action itself caused it, the action's result
  (including a screenshot already captured) is discarded.
- **Lockout clears by itself** when the home screen or an allowlisted app is
  in front again. Each lockout is written to the runner log once.
- **Phone locked** returns `phone locked: …` and does nothing.
- **Screen content is quoted** inside a `<screen_content id="…">` block with a
  random id and a note that it is untrusted data. Raw error text is quoted the
  same way, because it can contain on-screen labels.
- **Rate limit**: bursts of 30 calls, 2 per second sustained.
- **Auth**: a 256-bit URL-path secret, compared in constant time. Any other
  request gets a plain `404 page not found`. The secret is generated on first
  start and kept in the runner's keychain. It is never logged.
- **Action log**: tool name, status and time. No arguments or content.

## Tested on the phone (iPhone, iOS 27.2)

| Check | Result |
|---|---|
| Wrong path, root path | plain `404 page not found` |
| Loopback only | A Wi-Fi port forward is refused; only USB forwarding reaches it |
| All ten tools | Work. `launch_app` opens WhatsApp; `read_ui`, `screenshot`, `tap`, `swipe`, `type_text` work in WhatsApp and in search |
| Refusals | Non-allowlisted bundle id, foreign URL, edge swipes: refused before touching the phone |
| Safari in front | Every guarded tool returns only the locked message; no app name, no image |
| App switcher in front | Locked out (after the home-screen check was added) |
| `go_home` | About 1.9 s from Safari or WhatsApp to a verified home screen |
| Runner log | Tool name and status only; typed text and the secret do not appear |
| Guard overhead | 40 to 100 ms per call in an app; about 450 ms more on the home screen |

What the phone test changed:

- **The app switcher leaked.** iCTRL reports it as SpringBoard, so the first
  build treated it as home and returned a screenshot of other apps' previews.
  Fixed by the home-screen check above.
- **`go_home` no longer uses the bottom-edge swipe.** That gesture is fast but
  can stop in the app switcher. It now brings SpringBoard forward as an app,
  then falls back to the Home button, and stops as soon as something
  permitted is in front.
- **Search will not close.** Neither method dismisses the iOS 27 search
  screen. Since search is permitted, `go_home` reports "Search is in front"
  instead of failing.

## Known gaps

- **Notification Centre and Control Centre are not yet told apart from the
  home screen**, and neither is an overlay pulled down over an allowlisted
  app. Claude cannot open them (edge swipes are refused), but if the owner
  does, the bridge would read them. Needs their element ids from a device.
- **`go_home` from search does not reach the home screen** (see above). The
  last change, stopping early there, is unit-tested but was not re-run on the
  phone.
- **Typing in WhatsApp is slow**: 12 characters took 26 s inside iCTRL's own
  `type` call, and clearing with empty text timed out there. In search the
  same call took 1.3 s. Not a bridge issue, but worth tuning (`via`, `fast`).
- **No way to read the URL yet.** Showing and rotating the connector URL comes
  with Stage 4 and the companion app. Until then a development run uses
  `ICTRL_BRIDGE_DEV_SECRET`.
- **The allowlist is WhatsApp only**, read from the runner's defaults. Editing
  it from the companion app is Stage 5/6.
- **Raw API visibility is not yet forced to "this device only"** while the
  bridge runs. That hook lands with Funnel in Stage 3.

## Trying it

Unit tests:

```bash
cd ClaudeBridge && swift test
```

On a phone (development run from Xcode): add two environment variables to the
iCTRL scheme's Test action, then run the test as usual.

| Variable | Value |
|---|---|
| `ICTRL_BRIDGE` | `1` |
| `ICTRL_BRIDGE_DEV_SECRET` | any string of 32 or more URL-safe characters |

The endpoint is then `http://127.0.0.1:8220/<secret>/mcp` on the phone. From
the Mac, forward the port over USB (`iproxy 18220:8220`) and call
`http://127.0.0.1:18220/<secret>/mcp`. The same run can be started from the
command line with `xcodebuild test-without-building`, passing the variables
with a `TEST_RUNNER_` prefix.
