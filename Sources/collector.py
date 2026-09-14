#!/usr/bin/python3
"""Local, incremental usage reader. Never stores message bodies or credentials."""
import argparse
import concurrent.futures
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import sys
import time

VERSION = 5
FIELDS = ('input', 'output', 'cached', 'write', 'write1h')
DEFAULT_STATE = Path.home() / 'Library/Application Support/UsageBar'

def read_json(path, fallback=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return fallback

def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    with open(temp, 'w', encoding='utf-8') as f:
        os.chmod(temp, 0o600)
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
    os.replace(temp, path)

def stamp(value):
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return 0

def number(value):
    return max(0, int(value or 0))

def vector(u, provider):
    if provider == 'codex':
        total = number(u.get('input_tokens'))
        cached = min(total, number(u.get('cached_input_tokens')))
        write = min(total - cached, number(u.get('cache_write_input_tokens')))
        return dict(input=total, output=number(u.get('output_tokens')), cached=cached, write=write, write1h=0)
    cached = number(u.get('cache_read_input_tokens'))
    write = number(u.get('cache_creation_input_tokens'))
    hour = min(write, number((u.get('cache_creation') or {}).get('ephemeral_1h_input_tokens')))
    return dict(input=number(u.get('input_tokens')) + cached + write,
                output=number(u.get('output_tokens')), cached=cached, write=write, write1h=hour)

def zero():
    return dict.fromkeys(FIELDS, 0)

def add(a, b):
    for k in FIELDS:
        a[k] = a.get(k, 0) + b.get(k, 0)

def model_name(raw):
    raw = raw or 'unknown'
    if 'claude-' in raw:
        return raw[raw.index('claude-'):]
    return raw

def rate_for(model, prices):
    if model in prices:
        return prices[model]
    # Only a date snapshot suffix is an alias; never guess a new model's price.
    base = re.sub(r'-\d{8}$', '', model)
    return prices.get(base)

def cost_for(v, rate):
    if rate is None:
        return None
    fresh = max(0, v['input'] - v['cached'] - v['write'])
    return (fresh * rate['input'] + v['output'] * rate['output'] +
            v['cached'] * rate['cached'] + (v['write'] - v['write1h']) * rate['write'] +
            v['write1h'] * rate.get('write1h', rate['write'])) / 1_000_000

def new_state(path, provider):
    return dict(provider=provider, id=path.stem, title='', cwd='', model='unknown',
                updated=0, offset=0, inode=0, mtime=0, size=0, requests={},
                legacy={}, previous=zero(), rate=None, malformed=0)

def consume(d, s):
    kind = d.get('type')
    p = d.get('payload') or {}
    provider = s['provider']
    ts = stamp(d.get('timestamp'))
    if provider == 'codex':
        if kind == 'session_meta':
            s['id'] = p.get('id', s['id'])
            s['cwd'] = p.get('cwd', '')
            s['forked'] = bool(p.get('forked_from_id'))
            source = p.get('source')
            s['internal'] = isinstance(source, dict) and (source.get('subagent') or {}).get('other') == 'guardian'
        elif kind == 'turn_context':
            s['model'] = model_name(p.get('model'))
        elif kind == 'token_usage_record':
            # Forks may carry the parent's records. Charge only this task.
            if p.get('thread_id', s['id']) != s['id']:
                s['foreignRecords'] = True
                return
            u = p.get('usage')
            if not isinstance(u, dict):
                return
            rid = p.get('response_id') or str(d.get('ordinal', d.get('timestamp')))
            s['requests'][rid] = {'model': s['model'], 'usage': vector(u, provider)}
            s['updated'] = max(s['updated'], ts)
        elif kind == 'event_msg' and p.get('type') == 'token_count':
            rate = p.get('rate_limits')
            if rate:
                s['rate'] = {'raw': rate, 'observed': ts}
            u = (p.get('info') or {}).get('total_token_usage')
            if not isinstance(u, dict):
                return
            current = vector(u, provider)
            previous = s['previous']
            # Cumulative counters are snapshots, never values to sum directly.
            if current['input'] < previous['input'] or current['output'] < previous['output']:
                previous = zero()  # A new counter epoch after reset.
            delta = {k: max(0, current[k] - previous[k]) for k in FIELDS}
            add(s['legacy'].setdefault(s['model'], zero()), delta)
            s['previous'] = current
            s['updated'] = max(s['updated'], ts)
    else:
        if kind in ('custom-title', 'ai-title'):
            s['title'] = d.get('customTitle') or d.get('aiTitle') or s['title']
        if kind != 'assistant':
            return
        m = d.get('message') or {}
        if not isinstance(m.get('usage'), dict) or m.get('model') == '<synthetic>':
            return
        s['id'] = d.get('sessionId', s['id'])
        s['cwd'] = d.get('cwd', s['cwd'])
        model = model_name(m.get('model'))
        rid = str(m.get('id') or d.get('uuid')) + ':' + str(d.get('requestId') or '')
        v = vector(m['usage'], provider)
        old = s['requests'].get(rid)
        # Streaming records can repeat an id with progressively fuller usage.
        if old:
            v = {k: max(v[k], old['usage'][k]) for k in FIELDS}
        s['requests'][rid] = {'model': model, 'usage': v}
        s['updated'] = max(s['updated'], ts)

def scan_file(path, provider, previous=None):
    st = path.stat()
    s = previous
    if (not s or s['inode'] != st.st_ino or st.st_size < s['offset'] or
            (st.st_size == s['size'] and st.st_mtime_ns != s['mtime'])):
        s = new_state(path, provider)
    if st.st_size == s['size'] and st.st_mtime_ns == s['mtime']:
        return s
    needles = (b'"session_meta"', b'"turn_context"', b'"token_usage_record"', b'"token_count"') if provider == 'codex' else (b'"assistant"', b'"custom-title"', b'"ai-title"')
    with open(path, 'rb') as f:
        f.seek(s['offset'])
        while True:
            start = f.tell()
            line = f.readline()
            if not line:
                break
            if not line.endswith(b'\n'):
                f.seek(start)  # Retry an in-flight write on the next scan.
                break
            if any(n in line for n in needles):
                try:
                    consume(json.loads(line), s)
                except (ValueError, TypeError, KeyError, AttributeError):
                    s['malformed'] += 1
            s['offset'] = f.tell()
    s.update(inode=st.st_ino, size=st.st_size, mtime=st.st_mtime_ns)
    return s

def summarize(states, prices, titles=None):
    groups = {}
    for s in states:
        if s.get('internal'):
            continue
        sid = s['provider'] + ':' + s['id']
        g = groups.setdefault(sid, dict(id=s['id'], provider=s['provider'], title='', cwd='',
                                        updated=0, requests={}, legacy={}, malformed=0))
        if s['title']:
            g['title'] = s['title']
        g['cwd'] = s['cwd'] or g['cwd']
        g['updated'] = max(g['updated'], s['updated'])
        g['malformed'] += s['malformed']
        for rid, r in s['requests'].items():
            old = g['requests'].get(rid)
            if old:
                r = dict(model=r['model'], usage={k: max(r['usage'][k], old['usage'][k]) for k in FIELDS})
            g['requests'][rid] = r
        # Archived and active copies of the same legacy task are snapshots.
        for model, v in ({} if s.get('foreignRecords') or s.get('forked') else s['legacy']).items():
            target = g['legacy'].setdefault(model, zero())
            for k in FIELDS:
                target[k] = max(target[k], v[k])
    rows = []
    for g in groups.values():
        models = {}
        if g['requests']:
            for r in g['requests'].values():
                add(models.setdefault(r['model'], zero()), r['usage'])
            # Older parts of a session may predate per-response records. Keep
            # only the positive residual of cumulative legacy usage per model.
            if g['provider'] == 'codex':
                for model, v in g['legacy'].items():
                    target = models.setdefault(model, zero())
                    for k in FIELDS:
                        target[k] = max(target[k], v[k])
        else:
            models = g['legacy']
        total = zero()
        breakdown = []
        unknown = []
        estimated = 0.0
        for model, v in models.items():
            add(total, v)
            cost = cost_for(v, rate_for(model, prices))
            if cost is None and (v['input'] or v['output']):
                unknown.append(model)
            estimated += cost or 0
            breakdown.append(dict(model=model, **v, cost=cost))
        if not (total['input'] or total['output']):
            continue
        title = (titles or {}).get(g['id']) or g['title'] or Path(g['cwd']).name or 'Session'
        rows.append(dict(id=g['id'], provider=g['provider'], title=title, cwd=g['cwd'],
                         updated=g['updated'], **total, cost=None if unknown else estimated,
                         knownCost=estimated, unknownModels=unknown, models=breakdown,
                         malformed=g['malformed']))
    return sorted(rows, key=lambda r: r['updated'], reverse=True)

def normalize_window(w, label, observed, snake=False):
    if not isinstance(w, dict):
        return None
    value = w.get('used_percent' if snake else 'usedPercent')
    if not isinstance(value, (int, float)):
        return None
    duration = w.get('window_minutes' if snake else 'windowDurationMins')
    reset = stamp(w.get('resets_at' if snake else 'resetsAt'))
    if duration:
        label = (str(int(duration / 1440)) + '日') if duration >= 1440 else (str(round(duration / 60, 1)).removesuffix('.0') + '時間')
    return dict(label=label, remaining=max(0, min(100, 100 - value)), resetsAt=reset,
                observed=observed, expired=bool(reset and reset <= time.time()))

def codex_windows(result, observed, snake=False):
    buckets = result.get('rateLimitsByLimitId')
    if not buckets:
        raw = result if snake else result.get('rateLimits') or {}
        buckets = {raw.get('limit_id' if snake else 'limitId', 'codex'): raw}
    windows = []
    for key, bucket in sorted(buckets.items(), key=lambda x: x[0] != 'codex'):
        for field, label in [('primary', '主な利用枠'), ('secondary', '追加の利用枠')]:
            w = normalize_window(bucket.get(field), label, observed, snake)
            if w:
                w['bucket'] = key
                if key != 'codex':
                    w['label'] = (bucket.get('limitName') or key) + ' · ' + w['label']
                windows.append(w)
    return windows

def codex_rpc():
    candidates = [os.environ.get('USAGEBAR_CODEX'), shutil.which('codex'),
                  '/opt/homebrew/bin/codex', '/usr/local/bin/codex',
                  str(Path.home() / '.local/bin/codex')]
    executable = next((p for p in candidates if p and os.access(p, os.X_OK)), None)
    if not executable:
        raise RuntimeError('Codex CLIが見つかりません')
    process = subprocess.Popen([executable, 'app-server'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = b''
    def send(message):
        process.stdin.write((json.dumps(message) + '\n').encode())
        process.stdin.flush()
    def receive(wanted):
        nonlocal pending
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                try:
                    result = json.loads(line)
                except ValueError:
                    continue
                if result.get('id') == wanted:
                    if 'error' in result:
                        raise RuntimeError('Codexで利用枠を取得できません。ログイン状態を確認してください')
                    return result.get('result', {})
            if selector.select(0.5):
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('Codex CLIを起動できません')
                pending += chunk
        raise RuntimeError('Codexの利用枠取得がタイムアウトしました')
    try:
        send(dict(id=1, method='initialize', params=dict(clientInfo=dict(name='usagebar', version='1.0.0'), capabilities={})))
        receive(1)
        send(dict(method='initialized'))
        send(dict(id=2, method='account/rateLimits/read'))
        return receive(2)
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdin.close()
        process.stdout.close()

def codex_quota(states, state_dir, live=True, force=False):
    now = time.time()
    path = state_dir / 'codex-quota.json'
    cache = read_json(path, {})
    error = cache.get('error', '')
    if live and (force or now - cache.get('attempted', 0) >= 300):
        try:
            result = codex_rpc()
            cache = dict(attempted=now, observed=now, raw=result, linked=True)
            error = ''
        except (OSError, RuntimeError) as e:
            error = str(e) if isinstance(e, RuntimeError) else 'Codex CLIとの通信に失敗しました'
            cache.update(attempted=now, error=error)
        atomic_json(path, cache)
    samples = [s['rate'] for s in states if s.get('rate')]
    sample = max(samples, key=lambda s: s['observed'], default=None)
    if cache.get('raw') and (not sample or cache.get('observed', 0) >= sample['observed']):
        observed = cache['observed']
        windows = codex_windows(cache['raw'], observed)
        source = 'Codexアカウント'
    elif sample:
        observed = sample['observed']
        windows = codex_windows(sample['raw'], observed, snake=True)
        source = 'セッションログ'
    else:
        observed, windows, source = 0, [], '未取得'
    linked = bool(cache.get('linked', bool(cache.get('raw'))) or sample)
    return dict(windows=windows, observed=observed, source=source, error=error, linked=linked,
                stale=now - observed > 600, detail='利用枠はアカウント全体で共有されます')

def claude_quota(state_dir):
    data = read_json(state_dir / 'claude-status.json', {})
    observed = data.get('observed', 0)
    windows = []
    for key, label in [('five_hour', '5時間'), ('seven_day', '7日'), ('spend_limit', '支出枠')]:
        w = (data.get('rate_limits') or {}).get(key)
        if isinstance(w, dict):
            item = normalize_window(dict(usedPercent=w.get('used_percentage'), resetsAt=w.get('resets_at')), label, observed)
            if item:
                item['bucket'] = 'claude'
                windows.append(item)
    installed = bool(read_json(state_dir / 'bridge-config.json', {}).get('installed'))
    detail = 'Claude Codeからの最終通知。会話の応答時に更新されます'
    if not windows:
        detail = ('連携済み・Claude Codeからの利用枠通知待ち。Pro/Maxの応答後に更新されます。接続先によっては通知されません' if installed else
                  '「Claude連携」で使用率の通知を受け取れます。セッションのトークン集計は連携前でも利用できます')
    return dict(windows=windows, observed=observed, source='Claude Code通知' if observed else '未取得',
                linked=installed and bool(windows),
                error='', stale=time.time() - observed > 600, detail=detail, bridgeInstalled=installed)

def collect(state_dir, codex_home, claude_home, live=True, force=False):
    cache_path = state_dir / 'sessions-cache.json'
    cache = read_json(cache_path, {})
    previous = cache.get('files', {}) if cache.get('version') == VERSION else {}
    files = {}
    errors = []
    cutoff = time.time() - 30 * 86400
    # Start read-only quota polling while incrementally scanning local logs.
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(codex_quota, [], state_dir, live, force)
        for provider, roots in [('codex', [codex_home / 'sessions', codex_home / 'archived_sessions']),
                                ('claude', [claude_home / 'projects'])]:
            for root in roots:
                if not root.exists():
                    continue
                for path in root.rglob('*.jsonl'):
                    # Side-agent transcripts are separate sessions; use their filename
                    # below to avoid merging cumulative parent totals with children.
                    try:
                        if path.stat().st_mtime < cutoff:
                            continue
                        s = scan_file(path, provider, previous.get(str(path)))
                        if provider == 'claude' and 'subagents' in path.parts:
                            s['id'] = path.stem
                            s['title'] = s['title'] or 'Subagent · ' + path.stem[-8:]
                        files[str(path)] = s
                    except OSError:
                        errors.append(provider + ': 読み取れないログがあります')
        future.result()
    atomic_json(cache_path, dict(version=VERSION, files=files))
    pricing = read_json(Path(__file__).with_name('pricing.json'), {})
    prices = pricing.get('models', {})
    override = read_json(state_dir / 'pricing.json', {})
    prices.update(override.get('models', {}))
    titles = {}
    try:
        for line in (codex_home / 'session_index.jsonl').open():
            try:
                d = json.loads(line)
                titles[d['id']] = d.get('thread_name') or d.get('title') or ''
            except (ValueError, KeyError):
                continue
    except OSError:
        pass
    states = list(files.values())
    return dict(updated=time.time(), sessions=summarize(states, prices, titles),
                codex=codex_quota(states, state_dir, live=False), claude=claude_quota(state_dir),
                errors=sorted(set(errors)), pricingDate=pricing.get('verified', ''),
                scope='このMacの直近30日以内に更新されたセッション · 数値は各セッションの累計')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, default=DEFAULT_STATE)
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')))
    parser.add_argument('--claude-home', type=Path, default=Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home() / '.claude')))
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.state_dir / 'collector.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = collect(args.state_dir, args.codex_home, args.claude_home, not args.offline, args.force)
        print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))

if __name__ == '__main__':
    main()
