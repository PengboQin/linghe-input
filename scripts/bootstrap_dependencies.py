#!/usr/bin/env python3
"""Fetch pinned public sources and project-local build tools, preserving existing checkouts."""
from pathlib import Path
import hashlib
import json
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RIME_SHA = '33e78140250125871856cdc5b42ddc6a5fcd3cd4'
BOOST_SHA = '7009fe1faa1697476bdc7027703a2badb84e849b7b0baad5086b087b971f8617'

def run(command, cwd=ROOT):
    subprocess.run(command, cwd=cwd, check=True)

def main():
    (ROOT/'vendor').mkdir(exist_ok=True)
    source = ROOT/'vendor/librime'
    if not source.exists():
        run(['git','clone','--depth','1','--branch','1.17.0','https://github.com/rime/librime.git',str(source)])
    sha = subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()
    if sha != RIME_SHA: raise SystemExit('Existing Rime checkout differs from lock; preserved without reset')
    if subprocess.check_output(['git','status','--porcelain'],cwd=source,text=True).strip():
        raise SystemExit('Existing Rime checkout modified; preserved without update')
    run(['git','submodule','update','--init','--depth','1','deps/leveldb','deps/yaml-cpp','deps/marisa-trie','deps/opencc'],source)
    locks = json.loads((ROOT/'docs/stages/P1/dependencies.lock.json').read_text())
    for item in locks:
        if item['name'] in ['yaml-cpp','leveldb','marisa-trie','opencc']:
            path = source/'deps'/item['name']
            actual = subprocess.check_output(['git','rev-parse','HEAD'],cwd=path,text=True).strip()
            if actual != item['commit']: raise SystemExit('Dependency differs from lock: ' + item['name'])
    archive = ROOT/'vendor/boost_1_85_0.tar.bz2'
    if not archive.exists():
        urllib.request.urlretrieve('https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2',archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != BOOST_SHA:
        raise SystemExit('Boost source digest mismatch; archive was not extracted')
    if not (ROOT/'vendor/boost_1_85_0/boost').exists():
        with tarfile.open(archive) as tar:
            for item in tar.getmembers():
                if not (ROOT/'vendor'/item.name).resolve().is_relative_to((ROOT/'vendor').resolve()):
                    raise SystemExit('Invalid source archive path')
                if item.issym() or item.islnk():
                    target = (ROOT/'vendor'/item.name).parent/item.linkname
                    if not target.resolve().is_relative_to((ROOT/'vendor').resolve()): raise SystemExit('Invalid archive link')
            tar.extractall(ROOT/'vendor')
    tools = ROOT/'.tools/python'
    if not tools.exists(): run(['python3','-m','venv',str(tools)])
    run([str(tools/'bin/python'),'-m','pip','install','cmake==3.31.6','ninja==1.11.1.3'])
    print('Pinned sources verified; project-local tools ready. No global installation.')

if __name__ == '__main__': main()
