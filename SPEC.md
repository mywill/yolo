# yolo — Specification

Contract document. `README.md` is the tutorial; `tests/yolo.bats` is the
executable spec. On disagreement, the test suite wins.

## 1. Components

| Path                    | Role                                                              |
|-------------------------|-------------------------------------------------------------------|
| `bin/yolo`              | Launcher. Parses flags, resolves the image, runs podman.          |
| `setup-yolo.sh`         | Builds the base image; installs `bin/yolo` to `~/.local/bin/yolo`.|
| `images/Dockerfile`     | Base image `con-bomination-claude-code`.                          |
| `images/entrypoint.sh`  | Runs `claude update` then `exec "$@"`.                            |
| `config.example`        | Template for `.git/yolo/config`.                                  |
| `tests/yolo.bats`       | bats-core test suite.                                             |

## 2. CLI

```
yolo [PODMAN_ARGS...] [FLAGS] [-- CLAUDE_ARGS...]
```

Tokens before `--` that aren't recognized flags pass through to `podman
run`. Tokens after `--` go to `claude`. If no `--` is present, all
unrecognized tokens are treated as `CLAUDE_ARGS`.

| Flag                  | Default  | Effect                                                                                          |
|-----------------------|----------|-------------------------------------------------------------------------------------------------|
| `-h`, `--help`        | —        | Print help, exit 0.                                                                             |
| `--anonymized-paths`  | off      | Mount Claude config at `/claude`, cwd at `/workspace`.                                          |
| `--entrypoint=CMD`    | `claude` | Replace in-container entrypoint. Also accepts `--entrypoint CMD`.                               |
| `--worktree=MODE`     | `ask`    | `MODE` ∈ {`ask`, `bind`, `skip`, `error`}; anything else is a hard error.                       |
| `--nvidia`            | off      | Add `--device nvidia.com/gpu=all --security-opt label=disable`.                                 |
| `--rebuild`           | off      | Force rebuild of the derived image.                                                             |
| `--no-config`         | off      | Skip sourcing `.git/yolo/config` (and skip auto-creation).                                      |
| `--install-config`    | —        | Create `.git/yolo/config` from template if missing; otherwise print existing. Exits 0.          |

`--install-config` and `--help` short-circuit before podman runs.

## 3. Configuration

### Location

`.git/yolo/config`. For worktrees, `.git` is resolved by reading the
`gitdir:` line and stripping `/worktrees/...` to find the original repo.
This directory is not tracked, not destroyed by `git clean`, and shared
across worktrees.

### Auto-creation

On first run inside a git repo (no `--no-config`), `bin/yolo` writes the
template to `.git/yolo/config` and continues. Subsequent runs source it.

### Variables

Sourced as bash. Recognized:

| Variable                | Type    | Effect                                                          |
|-------------------------|---------|-----------------------------------------------------------------|
| `YOLO_PODMAN_VOLUMES`   | array   | Each entry runs through `expand_volume`, added as `-v`.         |
| `YOLO_PODMAN_OPTIONS`   | array   | Prepended to user-supplied podman args.                         |
| `YOLO_CLAUDE_ARGS`      | array   | Prepended to user-supplied claude args.                         |
| `USE_ANONYMIZED_PATHS`  | 0/1     | Default for `--anonymized-paths`.                               |
| `USE_NVIDIA`            | 0/1     | Default for `--nvidia`.                                         |
| `WORKTREE_MODE`         | string  | Default for `--worktree=`.                                      |

CLI flags override config. `--no-config` skips the file entirely.

### Volume shorthand (`expand_volume`)

| Input                       | Expanded                                |
|-----------------------------|-----------------------------------------|
| `~/projects`                | `<HOME>/projects:<HOME>/projects:z`     |
| `~/data::ro,z`              | `<HOME>/data:<HOME>/data:ro,z`          |
| `/host:/container`          | `/host:/container:z`                    |
| `/host:/container:ro,z`     | unchanged                               |

## 4. `.yolo/` contract

### Files

| Path                       | Required |
|----------------------------|----------|
| `.yolo/root-setup.sh`      | no       |
| `.yolo/user-setup.sh`      | no       |

At project root. Both optional. If both absent (or `.yolo/` absent), the
base image is used directly and no derived image is built.

### Build

Base is always `con-bomination-claude-code`. When at least one script
exists, `bin/yolo` generates:

```dockerfile
FROM con-bomination-claude-code

# Only if root-setup.sh exists:
COPY --chmod=755 root-setup.sh /tmp/root-setup.sh
USER root
RUN /tmp/root-setup.sh
RUN rm -f /tmp/root-setup.sh
USER claude

# Only if user-setup.sh exists:
COPY --chmod=755 user-setup.sh /tmp/user-setup.sh
RUN /tmp/user-setup.sh
```

- `root-setup.sh` runs as `USER root`.
- `user-setup.sh` runs as `USER claude` (UID 1000).
- Scripts are located at `/tmp/`. `WORKDIR` at run time is `/workspace`
  (inherited from base), not `/tmp`.
- `root-setup.sh` is deleted between stages; `user-setup.sh` is not.

### Derived image name

```
hash_input  = base_image_id
              [+ "|root|" + contents_of_root-setup.sh   if present]
              [+ "|user|" + contents_of_user-setup.sh   if present]

