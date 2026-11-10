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
| `read_ui` | refused | UI tree with frames. Starts with the scroll position (how far down, how much content above and below). Optional `filter_text`; `include_offscreen` also lists elements loaded beyond the screen edges. |
| `scroll` | refused | Precise scrolling without momentum: `direction` plus `pages` (a fraction of a screen) or `points`; optional `x`,`y` to scroll one area. Reports whether it moved and the new position. |
| `scroll_to` | refused | Brings an element into view by label or identifier and returns its tap point. |
| `tap_element` | refused | Taps an element by label or identifier wherever it is: scrolls it into view first if it is off screen, waits for the list to stop, then taps. `occurrence` picks among duplicates. |
| `tap` | refused | x, y in points. |
| `swipe` | refused | Low-level gesture (pull to refresh, swipe a row). Refuses starts within 40 pt of the top edge or 50 pt of the bottom edge (system gestures). |
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
| Control Centre, over the home screen or over WhatsApp | Locked out. iOS makes SpringBoard the front app while it is open, and the icon grid is not visible, so the home-screen check fails |
| Notification Centre, over the home screen or over WhatsApp | Refused as `phone locked`. iOS reports the screen as locked while that sheet is down |
| Keep-awake (first version, a bottom-edge tap) | Held a 30 s Auto-Lock for 19 minutes, but the taps hit real controls; replaced by a key event that is not yet verified (see FUNNEL.md) |
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

- **`go_home` from search does not reach the home screen** (see above). The
  last change, stopping early there, takes 2.3 s on the phone.
- **Typing in WhatsApp is slow**: 12 characters took 26 s inside iCTRL's own
  `type` call, and clearing with empty text timed out there. In search the
  same call took 1.3 s. Not a bridge issue, but worth tuning (`via`, `fast`).
- **No way to read the URL yet.** Showing and rotating the connector URL comes
  with Stage 4 and the companion app. Until then a development run uses
  `ICTRL_BRIDGE_DEV_SECRET`.
- **Read-only apps block typing only.** Taps on send buttons are not detected.
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

## Finding markers on a new iOS version

Run with `ICTRL_BRIDGE_DIAG=1`. Every two seconds the runner logs which app is
in front, the lock flag and the element ids in SpringBoard's visible tree
(identifiers only, never labels), whenever they change. Open each surface for
a few seconds and read the log. On iOS 27.2 that showed:

| Screen | Front app | Lock flag | Telling ids |
|---|---|---|---|
| Home screen | SpringBoard | false | `Home screen icons` |
| App switcher | SpringBoard | false | `AppSwitcherContentView`, `SBSwitcherWindow:Main` |
| Control Centre (anywhere) | SpringBoard | false | `cc-root-folder-view`, no icon grid |
| Notification Centre (anywhere) | SpringBoard | **true** | `NotificationShortLookView` |
| Pull-down search | `com.apple.campo` | false | |
| An app | that app | false | |

## The allowlist

Edited in the companion app: Claude Bridge → Allowed apps. The screen lists
the installed apps, each with a switch; an allowed app also gets a read-only
switch. The list is stored in the runner and read fresh on every tool call,
so a change applies immediately. It is changed through the companion's
`claude_bridge` method (`set_allowlist`), never through MCP.

**It starts empty.** Until an app is switched on, Claude can only see the home
screen and search. No app is special in the code: WhatsApp is one row like any
other.

### Where the list of installed apps comes from

iOS has no public way to list installed apps and refuses the usual private
ones. Measured on iOS 27.2:

| Route | Apps found |
|---|---|
| `LSApplicationWorkspace` (all applications) | 0 |
| `LSApplicationRecord` enumeration | 0 |
| Apps that contain an extension (via the plug-in list) | 198 |
| Apps this runner has opened before | 11 |

The screen shows the last two combined. Most apps include at least one
extension, but one that does not, and has never been opened through iCTRL,
will be missing; it can be added by bundle id at the bottom of the screen.

### Rules

- Never allowed, and ignored even if stored: Settings, the App Store, Wallet,
  Shortcuts, TestFlight, SpringBoard, and iCTRL's own companion and runner.
