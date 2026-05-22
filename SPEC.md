# yolo — Specification

Contract document. `README.md` is the tutorial; `tests/yolo.bats` is the
executable spec. On disagreement, the test suite wins.

## 1. Components

| Path                    | Role                                                              |
|-------------------------|-------------------------------------------------------------------|
| `bin/yolo`              | Launcher. Parses flags, resolves the image, runs podman.          |
| `setup-yolo.sh`         | Builds the prebuilt image; installs `bin/yolo` to `~/.local/bin/yolo`. |
| `images/Dockerfile`     | Prebuilt yolo image `yolo-base` (FROM `debian:bookworm`, installs claude and opencode; codex install commented out — see §10). |
| `images/entrypoint.sh`  | Per-harness self-update (timeout, Ctrl-C escape), then `exec "$@"` under tini. |
| `config.example`        | Reference documentation for `.git/yolo/config`. The template actually rendered by `--install-config` / first-run auto-creation lives in `bin/yolo` (`print_config_template`); the two are kept in sync by hand — see `AGENTS.md`. |
| `tests/yolo.bats`       | bats-core test suite.                                             |

## 2. CLI

```
yolo [PODMAN_ARGS...] [FLAGS] [-- HARNESS_ARGS...]
```

Tokens before `--` that aren't recognized flags pass through to `podman
run`. Tokens after `--` go to the harness. If no `--` is present, all
unrecognized tokens are treated as `HARNESS_ARGS`.

| Flag                  | Default  | Effect                                                                                          |
|-----------------------|----------|-------------------------------------------------------------------------------------------------|
| `-h`, `--help`        | —        | Print help, exit 0.                                                                             |
| `--harness=NAME`      | `claude` | Select harness. `NAME` ∈ {`claude`, `opencode`}. `codex` is recognized by the parser but currently exits with a "planned but not yet enabled" error (see §10). Also accepts `--harness NAME`. |
| `--entrypoint=CMD`    | —        | Replace in-container command, bypassing the harness profile (no default args, no auto `--name`). Also accepts `--entrypoint CMD`. |
| `--worktree=MODE`     | `ask`    | `MODE` ∈ {`ask`, `bind`, `skip`, `error`}; anything else is a hard error. Also accepts `--worktree MODE`. |
| `--nvidia`            | off      | Add `--device nvidia.com/gpu=all --security-opt label=disable`.                                 |
| `--rebuild`           | off      | Force rebuild of the derived image.                                                             |
| `--no-config`         | off      | Skip sourcing `.git/yolo/config` (and skip auto-creation).                                      |
| `--install-config`    | —        | Create `.git/yolo/config` from template if missing; otherwise print existing. Exits 0.          |

`--install-config` and `--help` short-circuit before podman runs.

### Ambiguous-arg warning

When no `--` is present and a token before the implicit boundary matches
a high-confidence podman flag (`-v`, `-p`, `-e`, `--volume`,
`--publish`, `--env`, `--network`, `--memory`, `--cpus`, `--shm-size`,
`--device`, plus the `=value` forms), `bin/yolo` prints a stderr
warning + tip suggesting `--` (once per invocation in which the
condition holds — there is no persistence across runs). Behavior is
unchanged: the unrecognized tokens still flow to the harness. Silence
with `YOLO_NO_AMBIGUOUS_WARN=1`.

### Harness selection precedence

Highest wins:

1. `--harness=NAME` on the CLI.
2. `HARNESS=name` in `.git/yolo/config`.
3. `HARNESS` in the calling shell's environment.
4. Default `claude`.

An unknown harness name is a hard error. A known-but-deferred harness
(`codex` at present) is also a hard error, with a distinct message
("planned but not yet enabled"); see §10.

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
| `HARNESS`               | string  | Selects the harness: `claude` or `opencode`. (`codex` deferred — see §10.) Overridden by `--harness=`. |
| `YOLO_PODMAN_VOLUMES`   | array   | Each entry runs through `expand_volume`, added as `-v`.         |
| `YOLO_PODMAN_OPTIONS`   | array   | Prepended to user-supplied podman args.                         |
| `YOLO_HARNESS_ARGS`     | array   | Prepended to user-supplied harness args (active for any harness). |
| `YOLO_CLAUDE_ARGS`      | array   | **Deprecated.** If non-empty, contents are merged into `YOLO_HARNESS_ARGS` (CLAUDE_ARGS first → HARNESS_ARGS wins on conflict) and a stderr warning is printed on each invocation while the variable is set. |
| `USE_NVIDIA`            | 0/1     | Default for `--nvidia`.                                         |
| `WORKTREE_MODE`         | string  | Default for `--worktree=`.                                      |

CLI flags override config. `--no-config` skips the file entirely.

### Volume shorthand (`expand_volume`)

| Input                       | Expanded                                |
|-----------------------------|-----------------------------------------|
| `~/projects`                | `<HOME>/projects:<HOME>/projects:z`     |
| `~/data::ro`                | `<HOME>/data:<HOME>/data:ro,z`          |
| `/host:/container`          | `/host:/container:z`                    |
| `/host:/container:ro,z`     | unchanged                               |

## 4. `.yolo/` contract

### Files

| Path                       | Required |
|----------------------------|----------|
| `.yolo/root-setup.sh`      | no       |
| `.yolo/user-setup.sh`      | no       |

At project root. Both optional. If both absent (or `.yolo/` absent), the
prebuilt image is used directly and no derived image is built. The
contract is harness-independent — the same derived image is reused
across `claude` and `opencode` (and across `codex` once re-enabled).

### Build

Base FROM is always the prebuilt image `yolo-base`. When at least one
script exists, `bin/yolo` generates:

```dockerfile
FROM yolo-base

