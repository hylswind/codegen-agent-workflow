#!/usr/bin/env bash
# Install the latest Claude Code with the native installer ("latest" channel).
set -euo pipefail

curl -fsSL https://claude.ai/install.sh | bash

export PATH="$HOME/.local/bin:$PATH"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$HOME/.local/bin" >> "$GITHUB_PATH"
fi

echo "name=claude-code version=$(claude --version | awk '{print $1}')"
