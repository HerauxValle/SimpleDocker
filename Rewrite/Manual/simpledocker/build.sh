#!/usr/bin/env bash
# build.sh — builds the simpledocker single binary
# Run from the simpledocker/ directory

set -euo pipefail

cd "$(dirname "$0")"

echo "==> Checking PyInstaller..."
if ! python3 -c "import PyInstaller" 2>/dev/null; then
    echo "    Installing PyInstaller..."
    pip install pyinstaller --break-system-packages 2>/dev/null \
        || pip install pyinstaller
fi

echo "==> Running PyInstaller..."
python3 -m PyInstaller simpledocker.spec --noconfirm

echo ""
echo "==> Done! Binary is at: dist/simpledocker"
echo "    Copy it anywhere and run:  ./simpledocker"
echo ""
ls -lh dist/simpledocker 2>/dev/null || true
