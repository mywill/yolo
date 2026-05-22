# yolo runtime model

## Mount layout

Host source → container target. Container targets under `/home/agent/...` are fixed regardless of host `$HOME`, so a harness that falls back to `$HOME` inside the container (e.g. opencode reads `$HOME/.config/opencode`) always finds its data — `$HOME=/home/agent` always.

| Host | Container | Mode | Active when |
|---|---|---|---|
| `$HOME/.claude` | `/home/agent/.claude` | rw | `HARNESS=claude` |
| `$HOME/.config/opencode` | `/home/agent/.config/opencode` | rw | `HARNESS=opencode` |
| `$HOME/.local/share/opencode` | `/home/agent/.local/share/opencode` | rw | `HARNESS=opencode` |
| `$HOME/.claude/skills` | `/home/agent/.claude/skills` | ro | `HARNESS=opencode` |
| `$HOME/.agents/skills` | `/home/agent/.agents/skills` | ro | `HARNESS=opencode` |
| `$HOME/.gitconfig` | `/tmp/.gitconfig` | ro | always |
| `$(pwd)` | `$(pwd)` | rw | always |
| `<original_repo>` | `<original_repo>` | rw | worktree, when bound |

(The `$HOME/.codex → /home/agent/.codex` mount and the codex-side ro skill mounts are implemented but disabled — see `SPEC.md` §10.)

`WORKDIR=$(pwd)`. Each harness's host source dir is created if missing. The ro skill paths are also created if missing, so the bind has something to point at on a fresh machine.

The workspace mount preserves the host path on both sides so harness session resume (which keys on the workspace path) interops between containerized and native runs.

The ro skill mounts make any skill installed at the standard host locations discoverable by opencode. Claude doesn't need separate skill mounts because its full `~/.claude` rw mount already covers `~/.claude/skills/`; claude does not read `~/.agents/skills/`.

### Worktree binding

When `$(pwd)` is a worktree (`.git` is a file pointing to `<orig>/.git/worktrees/<name>`), the launcher resolves the original repo. Modes: `ask` (prompt, default), `bind`, `skip`, `error`. Without binding, git ops needing original-repo metadata (`fetch`, some `push`) will fail.

## Not mounted

`~/.ssh`, host root, `.aws/`, `.docker/config.json`, cloud SDK creds, the yolo repo itself. Add via `YOLO_PODMAN_VOLUMES` or `-v` if needed.

## Environment variables

Always forwarded:

| Variable | Behavior |
|---|---|
| `GIT_CONFIG_GLOBAL` | Set to `/tmp/.gitconfig`. |
| `YOLO_HARNESS` | Set to the active harness name. Read by `entrypoint.sh` to choose the right self-update branch. |

Per-harness:

| Harness | Config env var (set to container path) | Forwarded by name (`-e NAME`) | Force-set (`-e KEY=VALUE`) |
|---|---|---|---|
| `claude` | `CLAUDE_CONFIG_DIR=/home/agent/.claude` | `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | (none) |
| `opencode` | (none — XDG resolves to `/home/agent/.config/opencode`) | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `GEMINI_API_KEY` | `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` |

(Codex, when re-enabled: `CODEX_HOME=/home/agent/.codex` config var, `OPENAI_API_KEY` forwarded by name. See `SPEC.md` §10.)

"Forwarded by name" = `-e VAR` (no value), so the host's exported value flows through; unset on the host means unset in the container. "Force-set" = `-e VAR=value` always, regardless of host env.

Anything else needs `--env=` via `YOLO_PODMAN_OPTIONS` or CLI `-e`.

## Launcher env vars (control yolo itself)

| Variable | Effect |
|---|---|
| `HARNESS` | Initial harness selection. Overridden by config `HARNESS=` and CLI `--harness=`. |
| `YOLO_NO_AMBIGUOUS_WARN` | Set to `1` to silence the "looks like a podman flag" warning when no `--` separator is present. |

## User namespace

- Container user: `agent`, UID/GID 1000, `HOME=/home/agent`.
- Host UID → container 1000 via `--userns=keep-id:uid=1000,gid=1000` (podman ≥ 4.3).
- Podman < 4.3: `--user="$(id -u):$(id -g)" --userns=keep-id` — clean only when host UID is 1000.

Files written in-container appear owned by the host user (the point of keep-id remapping).

## Network

Unrestricted outbound. No inbound by default — use `-p` (before `--`) for port mapping, e.g., `yolo -p 3000:3000`.

## Auto-injected `--name=`

Synthesized from `$PWD-$$`:

1. Strip leading `$HOME/`.
2. Non-`[A-Za-z0-9_.-]` → `_`.
3. Strip leading `.` / `_`.

Always passed to podman as `--name=$name`. For `HARNESS=claude` only, also passed as `claude --name=` so podman container and claude session names match (helps `/resume`). User-supplied `--name=` after `--` wins. `--entrypoint=` bypasses the profile and injects no `--name`.

## Fixed podman flags

Always set: `--log-driver=none`, `-it --rm`, `--userns=…`, `--name=<synthesized>`, mounts above, `-w <workspace>`, harness env (config-dir env + passthroughs from the table), `-e GIT_CONFIG_GLOBAL=/tmp/.gitconfig`, `-e YOLO_HARNESS=<harness>`.

User flags layer on via `YOLO_PODMAN_OPTIONS`, `YOLO_PODMAN_VOLUMES`, CLI tokens before `--`, harness tokens after `--`.

## Entrypoint

`images/entrypoint.sh` runs under tini (PID 1) and, on container start, attempts a per-harness self-update before `exec`-ing the harness command:

| `YOLO_HARNESS` | Update command |
|---|---|
| `claude` | `claude update` |
| `opencode` | `curl -fsSL https://opencode.ai/install \| bash` |

(The `codex` branch — `npm install -g --prefix /home/agent/.npm-global @openai/codex@latest` — is commented out alongside the codex install in the Dockerfile. See `SPEC.md` §10.)

Each is wrapped in `timeout --foreground 120` with an `INT` trap that prints "Update skipped." and continues — Ctrl-C aborts cleanly. Failures are swallowed (`|| true`). To bypass entirely: `yolo --entrypoint=<harness>` replaces the container command and skips `entrypoint.sh`.

## Security boundaries

The harness's yolo-mode signal runs inside the container — the container is the isolation layer. The signal is `--dangerously-skip-permissions` (CLI flag) for claude, and `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` (force-set env var) for opencode. (Codex, when re-enabled, uses CLI flag `--dangerously-bypass-approvals-and-sandbox`.)

Accessible: active harness's host config dir(s) rw, `$HOME/.gitconfig` ro, `$(pwd)` rw, bound original repo (worktree), anything in `YOLO_PODMAN_VOLUMES`/`-v`, outbound network.

Not accessible: `~/.ssh`, other credential dirs, host root, inbound network.

Threat model: prompt-injection in project code can attempt to coerce the harness. Mount surface bounds what it can touch. Adding `~/.ssh` or other creds expands attack surface. No outbound firewall.
