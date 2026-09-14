#!/usr/bin/python3
"""Capture only quota metadata; preserve the user's existing status-line output."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

STATE = Path(os.environ.get('USAGEBAR_STATE_DIR', Path.home() / 'Library/Application Support/UsageBar'))

def main():
    raw = sys.stdin.buffer.read()
    try:
        data = json.loads(raw)
        STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
        # No prompts, tokens, credentials, or conversation contents are written.
        capture = {'observed': time.time(), 'rate_limits': data.get('rate_limits') or {}}
        temp = STATE / ('claude-status.' + str(os.getpid()) + '.tmp')
        temp.write_text(json.dumps(capture))
        os.chmod(temp, 0o600)
        os.replace(temp, STATE / 'claude-status.json')
    except (ValueError, OSError):
        data = {}
    try:
        config = json.loads((STATE / 'bridge-config.json').read_text())
    except (ValueError, OSError):
        config = {}
    original = config.get('original') or {}
    command = original.get('command')
    if command and 'claude_bridge.py' not in command:
        # This is the exact already-configured user command, never JSON input.
        try:
            p = subprocess.run(['/bin/sh', '-c', command], input=raw, timeout=8)
            return p.returncode
        except (OSError, subprocess.TimeoutExpired):
            pass
    print((data.get('model') or {}).get('display_name', 'Claude'))
    return 0

if __name__ == '__main__':
    sys.exit(main())
