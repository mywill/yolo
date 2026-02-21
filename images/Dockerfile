# Based on Anthropic's official Dockerfile: https://github.com/anthropics/claude-code/blob/07e13937b2d6e798ce1880b22ad6bd22115478e4/.devcontainer/Dockerfile
FROM debian:bookworm

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Extra packages to install (space-separated list)
ARG EXTRA_PACKAGES=""

# Extras (set to "1" to enable)
ARG EXTRA_CUDA=""
ARG EXTRA_NODE=""
ARG EXTRA_PLAYWRIGHT=""

# Install basic development tools
# tini is included as a minimal init process to properly reap zombie processes
# when Claude spawns external tools (git, npm, etc.) that may fork children
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
  libwebkit2gtk-4.1-dev \
  build-essential \
  libssl-dev \
  libgtk-3-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev gstreamer1.0-plugins-bad libx264-dev \
  libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install extra packages if specified
RUN if [ -n "$EXTRA_PACKAGES" ]; then \
      apt-get update && apt-get install -y --no-install-recommends $EXTRA_PACKAGES \
      && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# Install Node.js if enabled
RUN if [ "$EXTRA_NODE" = "1" ]; then \
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
      apt-get install -y nodejs && \
      apt-get clean && rm -rf /var/lib/apt/lists/* && \
      npm install -g corepack && \
      corepack enable; \
    fi

# Install Playwright system dependencies if enabled (must be done as root)
# Requires EXTRA_NODE=1
RUN if [ "$EXTRA_PLAYWRIGHT" = "1" ]; then \
      if [ "$EXTRA_NODE" != "1" ]; then \
        echo "ERROR: EXTRA_PLAYWRIGHT=1 requires EXTRA_NODE=1" >&2; exit 1; \
      fi; \
      npx playwright install-deps chromium; \
    fi

# NVIDIA CUDA toolkit for building CUDA extensions
# Runtime GPU access (nvidia-smi, drivers) is handled by CDI at container runtime
# To use: run container with --device nvidia.com/gpu=all (yolo --nvidia)
# Requires non-free and contrib apt components
RUN if [ "$EXTRA_CUDA" = "1" ]; then \
      sed -i 's/^Components: main$/Components: main contrib non-free/' /etc/apt/sources.list.d/debian.sources \
      && apt-get update && apt-get install -y --no-install-recommends nvidia-cuda-toolkit \
      && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# Create non-root user
ARG USERNAME=claude
RUN useradd -m -s /bin/zsh $USERNAME

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/claude/.claude && \
  chown -R claude:claude /workspace /home/claude/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER claude

# Re-declare ARGs needed after USER switch (ARG values don't persist)
ARG EXTRA_NODE
ARG EXTRA_PLAYWRIGHT
ARG CLAUDE_CODE_VERSION

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

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
  echo 'source "$HOME/.cargo/env"' >> ~/.zshrc && \
  echo 'source "$HOME/.cargo/env"' >> ~/.bashrc

# Add cargo to PATH for this build
ENV PATH="/home/claude/.cargo/bin:$PATH"

# Prepare pnpm and npm-global paths if Node.js is installed
RUN if [ "$EXTRA_NODE" = "1" ]; then \
      corepack prepare pnpm@latest --activate; \
    fi

# Install Claude Code using native installer
RUN curl -fsSL https://claude.ai/install.sh | sh -s -- -y ${CLAUDE_CODE_VERSION}

# Install Playwright and Chromium browser if enabled (requires Node.js)
RUN if [ "$EXTRA_PLAYWRIGHT" = "1" ]; then \
      npm install -g playwright && \
      npx playwright install chromium; \
    fi

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && \
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# Add uv and claude to PATH for this build
ENV PATH="/home/claude/.local/bin:$PATH"

# Install git-annex
RUN uv tool install git-annex && \
  uv cache clean

# Use tini as init process to properly reap zombie processes
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["claude"]
