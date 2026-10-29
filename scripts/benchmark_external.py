"""Compare same-build in-memory vs external audit; synthetic data, no model calls."""
import argparse
import hashlib
import json
import math
import os
import pathlib
import platform
import shutil
import subprocess
import time

ROOT=pathlib.Path(__file__).resolve().parents[1]


def digest(path):
    result=hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''): result.update(block)
    return result.hexdigest()


def measure(command, stdout, stderr):
    start=time.perf_counter()
    with stdout.open('wb') as out, stderr.open('wb') as err:
        child=subprocess.Popen(command,cwd=ROOT,stdout=out,stderr=err)
        _,status,usage=os.wait4(child.pid,0)
        child.returncode=os.waitstatus_to_exitcode(status)
    if child.returncode:
        raise RuntimeError(f'exit={child.returncode}: {stdout.read_text()} {stderr.read_text()}')
    rss_bytes=usage.ru_maxrss if platform.system()=='Darwin' else usage.ru_maxrss*1024
    return {'wall_seconds':time.perf_counter()-start,'peak_rss_bytes':rss_bytes,'exit_code':child.returncode}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--sizes',nargs='+',type=int,default=[20000,200000])
    parser.add_argument('--release',action='store_true')
    parser.add_argument('--output',type=pathlib.Path,default=ROOT/'reports/external-benchmark')
    args=parser.parse_args()
    if not hasattr(os,'wait4'): parser.error('POSIX wait4 required for per-child peak RSS')
    profile='release' if args.release else 'debug'
    binaries=ROOT/f'_build/native/{profile}/build/cmd'
    legacy=binaries/'runledger/runledger.exe';external=binaries/'runledger-large/runledger-large.exe'
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
    # Freeze executable copies so concurrent rebuilds cannot change what is measured.
    frozen=output/'binaries';frozen.mkdir(exist_ok=True)
    for executable,name in [(legacy,'in-memory.exe'),(external,'external.exe')]:
        before=digest(executable)
        shutil.copy2(executable,frozen/name)
        if digest(frozen/name)!=before or digest(executable)!=before:
            raise RuntimeError('Executable changed while snapshotting; finish builds first')
    legacy=frozen/'in-memory.exe';external=frozen/'external.exe'
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip())
    results=[]
    for size in args.sizes:
        if size<1 or size>2000000: parser.error('sizes must be in 1..2000000')
        if math.gcd(size,104729)!=1: parser.error('size must be coprime to 104729')
        case=output/str(size);case.mkdir(exist_ok=True)
        source=case/'calls.jsonl'
        with source.open('w',encoding='utf-8') as f:
            for index in range(size):
                identity=(index*104729)%size
                row=dict(run_id='large-demo',task_id='q'+str(identity//2),
                         stage='answer' if identity%2==0 else 'review',call_id='req-'+str(identity),
                         model='demo-model',status='ok',input_tokens=100+identity%5,output_tokens=20)
                f.write(json.dumps(row,separators=(',',':'))+'\n')
        ordinary=measure([str(legacy),'audit',str(source)],case/'in-memory.json',case/'in-memory.stderr')
        work=case/'workspace'
        if work.exists(): raise RuntimeError('Benchmark workspace exists; choose fresh sizes or archive reports first')
        bounded=measure([str(external),str(source),str(work)],case/'external.json',case/'external.stderr')
        a=json.loads((case/'in-memory.json').read_text());b=json.loads((case/'external.json').read_text())['report']
        assert a['ok'] and b['ok'] and a['usage_complete'] and b['usage_complete']
        assert a['totals']==b['totals']
        assert a['totals']['calls']==size
        assert int(a['totals']['input_tokens'])==100*size+sum(i%5 for i in range(size))
        results.append({'calls':size,'input_bytes':source.stat().st_size,'input_sha256':digest(source),
                        'in_memory':ordinary,'external':bounded,'totals':a['totals'],'totals_equal':True,
                        'workspace_bytes':sum(p.stat().st_size for p in work.iterdir() if p.is_file())})
        print(json.dumps(results[-1]),flush=True)
    summary={'source_commit':commit,'working_tree_dirty':dirty,'system':platform.system(),
             'machine':platform.machine(),'profile':'native-'+profile,'method':'One run per mode/size; POSIX wait4 per-child peak RSS and end-to-end wall time. No medians or production guarantee.',
             'binary_sha256':{'in_memory':digest(legacy),'external':digest(external)},
             'benchmark_binaries_are_immutable_copies':True,
             'synthetic_data':True,'real_model_calls':False,'manifest_used':False,
             'limitations':'Batch bytes is a working-set target, not a hard RSS cap; manifest memory and output disk are separate. External audit trades I/O and time for lower RAM. No OOM, streaming provider, or real-user claim.',
             'results':results}
    (output/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(output/'results.json')


if __name__=='__main__': main()