# Only if root-setup.sh exists:
COPY --chmod=755 root-setup.sh /tmp/root-setup.sh
USER root
RUN /tmp/root-setup.sh
RUN rm -f /tmp/root-setup.sh
USER agent

# Only if user-setup.sh exists:
COPY --chmod=755 user-setup.sh /tmp/user-setup.sh
RUN /tmp/user-setup.sh
```

- `root-setup.sh` runs as `USER root`.
- `user-setup.sh` runs as `USER agent` (UID 1000).
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
Enforced by `tests/yolo.bats:432–453` (the `resolve_image: only user-setup.sh -> different hash than root-only with same content` block).

### Cache and rebuild

- `podman image exists <derived_tag>` and no `--rebuild` → use cache.
- Otherwise → build.
- `--rebuild` forces a rebuild; the tag is content-addressed so the name
  is reused.
- Missing base image → exit non-zero with
  `Base image 'yolo-base' not found. Run setup-yolo.sh first.`

## 5. Container runtime

### Harness profiles

`bin/yolo` selects one profile and uses it to compose mounts, env, and
the in-container command. Profiles for the currently active harnesses:

| Field                  | `claude`                     | `opencode`                                                          |
|------------------------|------------------------------|---------------------------------------------------------------------|
| In-container command   | `claude`                     | `opencode`                                                          |
| Default args (yolo)    | `--dangerously-skip-permissions` | (none — env `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` is force-set instead) |
| Auto `--name=` injected | yes                         | no                                                                  |
| Host source dir(s)     | `$HOME/.claude`              | `$HOME/.config/opencode` + `$HOME/.local/share/opencode`            |
| Container target dir(s) | `/home/agent/.claude`       | `/home/agent/.config/opencode` + `/home/agent/.local/share/opencode` |
| Config env var set     | `CLAUDE_CONFIG_DIR=/home/agent/.claude` | (none — XDG resolves to `/home/agent/.config/opencode`)   |
| Extra ro mounts (host → container) | (none — `~/.claude` rw already covers skills) | `$HOME/.claude/skills → /home/agent/.claude/skills`, `$HOME/.agents/skills → /home/agent/.agents/skills` |
| Env vars forwarded (`-e NAME`) | `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `GEMINI_API_KEY` |
| Env vars force-set (`-e KEY=VALUE`) | (none)                  | `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true`                        |

(The `codex` profile is implemented but currently deferred. See §10.)

