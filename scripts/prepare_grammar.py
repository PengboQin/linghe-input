#!/usr/bin/env python3
"""Fetch only pinned grammar source/data bytes; never execute upstream installers."""
import argparse, hashlib, json, pathlib, shutil, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]

def fetch(url,digest,destination,cache=None):
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest()==digest:return
    if cache is not None and cache.exists() and hashlib.sha256(cache.read_bytes()).hexdigest()==digest:
        destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(cache,destination);return
    data=urllib.request.urlopen(url,timeout=60).read()
    if hashlib.sha256(data).hexdigest()!=digest:raise RuntimeError('Pinned public dependency hash mismatch')
    destination.parent.mkdir(parents=True,exist_ok=True);destination.write_bytes(data)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,default=ROOT/'resources/rime');a=p.parse_args()
    lock=json.loads((ROOT/'docs/stages/P2/dictionary/grammar.lock.json').read_text())
    for source in lock['sourceFiles']:fetch(source['url'],source['sha256'],ROOT/source['path'])
    model=lock['model'];output=a.output.absolute()
    fetch(model['url'],model['sha256'],output/'private_zh_hans_compact.gram',ROOT/'resources/rime/private_zh_hans_compact.gram')
    fetch(model['licenseURL'],model['licenseSHA256'],output/'licenses/rime-octagram-data-LICENSE',ROOT/'resources/rime/licenses/rime-octagram-data-LICENSE')
    (output/'licenses/librime-octagram-LICENSE').write_bytes((ROOT/'vendor/librime-octagram/LICENSE').read_bytes())
    manifest=output/'SOURCE.json';data=json.loads(manifest.read_text());data['grammar']=lock
    for name in ['private_zh_hans_compact.gram','licenses/rime-octagram-data-LICENSE','licenses/librime-octagram-LICENSE']:
        file=output/name;item={'path':name,'bytes':file.stat().st_size,'sha256':hashlib.sha256(file.read_bytes()).hexdigest()}
        data['generated']=[entry for entry in data['generated'] if entry['path']!=name]+[item]
    manifest.write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps({'modelBytes':model['bytes'],'verified':True,'upstreamInstallersExecuted':False}))

if __name__=='__main__':main()
