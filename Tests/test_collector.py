import copy
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
import collector as c
import bridge_setup

PRICES = {'gpt-test': {'input': 10, 'cached': 1, 'write': 12.5, 'output': 50},
          'claude-test': {'input': 5, 'cached': .5, 'write': 6.25, 'write1h': 10, 'output': 25}}

def event(total):
    return {'type': 'event_msg', 'timestamp': '2026-09-14T01:00:00Z',
            'payload': {'type': 'token_count', 'info': {'total_token_usage': total}}}

def usage(i, o=10, cached=0):
    return {'input_tokens': i, 'output_tokens': o, 'cached_input_tokens': cached}

class UsageTests(unittest.TestCase):
    def state(self, provider='codex'):
        s = c.new_state(Path('session.jsonl'), provider)
        s['model'] = 'gpt-test'
        return s

    def test_cumulative_snapshots_not_summed_and_reasoning_not_double_counted(self):
        s = self.state()
        for u in [usage(100, 10, 20), usage(100, 10, 20), dict(usage(250, 30, 100), reasoning_output_tokens=20)]:
            c.consume(event(u), s)
        r = c.summarize([s], PRICES)[0]
        self.assertEqual((r['input'], r['output'], r['cached']), (250, 30, 100))
        self.assertAlmostEqual(r['cost'], (150 * 10 + 100 + 30 * 50) / 1e6)

    def test_new_and_old_events_not_double_counted(self):
        s = self.state()
        record = {'type': 'token_usage_record', 'payload': {'thread_id': 'session', 'response_id': 'r1', 'usage': usage(100)}}
        c.consume(record, s); c.consume(record, s); c.consume(event(usage(100)), s)
        self.assertEqual(c.summarize([s], PRICES)[0]['input'], 100)

    def test_migration_retains_old_usage(self):
        s = self.state()
        c.consume(event(usage(100)), s)
        c.consume({'type':'token_usage_record','payload':{'thread_id':'session','response_id':'r','usage':usage(50)}}, s)
        c.consume(event(usage(150,20)), s)
        self.assertEqual(c.summarize([s], PRICES)[0]['input'], 150)

    def test_foreign_thread_record_ignored(self):
        s = self.state()
        c.consume({'type':'token_usage_record','payload':{'thread_id':'parent','response_id':'r','usage':usage(999)}}, s)
        self.assertEqual(c.summarize([s], PRICES), [])

    def test_fork_cumulative_history_does_not_charge_parent(self):
        s = self.state()
        c.consume({'type':'token_usage_record','payload':{'thread_id':'parent','response_id':'parent-r','usage':usage(1000)}}, s)
        c.consume(event(usage(1000)), s)
        c.consume({'type':'token_usage_record','payload':{'thread_id':'session','response_id':'own-r','usage':usage(100)}}, s)
        c.consume(event(usage(1100)), s)
        self.assertEqual(c.summarize([s],PRICES)[0]['input'],100)

    def test_model_switch_prices_separately(self):
        s = self.state(); c.consume(event(usage(100, 10)), s)
        s['model'] = 'unknown-new-model'; c.consume(event(usage(200, 20)), s)
        row = c.summarize([s], PRICES)[0]
        self.assertIsNone(row['cost']); self.assertGreater(row['knownCost'], 0)
        self.assertEqual(len(row['models']), 2)

    def test_claude_streaming_dedup_and_cache_cost(self):
        s = self.state('claude')
        msg = {'type':'assistant','sessionId':'session','message':{'id':'m1','model':'converse/global.anthropic.claude-test','usage':{'input_tokens':100,'output_tokens':10,'cache_read_input_tokens':1000,'cache_creation_input_tokens':200,'cache_creation':{'ephemeral_1h_input_tokens':50}}}}
        c.consume(msg, s); c.consume(msg, s)
        msg['message']['usage']['output_tokens'] = 30; c.consume(msg, s)
        row = c.summarize([s, copy.deepcopy(s)], PRICES)[0]
        self.assertEqual((row['input'], row['output'], row['cached'], row['write']), (1300, 30, 1000, 200))
        self.assertAlmostEqual(row['cost'], (100*5 + 30*25 + 1000*.5 + 150*6.25 + 50*10) / 1e6)

    def test_partial_line_and_truncation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 's.jsonl'
            line = json.dumps(event(usage(100)))
            path.write_text(line[:30])
            s = c.scan_file(path, 'codex'); self.assertEqual(s['offset'], 0)
            with path.open('a') as f: f.write(line[30:] + '\n')
            s = c.scan_file(path, 'codex', s)
            self.assertEqual(c.summarize([s], PRICES)[0]['input'], 100)
            self.assertEqual(c.summarize([c.scan_file(path,'codex',s)],PRICES)[0]['input'],100)
            path.write_text(json.dumps(event(usage(20)))+'\n')
            s = c.scan_file(path, 'codex', s)
            self.assertEqual(c.summarize([s],PRICES)[0]['input'],20)

    def test_zero_quota_is_valid_missing_is_unknown_expiry_not_full(self):
        w = c.normalize_window({'usedPercent':0,'resetsAt':time.time()+100},'5h',time.time())
        self.assertEqual(w['remaining'],100)
        self.assertIsNone(c.normalize_window({'usedPercent':None},'5h',0))
        expired = c.normalize_window({'usedPercent':30,'resetsAt':1},'5h',1)
        self.assertTrue(expired['expired']); self.assertEqual(expired['remaining'],70)

    def test_multiple_buckets_preserved(self):
        result = {'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':7,'windowDurationMins':10080}},'other':{'primary':{'usedPercent':99,'windowDurationMins':300}}}}
        windows = c.codex_windows(result,time.time())
        self.assertEqual([w['remaining'] for w in windows],[93,1])
        self.assertEqual(windows[0]['label'],'7日')

    def test_bridge_setup_preserves_other_settings_and_restores_exact_statusline(self):
        with tempfile.TemporaryDirectory(prefix='UsageBar') as folder:
            root = Path(folder); state = root/'state'; claude = root/'claude'; claude.mkdir()
            original = {'env':{'DUMMY':'retained'},'statusLine':{'type':'command','command':'cat','padding':3},'hooks':{'a':[]}}
            (claude/'settings.json').write_text(json.dumps(original))
            bridge_setup.setup(state,claude)
            current = json.loads((claude/'settings.json').read_text())
            self.assertEqual(current['env'],original['env']); self.assertEqual(current['hooks'],original['hooks'])
            bridge_setup.setup(state,claude); bridge_setup.setup(state,claude,remove=True)
            self.assertEqual(json.loads((claude/'settings.json').read_text()),original)

    def test_bridge_refuses_invalid_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); (root/'settings.json').write_text('{invalid')
            with self.assertRaises(ValueError): bridge_setup.setup(root/'state',root)
            self.assertEqual((root/'settings.json').read_text(),'{invalid')

if __name__ == '__main__': unittest.main()
