#!/usr/bin/env python3
"""Run the actual C++ validator against canonical synthetic Swift/Python cases.
Negative integer JSON is quoted in the wrapper so the unsigned archive parser
can reject each original payload, instead of rejecting the whole fixture file.
No installed device, credentials, clipboard, server or input source is accessed.
"""
import argparse, json, pathlib, subprocess, tempfile
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--fixture',required=True);a=p.parse_args()
cases=json.loads(pathlib.Path(a.fixture).read_text())['cases']
with tempfile.TemporaryDirectory(prefix='decision-synthetic-') as folder:
    wrapper=pathlib.Path(folder)/'cases.json'
    wrapper.write_text(json.dumps([{'name':c['name'],'valid':c['valid'],'event_json':json.dumps(c['event'],ensure_ascii=False)} for c in cases],ensure_ascii=False))
    subprocess.run([a.binary,str(wrapper),str(pathlib.Path(folder)/'queue.sqlite')],check=True)
