# Stage 2: the MCP layer on localhost

Status on 2026-11-10: built, unit-tested on the Mac (43 tests), and compiled
into the runner for iOS. **Not yet run on a phone.**

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
| `go_home` | works | Presses Home. The way out of lockout. |
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
  (`device_info`). Home screen or allowlisted app: proceed. Anything else,
  including an app the runner cannot name: lockout.
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

## Known gaps, by design for this stage

- **SpringBoard is treated as "home".** iCTRL reports Control Centre,
  Notification Centre, the app switcher and system alerts as SpringBoard too.
  The swipe edge rule keeps Claude from opening them, but if the owner opens
  one, the bridge would currently read it. Telling them apart is Stage 5.
- **No way to read the URL yet.** Showing and rotating the connector URL comes
  with Stage 4 and the companion app. Until then a development run uses
  `ICTRL_BRIDGE_DEV_SECRET`.
- **The allowlist is WhatsApp only**, read from the runner's defaults. Editing
  it from the companion app is Stage 5/6.
- **Two `device_info` calls per action** add latency. A cheaper foreground
  probe can replace them once the behaviour is confirmed on a device.
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

The endpoint is then `http://127.0.0.1:8220/<secret>/mcp` on the phone,
reachable from the Mac through a USB port forward of port 8220.
