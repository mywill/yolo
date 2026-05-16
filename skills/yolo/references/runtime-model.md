# yolo runtime model

## Mount layout

### Default (host paths preserved)

| Host | Container | Mode |
|---|---|---|
| `$HOME/.claude` | `$HOME/.claude` | rw |
| `$HOME/.gitconfig` | `/tmp/.gitconfig` | ro |
| `$(pwd)` | `$(pwd)` | rw |
| `<original_repo>` | `<original_repo>` | rw (worktree, when bound) |

`WORKDIR=$(pwd)`. `CLAUDE_CONFIG_DIR=$HOME/.claude`. `$HOME/.claude` is created on host if missing. Preserved paths → sessions interop with native Claude Code (`claude --continue` works both ways).

### `--anonymized-paths` / `USE_ANONYMIZED_PATHS=1`

| Host | Container | Mode |
|---|---|---|
| `$HOME/.claude` | `/claude` | rw |
| `$HOME/.gitconfig` | `/tmp/.gitconfig` | ro |
| `$(pwd)` | `/workspace` | rw |

`WORKDIR=/workspace`. `CLAUDE_CONFIG_DIR=/claude`. Identical container paths across projects let `claude --continue` carry context between codebases.

### Worktree binding

When `$(pwd)` is a worktree (`.git` is a file pointing to `<orig>/.git/worktrees/<name>`), the launcher resolves the original repo. Modes: `ask` (prompt, default), `bind`, `skip`, `error`. Without binding, git ops needing original-repo metadata (`fetch`, some `push`) will fail.

## Not mounted

`~/.ssh`, host root, `.aws/`, `.docker/config.json`, cloud SDK creds, the yolo repo itself. Add via `YOLO_PODMAN_VOLUMES` or `-v` if needed.

## Environment variables

Forwarded by the launcher:

| Variable | Behavior |
|---|---|
| `CLAUDE_CONFIG_DIR` | Set to in-container claude config path. |
| `GIT_CONFIG_GLOBAL` | `/tmp/.gitconfig`. |
| `CLAUDE_CODE_OAUTH_TOKEN` | Forwarded by name. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Forwarded by name. |

Anything else needs `--env=` via `YOLO_PODMAN_OPTIONS` or CLI `-e`.

## User namespace

- Container: `claude`, UID/GID 1000.
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

When the entrypoint is default (`claude`), the same name is also passed as `claude --name=` so podman container and claude session names match (helps `/resume`). User-supplied `--name=` after `--` wins. With `--entrypoint=` set, no `claude --name` is injected.

## Fixed podman flags

Always set: `--log-driver=none`, `-it --rm`, `--userns=…`, `--name=<synthesized>`, mounts above, `-w <workspace>`, `-e CLAUDE_CONFIG_DIR=…`, `-e GIT_CONFIG_GLOBAL=/tmp/.gitconfig`, `-e CLAUDE_CODE_OAUTH_TOKEN`, `-e CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.

User flags layer on via `YOLO_PODMAN_OPTIONS`, `YOLO_PODMAN_VOLUMES`, CLI tokens before `--`, claude tokens after `--`.

## Entrypoint

`images/entrypoint.sh`:

```bash
timeout --foreground 120 claude update </dev/null
```

`INT` trap prints "Update skipped." so Ctrl-C continues to claude. Failures swallowed (`|| true`). PID 1 is `tini`, which reaps zombies.

Bypass: `yolo --entrypoint=claude` (no update, no tini).

## Security boundaries

`--dangerously-skip-permissions` runs inside the container — the container is the isolation layer.

Accessible: `$HOME/.claude` rw, `$HOME/.gitconfig` ro, `$(pwd)` rw, bound original repo (worktree), anything in `YOLO_PODMAN_VOLUMES`/`-v`, outbound network.

Not accessible: `~/.ssh`, other credential dirs, host root, inbound network.

Threat model: prompt-injection in project code can attempt to coerce claude. Mount surface bounds what it can touch. Adding `~/.ssh` or other creds expands attack surface. No outbound firewall.
