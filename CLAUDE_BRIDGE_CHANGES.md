# Claude Bridge: changes to upstream files

This fork adds a "Claude via Funnel" bridge to iCTRL. Almost all of it lives in
new files that upstream does not know about. This file lists **every edit to a
file that upstream owns**, so a merge conflict can be resolved by re-applying a
known, small change.

Rules for this list:

- Every edit to an upstream file is marked in the code with `CLAUDE-BRIDGE HOOK`.
- `git grep -n "CLAUDE-BRIDGE HOOK" -- . ':!ClaudeBridge' ':!CLAUDE_BRIDGE_CHANGES.md'`
  must match the table below exactly. If it doesn't, one of them is wrong.
- When resolving a conflict: take upstream's version of the surrounding code,
  then re-apply the marked line(s).

## Upstream files touched

| File | Hook | Why |
|---|---|---|
| _none yet_ | | Stage 1 added only new files. |

## New files and folders (no conflict risk)

| Path | What |
|---|---|
| `CLAUDE_BRIDGE_CHANGES.md` | This file. |
| `ClaudeBridge/.gitignore` | Keeps Tailscale keys, tsnet state and secrets out of git. |
| `ClaudeBridge/scripts/sync-upstream.sh` | Fetches upstream and merges a release tag into `claude-bridge`. |
| `ClaudeBridge/scripts/hooks/pre-commit` | Blocks commits that contain a Tailscale key or a connector URL secret. |
| `ClaudeBridge/docs/UPSTREAM_SYNC.md` | The update workflow. |
| `ClaudeBridge/docs/VIABILITY.md` | Stage 1 findings: can tsnet run inside the runner. |

Note: upstream already has a `Scripts/` folder. macOS file systems are
case-insensitive by default, so a top-level `scripts/` would collide with it.
Bridge scripts therefore live in `ClaudeBridge/scripts/`.
