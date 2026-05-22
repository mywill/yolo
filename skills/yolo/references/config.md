# .git/yolo/config

Per-project runtime config, sourced as bash on startup.

## Location

`<project>/.git/yolo/config`. Inside `.git/` so it's untracked, survives `git clean`, and is shared across worktrees (the launcher resolves a worktree's `.git` file back to the original repo).

On first run, `yolo` auto-writes an empty template (unless `--no-config`). `yolo --install-config` prints existing or writes the template.

## Variables

All optional. Bash file → any bash syntax works.

| Variable | Type | Default | Effect |
|---|---|---|---|
| `HARNESS` | string | `claude` | Active harness: `claude` or `opencode`. (`codex` is parsed but currently exits with "planned but not yet enabled"; see `SPEC.md` §10.) Overridden by `--harness=`. |
| `YOLO_PODMAN_VOLUMES` | array | `()` | Extra mounts (each through `expand_volume`). |
| `YOLO_PODMAN_OPTIONS` | array | `()` | Args prepended to `podman run`. |
| `YOLO_HARNESS_ARGS` | array | `()` | Args prepended to the active harness (after its yolo-mode flag). |
| `YOLO_CLAUDE_ARGS` | array | `()` | **Deprecated.** If set, merged into `YOLO_HARNESS_ARGS` with a stderr warning on each invocation. `YOLO_HARNESS_ARGS` wins on conflicts. |
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

`~` → `$HOME`. Yolo auto-appends `,z` (SELinux shared relabel) to the bare-path and `::opt` shorthand forms unless `z` or `Z` is already in the opts list — required for read access on SELinux-enforcing hosts (Fedora/RHEL).

Use `+=` (not `=`) when appending; `=` resets the array.

## Common patterns

```bash
# Pin the harness for this project
HARNESS="opencode"

# Add a mount
YOLO_PODMAN_VOLUMES+=("~/datasets::ro")

# Switch model (CLI args after `--` override this)
YOLO_HARNESS_ARGS=("--model=claude-opus-4-7")

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

> On container start, the entrypoint runs a per-harness self-update (claude
> `claude update`; opencode `curl ... | bash`) with a 120s timeout. Ctrl-C
> aborts it cleanly. To skip entirely: `yolo --entrypoint=<harness>`
> bypasses `entrypoint.sh`. To pin harness versions deterministically,
> build the image with `--build-arg CLAUDE_CODE_VERSION=…` or
> `OPENCODE_VERSION=…`. (`CODEX_VERSION=…` is still accepted as a
> build-arg but currently has no effect since the codex install is
> commented out — see `SPEC.md` §10.)