derived_tag = "yolo-" + (sha256(hash_input) | head -c 12)
```

The `|root|` / `|user|` delimiters ensure identical bytes in different
files produce different hashes (the two scripts run in different stages).
Enforced by `tests/yolo.bats:361–382`.

### Cache and rebuild

- `podman image exists <derived_tag>` and no `--rebuild` → use cache.
- Otherwise → build.
- `--rebuild` forces a rebuild; the tag is content-addressed so the name
  is reused.
- Missing base image → exit non-zero with
  `Base image 'con-bomination-claude-code' not found. Run setup-yolo.sh first.`

## 5. Container runtime

### Default mounts

| Host                  | Container              | Options |
|-----------------------|------------------------|---------|
| `$HOME/.claude`       | `$HOME/.claude`        | `z`     |
| `$HOME/.gitconfig`    | `/tmp/.gitconfig`      | `ro,z`  |
| `$(pwd)`              | `$(pwd)`               | `z`     |
| `<original_repo>`     | `<original_repo>`      | `z`     | (worktree binding only)

`WORKDIR=$(pwd)`. `CLAUDE_CONFIG_DIR=$HOME/.claude`. `$HOME/.claude` is
created on the host if missing.

### `--anonymized-paths` mounts

| Host             | Container          | Options |
|------------------|--------------------|---------|
| `$HOME/.claude`  | `/claude`          | `z`     |
| `$HOME/.gitconfig` | `/tmp/.gitconfig`| `ro,z`  |
| `$(pwd)`         | `/workspace`       | `z`     |

`WORKDIR=/workspace`. `CLAUDE_CONFIG_DIR=/claude`.

### Worktree detection

When `$(pwd)/.git` is a symlink or file, `bin/yolo` resolves the `gitdir:`
line. If it matches `.../.git/worktrees/...`, the original repo is the
parent of the matched `.git`. Modes:

- `ask`: prompt `y/N`; on `y` bind-mount the original repo.
- `bind`: always bind-mount.
- `skip`: continue without bind-mounting.
- `error`: exit non-zero.

### `--userns`

Reads `podman version --format '{{.Client.Version}}'`, strips `-suffix`:

| podman version | Args                                          | Notes                              |
|----------------|-----------------------------------------------|------------------------------------|
| ≥ 4.3.0        | `--userns=keep-id:uid=1000,gid=1000`          | —                                  |
| < 4.3.0        | `--user="$(id -u):$(id -g)" --userns=keep-id` | Warns if host UID ≠ 1000.          |

Unparseable / empty version is treated as < 4.3.

### Env vars forwarded

- `CLAUDE_CONFIG_DIR` — set to in-container Claude config path.
- `GIT_CONFIG_GLOBAL=/tmp/.gitconfig`.
- `CLAUDE_CODE_OAUTH_TOKEN` — passed with `-e` (name only).
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` — same form.

### Other fixed podman flags

`--log-driver=none`, `-it`, `--rm`, synthesized `--name=` (§6).

### NVIDIA

`--nvidia` adds `--device nvidia.com/gpu=all --security-opt label=disable`.
If no CDI spec at `/etc/cdi/nvidia.yaml` or `/var/run/cdi/nvidia.yaml`,
prints a warning to stderr and continues.

## 6. Auto-injected `--name=`

```
name = "$PWD-$$"
     strip leading "$HOME/"
     replace non-[A-Za-z0-9_.-] with "_"
     strip leading "."s and "_"s
```

Passed to podman as `--name=$name`. When the entrypoint is `claude`
(default), also passed as `--name=$name` *before* `CLAUDE_ARGS`, so a
user-supplied `--name=` after `--` wins (later in argv). With a custom
`--entrypoint=`, no claude `--name` is injected.

## 7. Update on start

`images/entrypoint.sh`:

```
timeout --foreground 120 claude update </dev/null
```

An `INT` trap prints "Update skipped." so Ctrl-C aborts the update
immediately. Failures are swallowed (`|| true`). PID 1 is `tini`, which
reaps zombie children.

## 8. Security

`--dangerously-skip-permissions` is passed to claude; isolation comes from
the container.

Accessible by default:

- `$HOME/.claude` (rw), `$HOME/.gitconfig` (ro), `$(pwd)` (rw).
- Original repo when in a worktree with `bind`/`ask`+yes.
- Anything in `YOLO_PODMAN_VOLUMES` or `-v` on the command line.
- Unrestricted outbound network.

Not mounted: `~/.ssh` (so `git push` over SSH fails), credential files
outside the listed mounts, host root.

User-namespace remapping makes files written inside the container owned
by the host user.

## 9. Testing

```
bats tests/
shellcheck bin/yolo setup-yolo.sh images/entrypoint.sh
```

`tests/yolo.bats` exercises:

- `expand_volume` (all four forms).
- `podman_supports_keep_id_remap` version comparator.
- All flags in §2, including `--worktree=` validation.
- `--anonymized-paths` vs. default mount layout.
- `--nvidia` arg injection and its absence.
- Container `--name=` normalization.
- Env passthrough for `CLAUDE_CODE_OAUTH_TOKEN` and
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.
- Auto `--name=` and user-override semantics.
- Config sourcing of all three array variables; `--no-config` suppression.
- `resolve_image`: no `.yolo/`, empty `.yolo/`, root-only, user-only with
  same content (different hash), both, determinism, single-byte
  sensitivity, cache hit, `--rebuild`, missing base image.

Changes to the contracts above must update the corresponding tests.
