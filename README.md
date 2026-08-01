# yolo — containerized AI coding harnesses

Run **claude**, **opencode**, or **pi** inside a podman container with permission prompts skipped. One launcher, one image (`yolo-base`), interchangeable harnesses. (**codex** is planned but not yet enabled in this build — see "Planned" below.)

The container is the isolation boundary, not the harness. The harness's "skip all permission prompts" flag is injected automatically.

## Install

Requires podman ≥ 4.3 (ownership round-trips cleanly for any host UID). On podman < 4.3 yolo falls back to `--user=` form; clean ownership only when host UID is 1000.

```bash
git clone https://github.com/con/yolo
cd yolo
./setup-yolo.sh
```

`setup-yolo.sh` builds `yolo-base` (claude + opencode + pi pre-installed; codex deferred), installs `yolo` to `~/.local/bin`, and installs the yolo skill to `~/.claude/skills/yolo/` and `~/.agents/skills/yolo/`. Ensure `~/.local/bin` is on `$PATH`.

Flags: `--build=auto|yes|no`, `--install=auto|yes|no`. Idempotent.

## Harnesses

| Harness    | Yolo-mode signal                                             | Host config dir(s)                                              | Default auth env vars forwarded                                                               |
| ---------- | ------------------------------------------------------------ | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `claude`   | CLI flag `--dangerously-skip-permissions`                    | `~/.claude`                                                     | `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`                             |
| `opencode` | env `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` (force-set) | `~/.config/opencode`, `~/.local/share/opencode`                 | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `GEMINI_API_KEY` |
| `pi`       | (none — container is the boundary)                           | `~/.pi/agent`                                                   | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `GEMINI_API_KEY` |
| `hermes`   | CLI flag `--yolo`                                            | `~/.hermes`                                                     | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GOOGLE_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, `DEEPSEEK_API_KEY`, `MISTRAL_API_KEY`, `HF_TOKEN` |

"Forwarded" means `-e VAR` with no value — podman picks up the host value. Export the keys on your host; they appear inside the container.

### opencode: terminal copy/paste

opencode's TUI captures mouse events by default, which blocks native terminal text selection and copy. `setup-yolo.sh` checks `~/.config/opencode/tui.json` on each interactive run and reports status with colored output:

- **Missing file** → offers to create one with `"mouse": false` (interactive prompt).
- **File present with `"mouse": false`** → green `✓` confirmation.
- **File present without `"mouse": false`** → yellow `⚠` warning showing the exact line to add.

To configure manually:

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "mouse": false
}
```

Colors honour `NO_COLOR=1` and auto-disable when stdout isn't a TTY (e.g. piping setup output to a file).

### Planned: codex

The codex (OpenAI Codex CLI) harness is plumbed end-to-end but deferred in this build. `yolo --harness=codex` exits with a "planned but not yet enabled" message. The hold-up: codex is npm-distributed and required `npm config set prefix` in `~/.npmrc`, which collides with `nvm` in `.yolo/user-setup.sh`. Re-enabling means uncommenting one block in `images/Dockerfile`, one branch in `bin/yolo`'s `select_harness()`, and one case in `images/entrypoint.sh` — all flagged in-file.

## Usage

```bash
yolo                          # claude (default harness)
yolo --harness=opencode
yolo --harness=pi
yolo --harness=hermes
# yolo --harness=codex        # planned, not yet enabled
yolo --rebuild                # force rebuild of the project's derived image
yolo --last-image             # use previous project image as fallback
yolo --prune                  # prune stopped containers, unused images
yolo --nvidia                 # GPU passthrough via CDI
yolo -- "help with this code" # pass args to the harness
```

Pin a per-project default in `.git/yolo/config`:

```bash
HARNESS="opencode"
```

Precedence (highest wins): `--harness=` flag → `HARNESS=` in config → `HARNESS` env var → default `claude`.

Harness config dirs land at fixed `/home/agent/...` paths inside the container (the container user is `agent`, UID 1000) regardless of your host `$HOME`. The workspace mount preserves your host path on both sides so session resume (`claude --continue` and the opencode equivalent) interops between containerized and native runs.

## Mixing podman flags and harness args

Tokens before `--` that aren't recognized yolo flags go to `podman run`. Tokens after `--` go to the harness. **If no `--` is present, everything unrecognized goes to the harness.**

```bash
yolo -v /data:/data -- --model=opus    # podman flag + harness flag (correct)
yolo -- --resume                       # harness-only
yolo -v /data:/data                    # ⚠ no -- → -v leaks to harness; yolo warns
```

yolo prints a stderr warning when it sees a common podman flag (`-v`, `-p`, `-e`, `--volume`, `--publish`, `--env`, `--network`, `--memory`, `--cpus`, `--shm-size`, `--device`) before the implicit boundary. Silence it with `YOLO_NO_AMBIGUOUS_WARN=1`.

## Skills

The [SKILL.md format](https://agentskills.io) is an open standard adopted by claude, opencode, codex, and others. Yolo's bundled skill (`skills/yolo/`) helps agents reason about yolo itself.

Skill discovery (the path the harness reads inside the container):

| Harness  | User-level                                                                                           | Project-level                                             |
| -------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| claude   | `/home/agent/.claude/skills/<name>/SKILL.md`                                                         | `.claude/skills/<name>/SKILL.md` (walks up)               |
| opencode | `/home/agent/.config/opencode/skills/`, `/home/agent/.claude/skills/`, `/home/agent/.agents/skills/` | `.opencode/skills/`, `.claude/skills/`, `.agents/skills/` |

On the host, `setup-yolo.sh` installs the yolo skill to **both** `~/.claude/skills/yolo/` and `~/.agents/skills/yolo/`. The launcher binds the host's `~/.claude/skills` and `~/.agents/skills` into the opencode container (read-only) at the matching `/home/agent/...` targets. Claude already has `~/.claude` fully mounted (rw) at `/home/agent/.claude`; no extra mount is added there. (Both bind mounts are kept in place so re-enabling codex picks up the same skill paths.)

## Per-project setup (`.yolo/`)

A `.yolo/` directory at the project root customizes the derived image with project-specific dependencies:

```
your-project/
  .yolo/
    root-setup.sh   # runs as root during image build (apt-get, etc.)
    user-setup.sh   # runs as 'agent' user (rustup, nvm, uv, etc.)
