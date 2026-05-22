# Originally based on Anthropic's official Dockerfile: https://github.com/anthropics/claude-code/blob/07e13937b2d6e798ce1880b22ad6bd22115478e4/.devcontainer/Dockerfile
FROM debian:bookworm

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest
ARG OPENCODE_VERSION=latest
ARG CODEX_VERSION=latest

# Install basic development tools.
# tini is included as a minimal init process to properly reap zombie processes
# when a harness spawns external tools (git, npm, etc.) that may fork children.
# nodejs/npm are kept available for any project that wants to install
# npm-based tooling in .yolo/user-setup.sh. (They were originally required for
# the Codex CLI install; codex is currently deferred but the small footprint
# is worth keeping for general npm availability.)
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  dnsutils \
  fzf \
  gh \
  git \
  gnupg2 \
  iproute2 \
  jq \
  less \
  man-db \
  mc \
  moreutils \
  nano \
  ncdu \
  nodejs \
  npm \
  parallel \
  procps \
  shellcheck \
  sudo \
  tini \
  tree \
  unzip \
  vim \
  wget \
  zsh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user. Name is deliberately neutral ("agent") rather than
# tied to a specific harness — the image bundles claude and opencode (codex
# planned) and any of them may run as this user.
ARG USERNAME=agent
RUN useradd -m -u 1000 -U -s /bin/zsh $USERNAME

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and per-harness config directories.
# Each harness keeps its own state under the user's home so host bind mounts
# can land on the matching path: ~/.claude (Claude Code) and the XDG
# locations for OpenCode. (~/.codex skipped while codex is deferred.)
RUN mkdir -p \
  /workspace \
  /home/agent/.claude \
  /home/agent/.config/opencode \
  /home/agent/.local/share/opencode \
  && chown -R agent:agent \
  /workspace \
  /home/agent/.claude \
  /home/agent/.config \
  /home/agent/.local

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER agent

# Re-declare ARGs needed after USER switch (ARG values don't persist)
ARG CLAUDE_CODE_VERSION
ARG OPENCODE_VERSION
ARG CODEX_VERSION

# Persist the resolved versions into the runtime image so entrypoint.sh can
# decide whether to auto-update on container start. When a build pin is set
# (anything other than "latest"), the entrypoint skips the runtime update
# to preserve the pinned version.
ENV CODEX_VERSION=$CODEX_VERSION
ENV OPENCODE_VERSION=$OPENCODE_VERSION

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# User-owned bin directories on PATH, one per harness install method:
#   ~/.local/bin       — claude (native installer)
#   ~/.opencode/bin    — opencode (the upstream installer's default location)
#   ~/.npm-global/bin  — codex (npm -g into a dedicated prefix) [deferred]
# The codex prefix is left on PATH so re-enabling codex is a one-step Dockerfile
# edit. Keeping the claude and codex trees disjoint matters when codex returns:
# `claude update` scans npm's global prefix and reports a phantom "npm-global"
# install if the prefix is a parent of its own binary. Disjoint trees avoid the
# false positive while still resolving every harness on PATH.
ENV PATH="/home/agent/.npm-global/bin:/home/agent/.opencode/bin:/home/agent/.local/bin:$PATH"

# Install Claude Code using the native installer.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- ${CLAUDE_CODE_VERSION}

# Install OpenCode (sst/opencode). The upstream installer drops the binary
# under ~/.opencode/bin (its default), which is on PATH above. The build
# arg OPENCODE_VERSION is mapped to the installer's documented `--version
# X.Y.Z` flag (the installer's env var is $VERSION, not $OPENCODE_VERSION).
# For the default "latest", we omit the flag so the installer fetches the
# newest release rather than trying to install a literal "latest" tag.
RUN if [ "${OPENCODE_VERSION}" = "latest" ]; then \
      curl -fsSL https://opencode.ai/install | bash; \
    else \
      curl -fsSL https://opencode.ai/install | bash -s -- --version "${OPENCODE_VERSION}"; \
    fi

# Codex CLI (OpenAI) install — currently deferred. Re-enable by uncommenting
# the RUN block below AND restoring the codex entry in select_harness() in
# bin/yolo, the codex case in images/entrypoint.sh, and the codex check in
# the sanity RUN line further down.
#
# Note: the original form used `npm config set prefix` which writes prefix=…
# to ~/.npmrc — that line is incompatible with nvm in .yolo/user-setup.sh
# (nvm refuses to operate when a user-level prefix is set). The replacement
# below uses `npm install -g --prefix <path>` instead, which doesn't mutate
# ~/.npmrc and so cohabits cleanly with nvm.
#
# RUN mkdir -p /home/agent/.npm-global \
#   && npm install -g --prefix /home/agent/.npm-global "@openai/codex@${CODEX_VERSION}"

# Build-time sanity check: every active harness must resolve on PATH. Catches
# drift in upstream installer behavior (e.g., binary moves to a new default
# dir) before the image ships, rather than failing at container exec time.
# Codex is excluded while deferred — re-add it when re-enabling above.
RUN command -v claude && command -v opencode

# Entrypoint just sets up tini and execs the command yolo passes in.
# No harness is launched by default — yolo always supplies one (claude or
# opencode; codex deferred).
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
