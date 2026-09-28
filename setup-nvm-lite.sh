#!/usr/bin/env bash
set -e

TARGET="$HOME/.bin/tools/nvm/nvm-lite.sh"
BASHRC="$HOME/.bashrc"

mkdir -p "$HOME/.bin/tools/nvm"

curl -fsSL \
  "https://raw.githubusercontent.com/niteshnawada/nk-scripts/main/tools/nvm-lite/nvm-lite.sh" \
  -o "$TARGET"

chmod +x "$TARGET"

SOURCE_LINE="source $TARGET"

if ! grep -Fqx "$SOURCE_LINE" "$BASHRC" 2>/dev/null; then
    printf '\n# nvm-lite\n%s\n' "$SOURCE_LINE" >> "$BASHRC"
fi

echo "nvm-lite installed successfully."
echo "Restart Git Bash or run: source ~/.bashrc"