```

Both files optional. yolo hashes their contents + the base image ID and builds
a derived `yolo-<project>-<hash12>` image on first use. Cached on subsequent
runs; `--rebuild` forces a rebuild.

After each build, only the 2 most recent images for the project are kept;
older ones are removed automatically. Use `--last-image` to run the previous
image as a fallback if setup script changes break something.

The `.yolo/` contract is harness-independent — the same derived image is
reused across all enabled harnesses (and across codex too, once it's re-enabled).

Templates: `images/examples/` (rust, python, node, tauri, full).

## Cleanup

yolo manages disk usage automatically and provides manual cleanup via
`--prune`.

### Automatic

- **Pre-run container cleanup**: Before each `yolo` invocation, any stopped
  containers from previous runs in the same project directory are removed.
  This handles cases where the container wasn't cleaned up by `--rm`
  (e.g., unclean disconnect, podman crash).
- **Post-build image pruning**: After building a new derived
  `yolo-<project>-<hash12>` image, yolo keeps only the 2 most recent
  images for the project and removes older ones. This prevents
  accumulation as `.yolo/` scripts change over time.

### Manual

`yolo --prune` exits immediately after cleaning:

- All stopped yolo containers
- All unused `yolo-*` images (excluding `yolo-base`)
- All dangling image layers

### Fallback

`yolo --last-image` uses the second-most-recent derived image instead of
building a new one. Useful when `.yolo/` script changes break the
environment — you can run with the previous image while fixing the scripts.

## Project config (`.git/yolo/config`)

Sourced as bash on every run. Auto-created on first run in a git repo. Run `yolo --install-config` to view or create manually.

| Variable              | Type   | Default  | Effect                                                                                                                                          |
| --------------------- | ------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `HARNESS`             | string | `claude` | Selects harness (`claude`, `opencode`, or `pi`; codex planned). Overridden by `--harness=`.                                                            |
| `YOLO_PODMAN_VOLUMES` | array  | `()`     | Extra mounts. Each entry passes through `expand_volume`.                                                                                        |
| `YOLO_PODMAN_OPTIONS` | array  | `()`     | Prepended to `podman run` args.                                                                                                                 |
| `YOLO_HARNESS_ARGS`   | array  | `()`     | Prepended to the active harness's args.                                                                                                         |
| `YOLO_CLAUDE_ARGS`    | array  | `()`     | **Deprecated.** Merged into `YOLO_HARNESS_ARGS` if set, with a stderr warning printed on each invocation. `YOLO_HARNESS_ARGS` wins on conflict. |
| `USE_NVIDIA`          | 0/1    | 0        | Default for `--nvidia`.                                                                                                                         |
| `WORKTREE_MODE`       | string | `ask`    | Default for `--worktree=`. `ask`/`bind`/`skip`/`error`.                                                                                         |

Volume shorthand (`expand_volume`):

| Input                   | Expands to                          |
| ----------------------- | ----------------------------------- |
| `~/projects`            | `<HOME>/projects:<HOME>/projects:z` |
| `~/data::ro`            | `<HOME>/data:<HOME>/data:ro,z`      |
| `/host:/container`      | `/host:/container:z`                |
| `/host:/container:ro,z` | unchanged                           |

`+=` to append. `=` to reset. CLI flags override config. `--no-config` skips the file.

## NVIDIA GPU

`--nvidia` adds `--device nvidia.com/gpu=all --security-opt label=disable`. Requires nvidia-container-toolkit on the host. Generate a CDI spec once:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

Missing CDI → warning, no GPU.

## Git worktrees

When `$(pwd)` is a worktree, yolo resolves the original repo from the `gitdir:` pointer. Modes:

| Mode            | Behavior                                                                   |
| --------------- | -------------------------------------------------------------------------- |
| `ask` (default) | Prompt; on `y`, bind-mount the original repo.                              |
| `bind`          | Always bind-mount the original repo.                                       |
| `skip`          | Continue without binding. Git ops needing original-repo metadata may fail. |
| `error`         | Exit non-zero.                                                             |

Bind-mounting exposes more files. Trade off against your need for git fetch/push.

## Security

Permission prompts are skipped _inside_ the container; the container is the isolation layer.

Accessible by default: active harness's host config dir(s) (rw), `$HOME/.gitconfig` (ro), `$(pwd)` (rw), bound original repo (worktree), any `YOLO_PODMAN_VOLUMES` or CLI `-v`, outbound network.

Not accessible: `~/.ssh`, other credential dirs, host root, inbound network.

`git push` over SSH fails by design (no SSH keys mounted). Workaround: commit in container, push from host; mount keys explicitly; or use HTTPS + token in `~/.gitconfig`.

Prompt-injection in untrusted project code can attempt to coerce the harness. The mount surface bounds what it can touch. Mounting extra credentials expands the attack surface.

## Manual podman invocation

If you'd rather not install the launcher, the same effect for each harness:

```bash
# Claude
podman run -it --rm --userns=keep-id:uid=1000,gid=1000 \
  -v "$HOME/.claude:/home/agent/.claude:z" \
  -v "$HOME/.gitconfig:/tmp/.gitconfig:ro,z" \
  -v "$(pwd):$(pwd):z" -w "$(pwd)" \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude \
  -e GIT_CONFIG_GLOBAL=/tmp/.gitconfig \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
  -e YOLO_HARNESS=claude \
  yolo-base \
  claude --dangerously-skip-permissions

