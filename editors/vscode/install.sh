#!/usr/bin/env bash
# Build the compiler, package the extension with it inside, and install it into VS Code
# (or VSCodium / Cursor / Insiders: pass the CLI, e.g. `./install.sh cursor`).
#
#   editors/vscode/install.sh            # into `code`
#   editors/vscode/install.sh codium
set -euo pipefail
cd "$(dirname "$0")"

editor="${1:-}"
if [ -z "$editor" ]; then
    for c in code code-insiders codium cursor; do
        if command -v "$c" >/dev/null; then editor="$c"; break; fi
    done
fi
if [ -z "$editor" ] || ! command -v "$editor" >/dev/null; then
    echo "no editor CLI found (code, code-insiders, codium, cursor)." >&2
    echo "In VS Code: Command Palette → 'Shell Command: Install code command in PATH', or pass one: $0 <cli>" >&2
    exit 1
fi
command -v cargo >/dev/null || { echo "needs cargo (run ../../setup.sh)" >&2; exit 1; }
command -v npm >/dev/null || { echo "needs node + npm" >&2; exit 1; }

[ -d node_modules ] || npm install --no-audit --no-fund
npm run package                      # cargo build --release, bundles bin/stellang, writes the .vsix
version=$(node -p "require('./package.json').version")
"$editor" --install-extension "stellang-$version.vsix" --force
echo
echo "installed stellang $version into $editor: reload the window (Developer: Reload Window) and open a .st file"
