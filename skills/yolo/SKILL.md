---
name: yolo
description: Help users install, configure, modify, or troubleshoot yolo — a containerized Claude Code launcher using podman with per-project `.yolo/` setup scripts and `.git/yolo/config`. Use for installing yolo (`setup-yolo.sh`, podman version, NVIDIA CDI), adding `.yolo/` to a project (root vs user stage, rust/python/node/tauri), editing `.git/yolo/config` (volumes, podman options, claude args, worktree mode, anonymized paths), and diagnosing failures (missing base image, SSH push, ownership with podman <4.3, GPU not detected, cache not rebuilding).
---

# yolo

`yolo` runs Claude Code inside a podman container with `--dangerously-skip-permissions`. Isolation is the container, not Claude. The CLI is `yolo` (`~/.local/bin/yolo`); the launcher is one bash file (`bin/yolo`); the base image is `con-bomination-claude-code`.

## Core invariants

- **rw mounts**: `$(pwd)` and `$HOME/.claude` at original host paths (so sessions are compatible with native Claude Code).
- **ro mount**: `$HOME/.gitconfig` at `/tmp/.gitconfig`.
- **Not mounted**: `~/.ssh`, host root. `git push` over SSH fails by default.
- **User**: container `claude` (UID 1000), remapped via `--userns=keep-id`. Podman ≥ 4.3 needed for clean ownership when host UID ≠ 1000.
- **Entrypoint**: `images/entrypoint.sh` runs `claude update` (timeout 120s, Ctrl-C aborts), then `exec claude --dangerously-skip-permissions`.

## Navigator

- **Install on this machine** → [`references/install.md`](references/install.md)
- **Add yolo to a project / need rust/python/node here** → [`references/project-setup.md`](references/project-setup.md)
- **Create or edit `.git/yolo/config`** → [`references/config.md`](references/config.md)
- **Something's broken** → [`references/troubleshooting.md`](references/troubleshooting.md)
- **What's mounted / runtime environment** → [`references/runtime-model.md`](references/runtime-model.md)
