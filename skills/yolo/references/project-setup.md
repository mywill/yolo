# Adding yolo to a project

`<project_root>/.yolo/` customizes the container image. Both files optional; empty/absent `.yolo/` → base image used directly.

```
your-project/.yolo/
├── root-setup.sh    # runs as root during build (apt-get, /etc/, users)
└── user-setup.sh    # runs as 'claude' user (rustup, uv, nvm, cargo install, npm -g)
```

`root-setup.sh` is deleted from the image after running; `user-setup.sh` is kept (so installs are inspectable later).

## Build context

- `WORKDIR=/workspace` (from base image). Scripts copied to `/tmp/` and executed there.
- Project files are **not** visible during build — install *tools*, not deps. Project is mounted at runtime.
- Scripts run unattended — pass `-y` / `--non-interactive`.
- `COPY --chmod=755` is in the generated Dockerfile — no need to chmod.

## Caching

Derived tag: `yolo-<sha256(base_id + scripts)[:12]>`. Hash uses `|root|` and `|user|` delimiters, so identical bytes in different stages produce different tags. Cache hit → reuse; otherwise build. `yolo --rebuild` forces.

To refresh upstream versions without script changes: touch a comment to perturb the hash, or `--rebuild`.

## Per-language templates

Templates ship with the skill at `recipes/<lang>/` (i.e. `~/.claude/skills/yolo/recipes/<lang>/` for the standard install). Read them directly and copy into the project's `.yolo/`:

| Project marker | Template |
|---|---|
| `Cargo.toml` | `recipes/rust/` |
| `package.json` | `recipes/node/` |
| `pyproject.toml` / `requirements.txt` | `recipes/python/` |
| `Cargo.toml` + `package.json` + `src-tauri/` | `recipes/tauri/` |
| polyglot | `recipes/full/` |

(Canonical source in the yolo repo: `images/examples/<lang>/`. `setup-yolo.sh` copies them into the skill at install — re-run it to refresh.)

Pattern for unsupported languages: system libs / compilers → `root-setup.sh` apt-get; toolchains dropping under `$HOME` → `user-setup.sh`.

## Bootstrap workflow (creating `.yolo/` from inside a running session)

A user runs `yolo` in a project with no `.yolo/`, lands in the base image, and asks for tooling:

1. **You're already inside yolo.** `$(pwd)` is bind-mounted rw, so files written to `.yolo/` persist to the host.
2. **Write `.yolo/{root,user}-setup.sh`** by copying from `recipes/<lang>/` (or adapt). Apt-style → `root`, `curl … | sh` toolchains → `user`.
3. **Exit** (Ctrl-D or `/exit`). The derived image builds at launcher start, not runtime — the running session can't see new tools.
4. **Re-run `yolo`**. Launcher detects `.yolo/`, builds the derived image, starts a fresh session.
5. **Resume**: paths are preserved, so `claude --continue` / `/resume` picks up the previous conversation.

### Iteration

Edit `.yolo/*.sh` from inside or outside the container (same files). Exit, re-run — hash changes, rebuild is automatic. Podman build cache still helps: an unchanged `root-setup.sh` doesn't repeat when only `user-setup.sh` changed.

For quick experiments before committing to a script:

```bash
yolo --entrypoint=bash
# try install commands; if they work, paste into .yolo/*.sh, exit, re-run yolo
```

## Common pitfalls

- **Installing project deps in `.yolo/`** — project isn't visible at build time. Install `uv`/`cargo`/`nvm` in `.yolo/`; run `uv sync` / `cargo build` / `pnpm install` at first use inside the container.
- **Caching surprises** — content-keyed, not mtime. Identical bytes = identical tag.
