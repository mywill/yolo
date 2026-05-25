---
name: yolo
description: Help users install, configure, modify, or troubleshoot yolo — a containerized multi-harness AI coding launcher (claude, opencode; codex planned) using podman with per-project `.yolo/` setup scripts and `.git/yolo/config`. Use for installing yolo (`setup-yolo.sh`, podman version, NVIDIA CDI), switching harness (`--harness=` flag or `HARNESS=` config key), adding `.yolo/` to a project (root vs user stage, rust/python/node/tauri), editing `.git/yolo/config` (volumes, podman options, harness args, worktree mode), and diagnosing failures (missing base image, SSH push, ownership with podman <4.3, GPU not detected, cache not rebuilding).
---

# yolo

`yolo` runs an AI coding harness — `claude` (default) or `opencode` — inside a podman container with the harness's "skip all permission prompts" flag. Isolation is the container, not the harness. The CLI is `yolo` (`~/.local/bin/yolo`); the launcher is one bash file (`bin/yolo`); the prebuilt image is `yolo-base` (FROM `debian:bookworm`, claude + opencode installed).

> **codex is planned but not yet enabled.** `yolo --harness=codex` exits with "planned but not yet enabled" — the launcher knows about it but the install is commented out in `images/Dockerfile`. Re-enable instructions live in `SPEC.md` §10.

## Core invariants

- **Container user**: `agent` (UID 1000), `HOME=/home/agent`. Host UID is remapped via `--userns=keep-id`; podman ≥ 4.3 is needed for clean ownership when host UID ≠ 1000.
- **rw mounts (host → container)**: `$(pwd)` at the same host path, plus the active harness's config dir(s) at fixed `/home/agent/...` targets:
  - claude: `$HOME/.claude → /home/agent/.claude`
  - opencode: `$HOME/.config/opencode → /home/agent/.config/opencode` and `$HOME/.local/share/opencode → /home/agent/.local/share/opencode`
- **ro mounts (both harnesses cross-mount each other's data)**: `$HOME/.claude → /home/agent/.claude` and `$HOME/.agents/skills → /home/agent/.agents/skills` for opencode; `$HOME/.config/opencode → /home/agent/.config/opencode` and `$HOME/.local/share/opencode → /home/agent/.local/share/opencode` for claude. Every harness sees every other harness's config and skills regardless of which is active.
- **ro mount**: `$HOME/.gitconfig` at `/tmp/.gitconfig`.
- **Not mounted**: `~/.ssh`, host root. `git push` over SSH fails by default.
- **Why fixed container paths**: keeps the in-container layout independent of the host `$HOME` (e.g. `/home/alice` vs `/home/bob`). Harnesses that fall back to `$HOME` (opencode) find their data because `$HOME=/home/agent` always.
- **Entrypoint**: `images/entrypoint.sh` runs a per-harness self-update on container start (claude `claude update`; opencode `curl ... | bash`) with a 120s timeout and an INT trap (Ctrl-C aborts cleanly). For opencode the update only fires when the build pin is `latest`; otherwise the pinned version stays put. Then `exec "$@"` under tini. The yolo-mode signal is `--dangerously-skip-permissions` (CLI flag) for claude, and `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` (force-set env var) for opencode.

## Switching harness

Four-tier precedence, highest first:

```bash
yolo --harness=opencode       # 1. CLI flag
```

```ini
# .git/yolo/config
HARNESS="opencode"             # 2. per-project default
```

```bash
HARNESS=opencode yolo          # 3. shell env one-shot
```

Default is `claude` (4). `HARNESS=codex` is accepted by the parser but exits with "planned but not yet enabled" until codex is re-enabled.

`YOLO_HARNESS_ARGS` in config applies to whichever harness is active. `YOLO_CLAUDE_ARGS` is **deprecated** — if set, contents merge into `YOLO_HARNESS_ARGS` and a stderr warning is printed on each invocation.

## Navigator

- **Install on this machine** → [`references/install.md`](references/install.md)
- **Add yolo to a project / need rust/python/node here** → [`references/project-setup.md`](references/project-setup.md)
- **Create or edit `.git/yolo/config`** → [`references/config.md`](references/config.md)
- **Something's broken** → [`references/troubleshooting.md`](references/troubleshooting.md)
- **What's mounted / runtime environment** → [`references/runtime-model.md`](references/runtime-model.md)
