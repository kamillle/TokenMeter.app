#!/usr/bin/python3
"""Reversible Claude status-line integration. Touch only statusLine."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import time
from collector import atomic_json, DEFAULT_STATE

def setup(state=DEFAULT_STATE, claude=None, remove=False):
    claude = claude or Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home() / '.claude'))
    path = claude / 'settings.json'
    # Refuse invalid JSON instead of replacing settings with an empty object.
    settings = json.loads(path.read_text()) if path.exists() else {}
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path = state / 'bridge-config.json'
    config = json.loads(config_path.read_text()) if config_path.exists() else {}
    current = settings.get('statusLine') or {}
    ours = 'UsageBar' in current.get('command', '') and 'claude_bridge.py' in current.get('command', '')
    if remove:
        if ours:
            if config.get('original') is None:
                settings.pop('statusLine', None)
            else:
                settings['statusLine'] = config['original']
            atomic_json(path, settings)
        config['installed'] = False
        atomic_json(config_path, config)
        print('Claude連携を解除しました')
        return
    if not ours:
        config = {'original': settings.get('statusLine'), 'installed': True}
        # Back up the field we change, rather than a full file containing secrets.
        atomic_json(state / ('statusline-backup-' + str(time.time_ns()) + '.json'), config)
    bridge = state / 'claude_bridge.py'
    shutil.copyfile(Path(__file__).with_name('claude_bridge.py'), bridge)
    command = '/usr/bin/python3 ' + shlex.quote(str(bridge))
    settings['statusLine'] = dict(current, type='command', command=command)
    config['installed'] = True
    atomic_json(config_path, config)
    atomic_json(path, settings)
    print('Claude連携を有効にしました。既存のステータスライン表示は維持されます')

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--remove', action='store_true')
    args = p.parse_args()
    try:
        setup(remove=args.remove)
    except (OSError, ValueError):
        print('設定を更新できませんでした。設定ファイルの形式とアクセス権を確認してください', file=sys.stderr)
        sys.exit(1)
