#!/bin/bash
set -e

# Install nvm
export NVM_DIR="$HOME/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

# Load nvm and install latest LTS
. "$NVM_DIR/nvm.sh"
nvm install --lts

# Enable corepack for pnpm/yarn
corepack enable
corepack prepare pnpm@latest --activate
