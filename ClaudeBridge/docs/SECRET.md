# Stage 4: the URL secret and rotation

Status on 2026-11-10: built, unit-tested on the Mac, and both apps compile.
**Not yet run on a phone, and the companion screen has not been looked at on
a device.**

## The address

```
https://<fixed-hostname>.<tailnet>.ts.net/<secret>/mcp
```

- The host name is fixed (`ictrl-phone` by default). Only `<secret>` changes.
- The secret is 32 random bytes (256 bits) from the system RNG, base64url, 43
  characters. It is created the first time the bridge starts.
- It is stored in the runner's keychain (`AfterFirstUnlockThisDeviceOnly`)
  and nowhere else.

## The check

`BridgePathSecretAuthenticator` (in `ClaudeBridge/Core/BridgeAuth.swift`):

- Reads the current secret on every request, so a rotation applies to the
  next request with no restart.
- Compares in constant time, and compares even when the path has the wrong
  shape, so timing does not reveal which part was wrong.
- Anything that fails gets the same plain `404 page not found`: wrong secret,
  wrong path, malformed request, oversized body, or the MCP listener being
  down. There is no `WWW-Authenticate` header and no JSON, so nothing hints
  that an MCP server is there.
- A stored secret shorter than 32 characters is never accepted.

The check is one small protocol (`BridgeAuthenticator`). Two more
implementations can be swapped in without touching the server:

- `BridgePathAndBearerAuthenticator` (already written and tested): path
  secret plus a static `Authorization: Bearer …` header, for Claude accounts
  that have the connector "Request headers" option.
- OAuth 2.1 per the MCP authorization spec (not written).

## Rotation

In the companion app: **Settings → Claude Bridge → Rotate secret**. It asks for
confirmation, then:

1. the runner generates a new secret and replaces the old one in its
   keychain;
2. the old address returns 404 from the next request on;
3. the new address is put on the clipboard, ready to paste into the Claude
   connector (remove the old connector's URL and set the new one).

## Where the secret can and cannot appear

| Place | Secret present? |
|---|---|
| Companion screen | No. The address is drawn as `https://host/••••••••/mcp`. A screenshot or screen recording of it shows dots. |
| Companion app memory | Only for the moment between the runner's reply and the clipboard write. It is not kept in view state. |
| Clipboard | Yes, after Copy or Rotate: marked local-only (no Universal Clipboard) and set to expire after 2 minutes. |
| Runner log, `logs` RPC, GET /logs | No. The bridge logs "secret rotated" and tool names, never a path. iCTRL's request log only prints a fixed list of parameter names, none of which the bridge uses for secrets. |
| Go / Tailscale side | No logging at all; tsnet's own logs are discarded and log upload is disabled. Funnel relays see TLS ciphertext only. |
| MCP tools | No. No tool returns it, and `phone_status` reports no host or address. |
| Crash reports | Not written anywhere by the bridge. It is held in memory in the runner (a cache of the keychain value), which a crash report does not dump. |
| Git | No. Secrets never touch the Mac except a development secret you choose for a debug run; the pre-commit hook refuses anything shaped like an address with a secret. |

One thing to be aware of: if the companion app itself were put on the
allowlist, Claude could open it and tap Copy. It still could not read the
secret from the screen, and pasting it somewhere would need another
allowlisted app with a text field. Simplest is not to allowlist the iCTRL app.

## How the companion talks to the runner

A new method, `claude_bridge`, on iCTRL's existing paired and encrypted
loopback channel (the one the companion already uses for `config`). Actions:
`status`, `set_mode`, `connector_url`, `rotate_secret`, `set_auth_key`,
`action_log`.

It is not an MCP tool and is not reachable through Funnel. Any client paired
with the raw API can call it, and such a client already has full control of
the phone. In Funnel mode the raw API is loopback-only, so that means apps on
the phone and a computer over USB.

`set_mode` takes effect at once: turning Funnel on starts the bridge and the
tunnel and forces the raw API back to loopback; turning it off stops both.
The choice is remembered for the next time the runner starts.
