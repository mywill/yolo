#!/bin/bash
set -e

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
echo 'source "$HOME/.cargo/env"' >> ~/.zshrc
echo 'source "$HOME/.cargo/env"' >> ~/.bashrc

# Install nvm + Node.js
export NVM_DIR="$HOME/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
. "$NVM_DIR/nvm.sh"
nvm install --lts

# Enable corepack for pnpm
corepack enable
corepack prepare pnpm@latest --activate