- The home screen and system search are always permitted and are not part of
  the list.
- `open_url` only works for apps whose link formats are known
  (`BridgeKnownLinks`: currently WhatsApp, Telegram and Signal) and only when
  that app is on the list. Other apps can still be opened with `launch_app`.
- Read-only blocks typing. Taps on send buttons are not detected.

Not yet tried on a phone.

## Elements, scrolling and coordinates: what real apps needed

Found while driving a food-ordering menu in Grab on iOS 27.2, and fixed in
`BridgeUITree` and `BridgeTools`:

- **Apps that draw at their own size.** Grab draws at 375 x 667 and iOS scales
  it onto the 466 x 678 screen, at the top-left. Its frames are then not tap
  points. `read_ui` converts every frame to screen points and says so.
- **Bogus frames in off-screen rows.** Children of a row that is off screen all
  reported the list's origin as their frame, so iCTRL's own
  `scroll_to_element` decided an item four screens down was already in view.
  The bridge does not use it. It parses the tree, takes the row's own frame
  when a child's frame falls outside its row, and scrolls with exact slow
  drags inside the scrolling view until the element's centre is showing.
- **Taps on a gliding list are swallowed.** After a scroll the bridge re-reads
  until two readings of the element's position agree, then taps.
- **The child limit hid rows.** `page_source` applies `max_children` before
  its on-screen filter, so at 50 the rows past the 50th never appeared, even
  when they were the ones on screen. `read_ui` now asks for 400.

Verified on the phone: `tap_element` selected items one and four screens down
the list, and the basket total changed to match.

Not handled: horizontal scrolling to an element, and lists that only build
rows as you scroll are searched by paging down only (not up).

## Large-display (windowed) mode: what works and what does not

The phone this is developed on has a second, larger display mode. In it iOS
lays the screen out at 669 x 951 points while the runner works at 466 x 678,
iPhone-only apps are shown in a window, and the home screen is drawn by the
system search process ("Siri AI", `com.apple.campo`, the window host), not by
SpringBoard. Found while trying to search Carousell:

| Area | State |
|---|---|
| Which app is in front | **Fixed.** iCTRL named the wrong app (Taobao while Carousell was on screen): it trusts an app's "foreground" state, which lags, and the frontmost process is the window host. The bridge now decides itself (`ClaudeBridgeScreenProbe`, `BridgeForegroundDecision`): a process id must agree, and in windowed mode exactly one known app may claim the foreground. iCTRL's own resolver also got a process-id check (hook in `ActionHandler.swift`). |
| `read_ui` | **Fixed.** It names the app explicitly (the raw API otherwise read the wrong app and timed out after 15 s), and converts frames using the window's real position, read from SpringBoard's tree (`BridgeWindowLocator`). |
| `launch_app`, `screenshot` | Work. |
| `tap`, `tap_element`, `type_text`, `scroll`, `swipe` | **Do not work in this mode.** Synthesized touches take about 5.4 s and have no effect, in either coordinate space. Likely cause, not confirmed: XCTest aims events at the default display, and the content is on the other one (`XCSynthesizedEventRecord` has an `initWithName:displayID:` that upstream does not use). |
| `go_home` | Does not reach a classic home screen; the host's own screen (icons and a search bar) is treated like search, so tools are not locked out there. |

Residual risk in windowed mode: the "exactly one app claims the foreground"
check can only see apps the phone lets the runner list (those with an
extension, or opened through iCTRL before). An app outside that list, shown in
a window while nothing else claims the foreground, would be taken for the
host's own screen.

Tried and discarded: asking iOS which process owns the element at a screen
point. For a windowed app it answers "SpringBoard".

Diagnostics for this work are behind environment variables:
`ICTRL_BRIDGE_DIAG=1` (front app, lock flag, SpringBoard ids, the foreground
decision's inputs), `ICTRL_BRIDGE_DIAG_APPS=1` (per-app state and pid),
`ICTRL_BRIDGE_DIAG_TREES=1` (candidate window frames in SpringBoard's tree).