Container-relative `/home/agent/...` targets are independent of the host
`$HOME`. The container user is `agent` with `HOME=/home/agent`, so a
harness that falls back to `$HOME` (opencode reads its config from
`$HOME/.config/opencode`) resolves to exactly where its bind mount
lands, regardless of the host user.

The first listed host source dir is created on first run if missing.
Extra mounts (opencode's data dir, the cross-harness skill paths) are
also created. The ro skill mounts give opencode access to any skill
installed at the standard host locations; claude already sees them
through its full `~/.claude` rw mount.

### Mounts always present

| Host                  | Container                            | Options |
|-----------------------|--------------------------------------|---------|
| Harness host dir(s) (see profile) | `/home/agent/...` (see profile) | `z`     |
| `$HOME/.gitconfig`    | `/tmp/.gitconfig`                    | `ro,z`  |
| `$(pwd)`              | `$(pwd)`                             | `z`     |
| `<original_repo>`     | `<original_repo>`                    | `z`     | (worktree binding only)

`WORKDIR=$(pwd)`. The workspace mount preserves the host path on both
sides so harness session resume (which keys session history on the
workspace path) interops between containerized and native runs.

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

- `GIT_CONFIG_GLOBAL=/tmp/.gitconfig` (always).
- `YOLO_HARNESS=<active-harness>` (always). Read by `images/entrypoint.sh`
  to select the right self-update branch on container start.
- The harness's `HARNESS_CONFIG_ENV_NAME` set to the in-container config dir, if the harness has one (e.g. `CLAUDE_CONFIG_DIR=/home/agent/.claude` for claude).
- Each name in the harness's env-passthrough list forwarded with `-e NAME` (no value bound — podman reads it from the caller's environment). See profile table.
- Each entry in the harness's force-set list passed as `-e KEY=VALUE` unconditionally (currently only opencode: `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true`).

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

Passed to podman as `--name=$name`. Harnesses with
`HARNESS_INJECT_NAME=1` (currently only `claude`) also receive
`--name=$name` injected before `HARNESS_ARGS`, so a user-supplied
`--name=` after `--` wins (later in argv). `--entrypoint=` bypasses the
profile and injects no `--name`.

## 7. Entrypoint

`images/entrypoint.sh` runs under tini (PID 1) and, on container start,
attempts a self-update for the active harness before `exec`-ing the
command yolo passes in:

| `YOLO_HARNESS` | Update command                                                |
|----------------|---------------------------------------------------------------|
| `claude`       | `claude update`                                               |
| `opencode`     | `curl -fsSL https://opencode.ai/install \| bash`              |
| (unset)        | none                                                          |

(The `codex` branch is implemented but commented out in
`images/entrypoint.sh`. See §10.)

Each update is wrapped in `timeout --foreground 120` and an `INT` trap
prints "Update skipped." and continues. Failures are swallowed
(`|| true`) — a failed update never blocks the harness. Stdout/stderr
for the non-claude updates is suppressed to keep the container's
startup quiet; claude's update preserves its own progress output.

To bypass entirely (e.g. for fast iteration), use
`yolo --entrypoint=<harness>` — that replaces the container command and
skips `entrypoint.sh`.

## 8. Security

The harness's "skip all permission prompts" signal is injected by yolo:
CLI flag `--dangerously-skip-permissions` for claude, and force-set env
`OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` for opencode (current
opencode rejects the equivalent CLI flag). Isolation comes from the
container. (When re-enabled, codex uses the CLI flag
`--dangerously-bypass-approvals-and-sandbox`; see §10.)

Accessible by default:

- The active harness's host config dir(s) (rw), `$HOME/.gitconfig` (ro), `$(pwd)` (rw).
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
- All flags in §2, including `--worktree=` validation and `--harness=` validation.
- Default mount layout: host source → `/home/agent/...` container target
  for each active harness.
