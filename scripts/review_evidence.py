"""Replay bounded, synthetic review cases against the compiled public CLI.

This produces technical evidence, not competition approval or a real-provider claim.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/runledger/runledger.exe'


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def call(identity, stage, incoming=10, outgoing=2, **changes):
    value = dict(run_id='review-demo', task_id='q1', stage=stage, call_id=identity,
                 model='demo-model', status='ok', input_tokens=incoming, output_tokens=outgoing)
    value.update(changes)
    return value


def span(identity, stage, incoming=10, outgoing=2, state='OK', **attributes):
    attrs = {'gen_ai.operation.name': 'chat', 'gen_ai.response.model': 'demo-model',
             'runledger.run_id': 'review-demo', 'runledger.task_id': 'q1',
             'runledger.stage': stage, 'gen_ai.usage.input_tokens': incoming,
             'gen_ai.usage.output_tokens': outgoing}
    attrs.update(attributes)
    return {'context': {'trace_id': '1234567890abcdef1234567890abcdef', 'span_id': identity},
            'end_time': '2026-10-30T00:00:00Z', 'status': {'status_code': state}, 'attributes': attrs}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'reports/review-evidence')
    parser.add_argument('--date', required=True, help='Date of this run, e.g. 2026-10-30')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not EXE.is_file():
        parser.error('Build the native CLI first: moon build --target native')
    manifest = dict(run_id='review-demo', model='demo-model', task_ids=['q1'],
                    required_stages=['answer', 'review'])
    answer, review = call('a', 'answer'), call('r', 'review', 4, 1)
    results = []

    def case(name, rows, totals, codes, description, tasks=None, sdk=False,
             complete=None, group_available=None, reverse=False):
        destination = output / name
        destination.mkdir(exist_ok=True)
        expected = dict(manifest, task_ids=tasks or ['q1'])
        write_json(destination / 'manifest.json', expected)
        data = destination / 'input.jsonl'
        data.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows), encoding='utf-8')
        command = 'audit-spans' if sdk else 'audit-detail'
        proc = subprocess.run([str(EXE), command, str(data), str(destination / 'manifest.json')],
                              cwd=ROOT, capture_output=True, text=True, check=False)
        envelope = json.loads(proc.stdout)
        report = envelope if sdk else envelope['report']
        actual = dict(report['totals'])
        actual = {k: int(v) for k, v in actual.items()}
        for key, value in totals.items():
            assert actual[key] == value, (name, key, actual[key], value)
        actual_codes = sorted(f['code'] for f in report['findings'])
        assert actual_codes == sorted(codes), (name, actual_codes, codes)
        assert report['ok'] == (not codes), name
        assert proc.returncode == (1 if codes else 0), (name, proc.returncode)
        if complete is not None:
            assert report['usage_complete'] == complete, name
        if group_available is not None:
            assert envelope['group_totals_available'] == group_available, name
            if not group_available:
                assert envelope['groups'] == [], name
        write_json(destination / 'report.json', envelope)
        if reverse:
            data_reverse = destination / 'reversed.jsonl'
            data_reverse.write_text(''.join(json.dumps(row) + '\n' for row in reversed(rows)))
            second = subprocess.run([str(EXE), command, str(data_reverse), str(destination / 'manifest.json')],
                                    cwd=ROOT, capture_output=True, text=True, check=False)
            reverse_report = json.loads(second.stdout)['report']
            assert reverse_report['totals'] == report['totals']
            assert sorted(f['code'] for f in reverse_report['findings']) == actual_codes
            assert second.returncode == proc.returncode
            write_json(destination / 'reversed-report.json', json.loads(second.stdout))
        result = {'name': name, 'description': description, 'command': command,
                  'exit_code': proc.returncode, 'totals': actual, 'diagnostic_codes': actual_codes,
                  'usage_complete': report['usage_complete'], 'expected_checks_passed': True,
                  'input_sha256': hashlib.sha256(data.read_bytes()).hexdigest()}
        results.append(result)

    case('01-clean-control', [answer, review], {'calls': 2, 'input_tokens': 14, 'output_tokens': 3}, [],
         'Known-complete control: successful answer and review.', complete=True)
    case('02-conflicting-identity', [answer, call('a', 'answer', 11), review],
         {'calls': 1, 'input_tokens': 4, 'output_tokens': 1}, ['conflicting_call', 'missing_stage'],
         'Exclude both conflicting copies from accounting and coverage; reverse-order totals agree.',
         complete=False, reverse=True)
    case('03-failed-attempt-and-retry', [call('failed', 'answer', 100, 20, status='error'), answer, review],
         {'calls': 3, 'input_tokens': 114, 'output_tokens': 23, 'failed_calls': 1}, [],
         'Retain known usage of failed attempts while a successful retry satisfies stage coverage.', complete=True)
    case('04-directional-unknown-usage', [call('a', 'answer', None, 2), review],
         {'calls': 2, 'input_tokens': 4, 'output_tokens': 3, 'unknown_usage_calls': 1}, ['missing_usage'],
         'Missing input remains unknown even though both successful stages are present.', complete=False)
    case('05-wholly-missing-task', [answer, review], {'calls': 2, 'input_tokens': 14},
         ['missing_stage', 'missing_stage'],
         'An independent manifest detects q2 even when q2 never occurs in the log.',
         tasks=['q1', 'q2'], complete=True)
    case('06-sdk-unset-status', [span('0000000000000001', 'answer', state='UNSET'),
                              span('0000000000000002', 'review', 4, 1)],
         {'calls': 1, 'input_tokens': 4}, ['invalid_span', 'missing_stage'],
         'Do not turn an SDK UNSET status into evidence of successful answer completion.', sdk=True, complete=False)
    case('07-conflicting-semantic-usage',
         [span('0000000000000001', 'answer', 100, 20, **{'llm.token_count.prompt': 60}),
          span('0000000000000002', 'review', 4, 1)],
         {'calls': 1, 'input_tokens': 4}, ['invalid_span', 'missing_stage'],
         'Reject disagreeing GenAI/OpenInference input-token totals rather than silently choosing one.',
         sdk=True, complete=False)
    case('08-inclusive-cache-usage',
         [span('0000000000000001', 'answer', 100, 20, **{'gen_ai.usage.cache_read.input_tokens': 40}),
          span('0000000000000002', 'review', 4, 1)],
         {'calls': 2, 'input_tokens': 104, 'output_tokens': 21}, [],
         'Do not add cache detail to an already-inclusive GenAI input-token total.', sdk=True, complete=True)
    case('09-unsafe-aggregate', [call('a', 'answer', 9007199254740991, 0), call('r', 'review', 1, 0)],
         {'calls': 2, 'input_tokens': 9007199254740991}, ['aggregate_overflow'],
         'Reject an unsafe aggregate and explicitly withhold group totals; avoid misleading reconciled sums.',
         complete=False, group_available=False)
    reference = subprocess.check_output(['git', 'log', '-1', '--format=%H', '--', '*.mbt', 'moon.mod', 'moon.pkg'],
                                        cwd=ROOT, text=True).strip()
    implementation_diff = subprocess.check_output(['git', 'diff', 'HEAD', '--', '*.mbt', 'moon.mod', 'moon.pkg'], cwd=ROOT)
    write_json(output / 'summary.json', {'schema_version': 1, 'date_Asia_Shanghai': args.date,
        'implementation_reference_commit': reference, 'implementation_has_uncommitted_diff': bool(implementation_diff),
        'executable_sha256': hashlib.sha256(EXE.read_bytes()).hexdigest(),
        'synthetic_data': True, 'real_model_calls': False, 'competition_approval': False,
        'purpose': 'Bounded technical demonstrations of existing 0.2.0 behavior; not new core functionality.',
        'cases': results})
    print(f'{len(results)} synthetic review cases passed; one conflict case also checked in reverse order: {output}')


if __name__ == '__main__':
    main()
