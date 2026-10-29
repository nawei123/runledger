"""Black-box correctness, crash recovery and integrity tests for native external audit."""
import collections
import copy
import hashlib
import json
import os
import pathlib
import random
import signal
import subprocess
import tempfile
import time
import unittest

from check_invariants import reference

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / '_build/native/debug/build/cmd/runledger-large/runledger-large.exe'
LEGACY = ROOT / '_build/native/debug/build/cmd/runledger/runledger.exe'


def row(identity='a', task='q1', stage='answer', incoming=10, outgoing=2, **changes):
    value = dict(run_id='r', task_id=task, stage=stage, call_id=identity, model='m',
                 status='ok', input_tokens=incoming, output_tokens=outgoing)
    value.update(changes)
    return value


class ExternalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='runledger-external-test-')
        self.root = pathlib.Path(self.tmp.name)
        self.source = self.root / 'calls.jsonl'
        self.work = self.root / 'job'
        self.manifest = self.root / 'manifest.json'
        self.manifest.write_text(json.dumps(dict(run_id='r', model='m', task_ids=['q1','q2'], required_stages=['answer','review'])))
        self.options = ['--batch-rows','2','--batch-bytes','512','--fan-in','2']

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rows):
        self.source.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows), encoding='utf-8')

    def run_job(self, extra=(), work=None, manifest=True, expected=None):
        args = [str(BIN), str(self.source), str(work or self.work)] + self.options
        if manifest: args += ['--manifest', str(self.manifest)]
        proc = subprocess.run(args+list(extra),cwd=ROOT,text=True,capture_output=True)
        if expected is not None: self.assertEqual(proc.returncode,expected,proc.stdout+proc.stderr)
        return proc, json.loads(proc.stdout)

    def assert_legacy(self, proc, report, mode='audit'):
        args=[str(LEGACY),mode,str(self.source)]
        if self.manifest.exists(): args.append(str(self.manifest))
        old=subprocess.run(args,cwd=ROOT,text=True,capture_output=True)
        base=json.loads(old.stdout); actual=report['report']
        self.assertEqual(proc.returncode,old.returncode)
        for key in ['ok','usage_complete','totals']: self.assertEqual(actual[key],base[key],key)
        expected=collections.Counter((x['line'],x['code'],x['message']) for x in base['findings'])
        findings=[json.loads(line) for line in (self.work/'findings.jsonl').read_text().splitlines()]
        self.assertEqual(collections.Counter((x['line'],x['code'],x['message']) for x in findings),expected)
        self.assertEqual({k:int(v) for k,v in actual['diagnostic_counts'].items()},dict(collections.Counter(x['code'] for x in findings)))
        self.assertEqual(report['input']['sha256'],hashlib.sha256(self.source.read_bytes()).hexdigest())
        for name in ['findings','accepted_records']:
            path=self.work/report['artifacts'][name]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),report['artifacts'][name+'_sha256'])
        return base

    def test_cross_run_collisions_conflicts_and_late_duplicate(self):
        a=row(); self.write([a,row('b','q1','review'),row('c','q2','answer'),row('d','q2','review'),a,
                             row('a',incoming=11),row('a',run_id='other')])
        proc,result=self.run_job();self.assert_legacy(proc,result)
        self.assertEqual(result['external_sort']['ingest_runs'],4)
        self.assertEqual(result['report']['totals']['calls'],4)

    def test_preserve_original_order_for_overflow(self):
        self.write([row('z',incoming=9007199254740991,outgoing=0),row('a',incoming=1,outgoing=7)])
        proc,result=self.run_job();self.assert_legacy(proc,result)
        self.assertEqual(result['report']['totals']['input_tokens'],'9007199254740991')
        self.assertEqual(result['report']['totals']['output_tokens'],'0')

    def test_all_checkpoint_boundaries_resume_to_identical_result(self):
        rows=[row(str(i),'q'+str(i%2+1),'review' if i%2 else 'answer') for i in range(17)]
        rows += [copy.deepcopy(rows[0]),dict(rows[0],input_tokens=99),row('failed',status='error',input_tokens=None)]
        self.write(rows)
        self.run_job(expected=1)
        golden=(self.work/'report.json').read_bytes()
        second=self.root/'interrupted'
        proc,result=self.run_job(['--pause-after-checkpoints','1'],work=second,expected=75)
        phases=set()
        for _ in range(200):
            phases.add(result.get('phase'))
            proc,result=self.run_job(['--resume','--pause-after-checkpoints','1'],work=second)
            if proc.returncode!=75: break
        else: self.fail('recovery did not complete')
        self.assertEqual(proc.returncode,1,result)
        self.assertEqual((second/'report.json').read_bytes(),golden)
        self.assertTrue({0,1,2,3,4,5}.issubset(phases),phases)

    def test_changed_source_is_rejected_even_with_same_size(self):
        self.write([row()]);self.run_job(['--pause-after-checkpoints','2'],expected=75)
        self.source.write_bytes(self.source.read_bytes().replace(b'"m"',b'"n"'))
        _,result=self.run_job(['--resume'],expected=2)
        self.assertIn('changed',result['message'])

    def test_changed_resource_bound_and_manifest_are_rejected(self):
        self.write([row()]);self.run_job(['--pause-after-checkpoints','1'],expected=75)
        self.run_job(['--resume','--fan-in','3'],expected=2)
        self.manifest.write_text(self.manifest.read_text()+' ')
        self.run_job(['--resume'],expected=2)

    def test_intermediate_corruption_is_rejected(self):
        self.write([row()]);self.run_job(['--pause-after-checkpoints','2'],expected=75)
        part=self.work/'identity-g0-r0.jsonl';part.write_bytes(part.read_bytes()+b' ')
        _,result=self.run_job(['--resume'],expected=2)
        self.assertIn('checksum',result['message'])

    def test_checkpoint_corruption_is_rejected(self):
        self.write([row()]);self.run_job(['--pause-after-checkpoints','1'],expected=75)
        path=self.work/'checkpoint.json';data=json.loads(path.read_text());data['payload']+=' ';path.write_text(json.dumps(data))
        _,result=self.run_job(['--resume'],expected=2)
        self.assertIn('checksum',result['message'])

    def test_long_lines_invalid_utf8_and_diagnostic_sample_bound(self):
        self.source.write_bytes(b'x'*300+b'\n\xff\n'+b'not-json\n'*30)
        _,result=self.run_job(['--max-line-bytes','128','--sample-limit','2'],expected=1)
        counts={k:int(v) for k,v in result['report']['diagnostic_counts'].items()}
        self.assertEqual(counts['line_too_long'],1);self.assertEqual(counts['invalid_utf8'],1)
        self.assertEqual(counts['invalid_json'],30)
        self.assertEqual(len(result['report']['sample_findings']),2)
        self.assertTrue(result['report']['sample_truncated'])
        self.assertEqual(result['input']['physical_lines'],32)

    def test_empty_blank_crlf_and_no_final_newline(self):
        for payload in [b'',b'\n\r\n',json.dumps(row()).encode()+b'\r\n'+json.dumps(row('b','q1','review')).encode()]:
            with self.subTest(payload=payload):
                if self.work.exists():
                    self.work=self.root/('job-'+str(len(list(self.root.iterdir()))))
                self.source.write_bytes(payload)
                rows=[json.loads(line) for line in payload.splitlines() if line.strip()]
                proc,result=self.run_job();self.assert_legacy(proc,result)
                totals,codes,complete=reference(rows,json.loads(self.manifest.read_text()))
                self.assertEqual({k:int(v) for k,v in result['report']['totals'].items()},totals)
                self.assertEqual({k:int(v) for k,v in result['report']['diagnostic_counts'].items()},codes)
                self.assertEqual(result['report']['usage_complete'],complete)

    def test_existing_directory_and_lock_are_preserved(self):
        self.write([row()]);self.work.mkdir();marker=self.work/'user-file';marker.write_text('keep')
        self.run_job(expected=2);self.assertEqual(marker.read_text(),'keep')
        if os.name!='posix': return
        import fcntl
        os.chmod(self.work,0o700)
        with (self.work/'.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            _,result=self.run_job(['--resume'],expected=2)
            self.assertIn('locked',result['message'])

    def test_resume_completed_job_and_output_corruption(self):
        self.write([row()]);self.run_job(expected=1)
        original=(self.work/'report.json').read_bytes()
        self.run_job(['--resume'],expected=1);self.assertEqual((self.work/'report.json').read_bytes(),original)
        (self.work/'findings.jsonl').write_text('changed')
        self.run_job(['--resume'],expected=2)

    def test_sdk_and_ollama_adapters(self):
        for fmt,filename,mode in [('sdk','sdk-spans.jsonl','audit-spans'),('ollama','ollama.jsonl','audit-ollama')]:
            with self.subTest(fmt=fmt):
                self.source.write_bytes((ROOT/'examples'/filename).read_bytes())
                self.manifest.write_bytes((ROOT/'examples/manifest.json').read_bytes())
                self.work=self.root/('job-'+fmt)
                proc,result=self.run_job(['--format',fmt]);self.assert_legacy(proc,result,mode)

    def test_seeded_fault_combinations_match_in_memory_reference(self):
        rng=random.Random(20261030)
        for seed in range(25):
            with self.subTest(seed=seed):
                rows=[row(str(i),'q'+str(i%2+1),rng.choice(['answer','review']),rng.choice([0,10,None]),
                          rng.choice([0,2,None]),status=rng.choice(['ok','error'])) for i in range(30)]
                rows += [copy.deepcopy(rows[0]),dict(rows[1],input_tokens=13),row('foreign',run_id='other')]
                rng.shuffle(rows);self.write(rows);self.work=self.root/('random-'+str(seed))
                proc,result=self.run_job();self.assert_legacy(proc,result)
                totals,codes,complete=reference(rows,json.loads(self.manifest.read_text()))
                self.assertEqual({k:int(v) for k,v in result['report']['totals'].items()},totals)
                self.assertEqual({k:int(v) for k,v in result['report']['diagnostic_counts'].items()},codes)
                self.assertEqual(result['report']['usage_complete'],complete)

    def test_diagnostic_sample_has_a_byte_bound_for_long_identifiers(self):
        self.write([])
        self.manifest.write_text(json.dumps(dict(run_id='r', model='m', task_ids=['x'*40000], required_stages=['answer','review'])))
        _,result=self.run_job(expected=1)
        sample=result['report']['sample_findings']
        self.assertLessEqual(sum(len(json.dumps(x,ensure_ascii=False,separators=(',',':')).encode()) for x in sample),65536)
        self.assertTrue(result['report']['sample_truncated'])
        self.assertEqual(int(result['report']['diagnostic_counts']['missing_stage']),2)

    def test_real_sigkill_releases_lock_and_resumes_committed_work(self):
        self.write([row(str(i), 'q1' if i%4<2 else 'q2', 'answer' if i%2==0 else 'review') for i in range(2000)])
        args=[str(BIN),str(self.source),str(self.work)]+self.options+['--manifest',str(self.manifest)]
        with (self.root/'child.out').open('w') as out, (self.root/'child.err').open('w') as err:
            child=subprocess.Popen(args,cwd=ROOT,stdout=out,stderr=err)
            try:
                deadline=time.monotonic()+15
                found=False
                while time.monotonic()<deadline and child.poll() is None:
                    try:
                        envelope=json.loads((self.work/'checkpoint.json').read_text())
                        state=json.loads(envelope['payload'])
                        if state['phase']==0 and state['ingest_runs']>=3:
                            found=True
                            child.kill()
                            break
                    except (FileNotFoundError,json.JSONDecodeError):
                        pass
                    time.sleep(0.001)
                self.assertTrue(found,'child finished before a committed ingestion checkpoint could be interrupted')
                child.wait(timeout=10)
                self.assertEqual(child.returncode,-signal.SIGKILL)
            finally:
                if child.poll() is None: child.kill();child.wait()
        proc,result=self.run_job(['--resume'],expected=0)
        self.assert_legacy(proc,result)

    def test_one_identity_with_many_copies_and_sample_bytes(self):
        # All copies must remain one group without buffering the group in memory.
        self.write([row()]*200+[row(incoming=11)])
        proc,result=self.run_job(['--sample-limit','1000']);self.assert_legacy(proc,result)
        self.assertEqual(result['report']['totals']['calls'],0)
        self.assertEqual(int(result['report']['diagnostic_counts']['duplicate_call']),199)
        self.assertLessEqual(sum(len(json.dumps(x,ensure_ascii=False,separators=(',',':')).encode()) for x in result['report']['sample_findings']),65536)


if __name__=='__main__':
    unittest.main()
