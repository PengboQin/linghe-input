#!/usr/bin/env python3
"""Isolated source-policy and old-native-dictionary regression; no user data."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]

def main():
    spec=importlib.util.spec_from_file_location('mainland',ROOT/'scripts/mainland_lexicon_policy.py')
    policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
    assert len(policy.TIERS)==8105
    assert [sum(v==tier for v in policy.TIERS.values()) for tier in (1,2,3)]==[3500,3000,1605]
    assert policy.generated_header()==(ROOT/'core/include/private_standard_characters.h').read_text()
    for text in ('后台干活台湾叶子','淘宝天猫微信抖音','西安重庆深圳','王梓涵龚玥','春眠不觉晓','apple','1.4','@example.com','😀','❤️','〇'):
        assert policy.candidate_allowed(text),text
    for text in ('後臺','發財','龍門','繁體','𨈖','𰻞','神','ㄅ','龘','\U000323B0','\U0003FFFF','一\U000E0100','一\U000E01EF',''):
        assert not policy.candidate_allowed(text),text
    build=ROOT/'build/mainland-policy';build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fixture-',dir=build) as temporary:
        fixture=Path(temporary);shared=fixture/'shared';shutil.copytree(ROOT/'fixtures/rime-p1',shared)
        # Simulates an obsolete dictionary / imported personal entries. All
        # rejected rows intentionally outrank valid simplified homophones.
        semantic=fixture/'semantic';semantic.mkdir()
        shutil.copy2(ROOT/'resources/semantic/pinyin-syllables.txt',semantic/'pinyin-syllables.txt')
        for schema in shared.glob('*.schema.yaml'):
            schema.write_text(schema.read_text().replace('  spelling_hints: 8\n','').replace('translator:\n','translator:\n  spelling_hints: 100\n  always_show_comments: true\n'))
        dictionary=shared/'private_pinyin.dict.yaml'
        with dictionary.open('a') as stream:
            for i,text in enumerate(['後臺','發財','龍門','繁體','𨈖','𰻞','龘','神','臺灣']):
                stream.write(text+'\thao\t'+str(900000000-i)+'\n')
            for text in ['皓','浩','豪','耗','毫']:
                stream.write(text+'\thao\t500\n')
        supplement=ROOT/'resources/phrases/common-platforms.tsv'
        rows=[line.split('\t') for line in supplement.read_text().splitlines() if line and not line.startswith('#')]
        assert all(len(row)==3 and policy.candidate_allowed(row[0]) and int(row[2])<=500 for row in rows)
        with dictionary.open('a') as stream:
            for word,reading,weight in rows:stream.write(word+'\t'+reading+'\t'+weight+'\n')
        prefix=ROOT/'build/rime/macos-arm64'
        binary=fixture/'policy-test'
        sources=[ROOT/'core/src/private_input.cpp',*list((ROOT/'core/include').glob('*.h'))]
        core_object=build/'core.o'
        if not core_object.is_file() or any(item.stat().st_mtime_ns>core_object.stat().st_mtime_ns for item in sources):
            subprocess.run(['xcrun','clang++','-std=c++17','-O0','-I'+str(ROOT/'core/include'),'-I'+str(prefix/'include'),'-c',str(ROOT/'core/src/private_input.cpp'),'-o',str(core_object)],check=True)
        command=['xcrun','clang++','-std=c++17','-O0','-I'+str(ROOT/'core/include'),'-I'+str(prefix/'include'),str(ROOT/'core/tests/mainland_candidate_policy.cpp'),str(build/'core.o'),'-Wl,-force_load,'+str(prefix/'lib/librime.a'),'-L'+str(prefix/'lib'),'-lyaml-cpp','-lleveldb','-lmarisa','-lopencc','-o',str(binary)]
        subprocess.run(command,check=True)
        result=subprocess.run([binary,shared,fixture/'user'],text=True,capture_output=True)
        evidence=ROOT/'evidence/mainland-lexicon-policy-20261021';evidence.mkdir(exist_ok=True)
        (evidence/'runtime.log').write_text(result.stdout+result.stderr)
        if result.returncode:raise RuntimeError((result.stdout+result.stderr)[-2500:])
        print(result.stdout.strip())
    print(json.dumps({'policy':'mainland-simplified-v1','characters':8105,'sourceVerified':True,'legacyDictionaryFiltered':True,'literalArchiveClipboardChanged':False,'installedAppsChanged':False}))

if __name__=='__main__':main()