# OpenCode
podman run -it --rm --userns=keep-id:uid=1000,gid=1000 \
  -v "$HOME/.config/opencode:/home/agent/.config/opencode:z" \
  -v "$HOME/.local/share/opencode:/home/agent/.local/share/opencode:z" \
  -v "$HOME/.claude/skills:/home/agent/.claude/skills:ro,z" \
  -v "$HOME/.agents/skills:/home/agent/.agents/skills:ro,z" \
  -v "$HOME/.gitconfig:/tmp/.gitconfig:ro,z" \
  -v "$(pwd):$(pwd):z" -w "$(pwd)" \
  -e GIT_CONFIG_GLOBAL=/tmp/.gitconfig \
  -e OPENAI_API_KEY \
  -e ANTHROPIC_API_KEY \
  -e OPENROUTER_API_KEY \
  -e GROQ_API_KEY \
  -e GEMINI_API_KEY \
  -e OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true \
  -e YOLO_HARNESS=opencode \
  yolo-base \
  opencode
```

`--userns=keep-id:uid=1000,gid=1000` needs podman ≥ 4.3. On older podman use `--user="$(id -u):$(id -g)" --userns=keep-id`.

## Upgrading

The container user was renamed `claude` → `agent` and container mount paths moved under `/home/agent/...`. After pulling, rebuild the base image:

```bash
./setup-yolo.sh --build=yes
```

The setup script offers to remove orphaned `yolo-<hash>` derived images built against the previous base. On-disk session data is unchanged — both before and after, the underlying directory on the host is the same `~/.claude/` (etc.); only the container-side mount label moved. `claude --continue` still finds existing sessions because the workspace path is unchanged.

`USE_ANONYMIZED_PATHS` was removed (silently ignored if still set in old configs); the `--anonymized-paths` CLI flag is consumed and a stderr deprecation note is printed. The `YOLO_CLAUDE_ARGS` config variable is deprecated; if set, its contents are merged into `YOLO_HARNESS_ARGS` and a stderr warning is printed on each invocation. Rename in your `.git/yolo/config` to silence it.

## Reference

- `SPEC.md` — contract (flags, mounts, env vars, profile fields).
- `bin/yolo --help` — CLI reference.
- `skills/yolo/SKILL.md` — bundled skill source.
- [agentskills.io](https://agentskills.io) — SKILL.md format spec.
