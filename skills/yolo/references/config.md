# .git/yolo/config

Per-project runtime config, sourced as bash on startup.

## Location

`<project>/.git/yolo/config`. Inside `.git/` so it's untracked, survives `git clean`, and is shared across worktrees (the launcher resolves a worktree's `.git` file back to the original repo).

On first run, `yolo` auto-writes an empty template (unless `--no-config`). `yolo --install-config` prints existing or writes the template.

## Variables

All optional. Bash file → any bash syntax works.

| Variable | Type | Default | Effect |
|---|---|---|---|
| `YOLO_PODMAN_VOLUMES` | array | `()` | Extra mounts (each through `expand_volume`). |
| `YOLO_PODMAN_OPTIONS` | array | `()` | Args prepended to `podman run`. |
| `YOLO_CLAUDE_ARGS` | array | `()` | Args prepended to claude (after `--dangerously-skip-permissions`). |
| `USE_ANONYMIZED_PATHS` | 0/1 | 0 | Mount `$HOME/.claude`→`/claude` and `$(pwd)`→`/workspace`. |
| `USE_NVIDIA` | 0/1 | 0 | Enable `--nvidia`. |
| `WORKTREE_MODE` | `ask`/`bind`/`skip`/`error` | `ask` | Default for `--worktree=`. |

Precedence (highest wins): CLI args after `--` → CLI args before `--` → config arrays → defaults. `--no-config` skips the file (and auto-creation).

## Volume shorthand

| Input | Expands to |
|---|---|
| `"~/projects"` | `<HOME>/projects:<HOME>/projects:z` |
| `"~/data::ro"` | `<HOME>/data:<HOME>/data:ro,z` |
| `"/host:/container"` | `/host:/container:z` |
| `"/host:/container:ro,z"` | unchanged |

`~` → `$HOME`. `:z` added when no options. `::ro` = read-only same-path.

Use `+=` (not `=`) when appending; `=` resets the array.

## Common patterns

```bash
# Add a mount
YOLO_PODMAN_VOLUMES+=("~/datasets::ro")

# Switch model (CLI claude args after `--` override this)
YOLO_CLAUDE_ARGS=("--model=claude-opus-4-7")

# Anonymized paths — share `claude --continue` context across repos
USE_ANONYMIZED_PATHS=1

# GPU
USE_NVIDIA=1
YOLO_PODMAN_OPTIONS+=("--shm-size=8g")

# Skip worktree prompts (config lives in the *original* repo's .git/yolo/config)
WORKTREE_MODE="bind"   # or "skip"

# SSH key access (security trade-off — prompt-injected code could read keys)
YOLO_PODMAN_VOLUMES+=("$HOME/.ssh::ro")

# Env vars (by name forwards host value; literal also works)
YOLO_PODMAN_OPTIONS+=("--env=HF_TOKEN" "--env=HF_HOME=$HOME/.cache/huggingface")

# Resource limits
YOLO_PODMAN_OPTIONS+=("--memory=16g" "--cpus=4")

# Host networking (reaches localhost services; undoes some isolation)
YOLO_PODMAN_OPTIONS+=("--network=host")
```

### Skip the on-start `claude update`

Per-run: `yolo --entrypoint=claude` (cleanest — bypasses `entrypoint.sh` and tini).

Permanent in config (also bypasses tini PID 1, so unmanaged children may leak):

```bash
YOLO_PODMAN_OPTIONS+=("--entrypoint=/usr/bin/claude")
```
