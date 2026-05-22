# Troubleshooting yolo

## Quick lookup

| Symptom | Cause | Fix |
|---|---|---|
| `Base image 'yolo-base' not found` | prebuilt image missing | `cd <yolo-repo> && ./setup-yolo.sh` |
| `Unknown harness 'foo'` | `--harness=` value not in `{claude, opencode}` | typo, or that harness isn't installed in the image |
| `codex harness is planned but not yet enabled` | `--harness=codex` (or `HARNESS=codex` in config / env) on a build where codex is still deferred | use `--harness=claude` or `--harness=opencode`; to re-enable codex, follow `SPEC.md` §10 |
| Old `con-bomination-claude-code` tag still on disk | legacy from before the rename | `./setup-yolo.sh` offers to remove it after a build, or `podman rmi con-bomination-claude-code` manually |
| Old derived `yolo-<hash>` tags after an upgrade | base image ID changed; cached derivations are stale | `./setup-yolo.sh` offers to prune them; or `podman rmi yolo-<hash>` |
| `git push` fails: `Permission denied (publickey)` | `~/.ssh` not mounted (by design) | commit in container, push from host — or mount keys (see below) |
| Files in mounted dirs owned by weird UID | podman <4.3 with host UID ≠ 1000 | upgrade podman to ≥4.3 |
| `--nvidia` warning: CDI spec not found | toolkit missing or spec not generated | `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` |
| Worktree prompt every run | `WORKTREE_MODE` unset | set `WORKTREE_MODE=bind` or `skip` in `.git/yolo/config` |
| Script changes not picked up | cached derived image | `yolo --rebuild` |
| Config seems ignored | `--no-config` set, wrong gitdir, or typo'd var | see "Config ignored" below |
| `yolo` not found | `~/.local/bin` not in `$PATH` | add to shell rc |
| Image rebuilds every run | base image ID changed | expected — hash includes base ID |
| Harness opens but auth missing | required env var not exported on host | `export OPENAI_API_KEY=…` (etc.) and rerun; yolo forwards by name |
| opencode config not found / fresh session each run | upgrading from an old yolo before the agent-user rename | rebuild the base image (`./setup-yolo.sh --build=yes`); container paths are now `/home/agent/...` and don't depend on host `$HOME` |
| `YOLO_CLAUDE_ARGS is deprecated` warning at startup | legacy config variable name | rename `YOLO_CLAUDE_ARGS` → `YOLO_HARNESS_ARGS` in `.git/yolo/config`; old value still applies until renamed |
| `yolo --anonymized-paths` prints a deprecation note | flag was removed in the multi-harness refactor; yolo now consumes the token and warns on stderr | drop the flag — harness config paths are now always fixed under `/home/agent/...`, workspace stays at host path |
| Update on container start hangs / is slow | `claude update` / opencode install pulling from network | Ctrl-C aborts cleanly (prints "Update skipped."), or `yolo --entrypoint=<harness>` bypasses the entrypoint entirely. For opencode, pinning a non-`latest` version at build time (`--build-arg OPENCODE_VERSION=…`) also skips the runtime update. |
| Yolo skill not visible inside opencode | skill installed in **neither** `~/.claude/skills/yolo/` nor `~/.agents/skills/yolo/` (opencode reads both via read-only mounts into the container) | re-run `setup-yolo.sh --install=yes`; it installs to both paths. Verify with `ls ~/.claude/skills/yolo ~/.agents/skills/yolo` on the host. |
| Yolo skill not visible inside claude | `~/.claude/skills/yolo/` missing on host | re-run `setup-yolo.sh --install=yes` |
| Warning `'-v ...' looks like a podman flag` | passing podman args without `--` separator | add `--` between podman flags and harness args: `yolo -v /data:/data -- --resume`. Or silence with `YOLO_NO_AMBIGUOUS_WARN=1`. |
| Can't select/copy text inside opencode | opencode's TUI captures mouse events by default | add `"mouse": false` to `~/.config/opencode/tui.json`. `setup-yolo.sh` offers to create the file on first interactive run and prints a colored ✓/⚠ status on subsequent runs. See README §`opencode: terminal copy/paste`. |
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
- Variable typo. Only `HARNESS`, `YOLO_PODMAN_VOLUMES`, `YOLO_PODMAN_OPTIONS`, `YOLO_HARNESS_ARGS`, `YOLO_CLAUDE_ARGS` (deprecated), `USE_NVIDIA`, `WORKTREE_MODE` are recognized. `USE_ANONYMIZED_PATHS` was removed and is silently ignored.
- `=` resets, `+=` appends. Last `=` wins.

Debug:

```bash
bash -c 'source .git/yolo/config; declare -p HARNESS YOLO_PODMAN_VOLUMES YOLO_PODMAN_OPTIONS YOLO_HARNESS_ARGS YOLO_CLAUDE_ARGS USE_NVIDIA WORKTREE_MODE'
```

## When all else fails

Isolate launcher vs. container by running podman directly:

```bash
podman run -it --rm \
  --userns=keep-id:uid=1000,gid=1000 \
  -v "$HOME/.claude:/home/agent/.claude:z" \
  -v "$HOME/.gitconfig:/tmp/.gitconfig:ro,z" \
  -v "$(pwd):$(pwd):z" \
  -w "$(pwd)" \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude \
  -e GIT_CONFIG_GLOBAL=/tmp/.gitconfig \
  yolo-base \
  bash
```

Works but `yolo` doesn't → issue in `bin/yolo`. Also fails → image or podman setup.
