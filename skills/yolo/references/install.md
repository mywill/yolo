# Installing yolo

## Prerequisites

- **podman ≥ 4.3** strongly recommended. Check: `podman version --format '{{.Client.Version}}'`.
  - Ubuntu 22.04 ships 3.4 — upgrade, or accept that host UID must be 1000 for clean file ownership. The launcher (`podman_supports_keep_id_remap` in `bin/yolo`) picks the right `--userns` flag automatically.
- **git** for cloning.
- **nvidia-container-toolkit** if `--nvidia` GPU passthrough is wanted.

## Standard install

```bash
git clone https://github.com/con/yolo
cd yolo
./setup-yolo.sh
```

`setup-yolo.sh`:

1. Builds the prebuilt image `yolo-base` (a few minutes; cached after). The image bundles `claude` and `opencode`. (`codex` is plumbed but its install is commented out — see `SPEC.md` §10.)
2. Prompts to install `yolo` to `~/.local/bin/yolo`.
3. Prompts to install the agent skill to **both** `~/.claude/skills/yolo/` and `~/.agents/skills/yolo/`. The dual install covers both currently-active harnesses' search paths plus codex's (`~/.agents/skills/`) so re-enabling codex later doesn't require a re-install: claude reads `~/.claude/skills/`, opencode reads both. Both harness profiles also bind each other's data directories read-only into their containers, so skills (and plans, projects, config) are discoverable regardless of which harness is active.
4. If a legacy `con-bomination-claude-code` tag is detected on the host, offers to remove it after the new image is built.

Ensure `~/.local/bin` is on `$PATH` in `~/.bashrc` / `~/.zshrc`.

Flags: `--build=auto|yes|no`, `--install=auto|yes|no` (default `auto`: build if missing, prompt for install). Idempotent.

## NVIDIA setup

`--nvidia` uses CDI:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

Searched at `/etc/cdi/nvidia.yaml` then `/var/run/cdi/nvidia.yaml`. Missing → warning, no GPU. Activate per-run with `yolo --nvidia` or set `USE_NVIDIA=1` in `.git/yolo/config`.

## Manual install

```bash
podman build --build-arg TZ=$(timedatectl show --property=Timezone --value) \
  -t yolo-base images/
cp bin/yolo ~/.local/bin/yolo && chmod +x ~/.local/bin/yolo
# Install skill to both paths so all three harnesses can find it
mkdir -p ~/.claude/skills ~/.agents/skills
cp -r skills/yolo ~/.claude/skills/
cp -r skills/yolo ~/.agents/skills/
```

Verify: `yolo --help`.