- `--nvidia` arg injection and its absence.
- Container `--name=` normalization.
- Env passthrough for `CLAUDE_CODE_OAUTH_TOKEN` and
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` (under harness=claude).
- Auto `--name=` and user-override semantics (harness=claude only).
- Config sourcing of all three array variables; `--no-config` suppression.
- `resolve_image`: no `.yolo/`, empty `.yolo/`, root-only, user-only with
  same content (different hash), both, determinism, single-byte
  sensitivity, cache hit, `--rebuild`, missing base image.
- `select_harness` profile dispatch for claude and opencode; unknown
  name rejection; codex returns the "planned but not yet enabled" error
  (see §10).
- `--harness=opencode` end-to-end: in-container command, default args,
  mounts, env passthrough, absence of claude-specific bits.
- Harness selection precedence: CLI > config > shell env > default.
- `YOLO_HARNESS_ARGS` applied for any harness. `YOLO_CLAUDE_ARGS`
  deprecated alias: contents merged in, warning fires, `YOLO_HARNESS_ARGS`
  wins on conflict.
- `YOLO_HARNESS=<name>` env var forwarded into the container for every
  active harness.
- `CLAUDE_CONFIG_DIR` set exactly once and only for harness=claude.
- `warn_ambiguous_args` covers `-v`, `-p`, `-e`, `--volume`, `--publish`,
  `--env`, `--env=`, `--network=host`; silent on `--env-file=` and on
  harness-only args.
- `--entrypoint=CMD` bypasses harness defaults.
- Codex-specific tests are skipped while the harness is deferred (a
  single `skip` line per test makes re-enabling a search-and-delete).

Changes to the contracts above must update the corresponding tests.

## 10. Deferred: codex

The codex (OpenAI Codex CLI) harness is plumbed end-to-end in
`bin/yolo`, `images/Dockerfile`, and `images/entrypoint.sh` but
currently disabled. `yolo --harness=codex` (or `HARNESS=codex` from
config / shell env) exits non-zero with:

```
Error: codex harness is planned but not yet enabled in this build of yolo.
       Use --harness=claude or --harness=opencode for now.
```

### Why deferred

Codex is npm-distributed. The previous install used
`npm config set prefix "/home/agent/.npm-global"` which writes
`prefix=…` into `~/.npmrc`. nvm's startup check refuses to operate when
a user-level npmrc has `prefix` or `globalconfig` set, so any project
whose `.yolo/user-setup.sh` installed nvm (the canonical pattern in
`images/examples/node/`) failed to build with exit 11.

The fix is mechanical (`npm install -g --prefix <path>` instead of
`npm config set prefix`), and the replacement form is already in the
commented Dockerfile block. Codex is held back to keep the base image
slim and to wait for a static-binary distribution that would remove the
node dependency entirely.

### Re-enabling

Uncomment, in this order:

1. `images/Dockerfile`: the `RUN ... npm install -g --prefix ... codex`
   block, and add `codex` back to the `command -v` sanity-check line.
   Restore the `~/.codex` entry in the `mkdir`/`chown` block.
2. `images/entrypoint.sh`: the `codex)` case in the update switch.
3. `bin/yolo`: in `select_harness()`, remove the `echo`/`exit 1` lines
   in the `codex)` branch and uncomment the profile config below them.
4. `.github/workflows/ci.yml`: re-enable the codex smoke test.
5. `tests/yolo.bats`: remove the `skip "codex harness temporarily
   disabled"` lines (grep for that exact string).
6. This section: delete it; restore codex columns in §5/§7 tables and
   the codex bullets in §9.

The profile, when re-enabled, is:

| Field                  | `codex`                                          |
|------------------------|--------------------------------------------------|
| In-container command   | `codex`                                          |
| Default args (yolo)    | `--dangerously-bypass-approvals-and-sandbox`     |
| Auto `--name=` injected | no                                              |
| Host source dir(s)     | `$HOME/.codex`                                   |
| Container target dir(s) | `/home/agent/.codex`                            |
| Config env var set     | `CODEX_HOME=/home/agent/.codex`                  |
| Extra ro mounts        | `$HOME/.claude/skills → /home/agent/.claude/skills`, `$HOME/.agents/skills → /home/agent/.agents/skills` |
| Env vars forwarded     | `OPENAI_API_KEY`                                 |
| Env vars force-set     | (none)                                           |
