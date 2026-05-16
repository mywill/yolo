# Troubleshooting yolo

## Quick lookup

| Symptom | Cause | Fix |
|---|---|---|
| `Base image 'con-bomination-claude-code' not found` | base image missing | `cd <yolo-repo> && ./setup-yolo.sh` |
| `git push` fails: `Permission denied (publickey)` | `~/.ssh` not mounted (by design) | commit in container, push from host — or mount keys (see below) |
| Files in mounted dirs owned by weird UID | podman <4.3 with host UID ≠ 1000 | upgrade podman to ≥4.3 |
| `--nvidia` warning: CDI spec not found | toolkit missing or spec not generated | `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` |
| Worktree prompt every run | `WORKTREE_MODE` unset | set `WORKTREE_MODE=bind` or `skip` in `.git/yolo/config` |
| Script changes not picked up | cached derived image | `yolo --rebuild` |
| Config seems ignored | `--no-config` set, wrong gitdir, or typo'd var | see "Config ignored" below |
| `yolo` not found | `~/.local/bin` not in `$PATH` | add to shell rc |
| Image rebuilds every run | base image ID changed | expected — hash includes base ID |
| `claude update` hangs at startup | network slow | Ctrl-C (prints "Update skipped.") or `yolo --entrypoint=claude` |
| Container name collision | leftover container | `podman rm <name>` |
| Permission denied writing mounted dir | host file not owned by you | `sudo chown $USER:$USER <dir>` |

## `git push` over SSH

Three options:

1. **Commit in container, push from host** (cleanest).
2. **Mount keys** in `.git/yolo/config`: `YOLO_PODMAN_VOLUMES+=("$HOME/.ssh::ro")`. Prompt-injected project code could read keys — deliberate, trusted repos only.
3. **HTTPS + token** via `credential.helper` in `~/.gitconfig` (mounted ro).

## Config ignored

Check, in order:

- `--no-config` somewhere (CLI, alias, env).
- Worktree gitdir: config lives in the **original repo's** `.git/yolo/config`, not the worktree's `.git` file. Launcher resolves the `gitdir:` line automatically.
- Variable typo. Only `YOLO_PODMAN_VOLUMES`, `YOLO_PODMAN_OPTIONS`, `YOLO_CLAUDE_ARGS`, `USE_ANONYMIZED_PATHS`, `USE_NVIDIA`, `WORKTREE_MODE` are recognized.
- `=` resets, `+=` appends. Last `=` wins.

Debug:

```bash
bash -c 'source .git/yolo/config; declare -p YOLO_PODMAN_VOLUMES YOLO_PODMAN_OPTIONS YOLO_CLAUDE_ARGS USE_ANONYMIZED_PATHS USE_NVIDIA WORKTREE_MODE'
```

## When all else fails

Isolate launcher vs. container by running podman directly:

```bash
podman run -it --rm \
  --userns=keep-id:uid=1000,gid=1000 \
  -v "$HOME/.claude:$HOME/.claude:z" \
  -v "$HOME/.gitconfig:/tmp/.gitconfig:ro,z" \
  -v "$(pwd):$(pwd):z" \
  -w "$(pwd)" \
  -e CLAUDE_CONFIG_DIR="$HOME/.claude" \
  -e GIT_CONFIG_GLOBAL=/tmp/.gitconfig \
  con-bomination-claude-code \
  bash
```

Works but `yolo` doesn't → issue in `bin/yolo`. Also fails → image or podman setup.
