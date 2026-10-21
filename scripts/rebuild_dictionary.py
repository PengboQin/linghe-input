#!/usr/bin/env python3
"""Prepare, compile and verify public dictionary resources in a new owned directory."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path);args=parser.parse_args()
    output=args.output.absolute();prefix=ROOT/'build/rime/macos-arm64'
    subprocess.run(['python3',ROOT/'scripts/prepare_dictionary.py','--output',output],check=True)
    if (ROOT/'docs/stages/P2/dictionary/grammar.lock.json').exists():
        subprocess.run(['python3',ROOT/'scripts/prepare_grammar.py','--output',output],check=True)
    binary=output.parent/(output.name+'-compiler-smoke')
    subprocess.run(['xcrun','clang++','-std=c++17','-O2','-I'+str(ROOT/'core/include'),'-I'+str(ROOT/'vendor/librime/src'),'-I'+str(prefix/'include'),
                    ROOT/'core/src/private_input.cpp',ROOT/'core/tests/engine_smoke.cpp',
                    '-Wl,-force_load,'+str(prefix/'lib/librime.a'),'-L'+str(prefix/'lib'),
                    '-lyaml-cpp','-lleveldb','-lmarisa','-lopencc','-o',binary],check=True)
    user=output.parent/(output.name+'-compile-user')
    subprocess.run([binary,output,user],check=True)
    compiled=output/'build';compiled.mkdir()
    names=['default.yaml','private_pinyin.prism.bin','private_pinyin.table.bin','private_pinyin.reverse.bin',
           'private_pinyin.schema.yaml','private_pinyin_private.schema.yaml','private_pinyin_exact.schema.yaml','private_pinyin_exact.prism.bin','private_nine.schema.yaml','private_nine_private.schema.yaml','private_nine.prism.bin','private_nine_initials.schema.yaml','private_nine_initials.prism.bin']
    for name in names:shutil.copy2(user/'build'/name,compiled/name)
    header=(compiled/'private_pinyin.table.bin').read_bytes()[:44]
    manifest=json.loads((output/'SOURCE.json').read_text())
    manifest['compiledFormat']=header[:32].split(b'\0')[0].decode()
    manifest['compiledEntries']=struct.unpack_from('<I',header,40)[0]
    manifest['compiledFiles']=[{'path':str(p.relative_to(output)),'bytes':p.stat().st_size,
                               'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(compiled.iterdir())]
    (output/'SOURCE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    fresh=output.parent/(output.name+'-prebuilt-user')
    subprocess.run([binary,output,fresh,'NO_DEPLOY'],check=True)
    print(json.dumps({'compiledEntries':manifest['compiledEntries'],'prebuiltNoDeployPassed':True,
                      'output':str(output.relative_to(ROOT)),'promotedToClient':False}))

if __name__=='__main__':main()
