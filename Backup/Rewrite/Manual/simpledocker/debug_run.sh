#!/usr/bin/env bash
# Run without tmux wrapping so you see errors directly in terminal
cd "$(dirname "$0")"
python main.py --inner 2>&1 | tee /tmp/simpledocker_debug.log
echo ""
echo "--- log saved to /tmp/simpledocker_debug.log ---"
