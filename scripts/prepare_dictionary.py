#!/usr/bin/env python3
"""Rebuild the pinned public LGPL dictionary; no private lexicons or installers."""
import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from mainland_lexicon_policy import candidate_allowed, candidate_tier, POLICY, DATA, SOURCE

ROOT = Path(__file__).resolve().parents[1]

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.absolute()
    if not output.resolve().is_relative_to(ROOT / 'build') or output.exists():
        raise SystemExit('Output must be a new app-owned build directory; existing data preserved')
    lock = json.loads((ROOT/'docs/stages/P2/dictionary/upstream.lock.json').read_text())
    sources = {}
    for repo in lock['repositories']:
        name = repo['repository'].split('/')[-1]
        directory = ROOT/'vendor/dictionaries'/name/repo['revision']
        for item in repo['files']:
            if digest(directory/item['path']) != item['sha256']: raise SystemExit('Public source digest differs from lock')
        sources[name] = directory
    output.mkdir(parents=True)
    conversion = output.parent/(output.name+'-conversion'); conversion.mkdir()
    tools = ROOT/'build/deps/macos-arm64/opencc/src/tools'
    data = ROOT/'vendor/librime/deps/opencc/data'
    opencc_sha = subprocess.check_output(['git','rev-parse','HEAD'],cwd=data.parent,text=True).strip()
    expected = next(x['commit'] for x in json.loads((ROOT/'docs/stages/P1/dependencies.lock.json').read_text()) if x['name']=='opencc')
    if opencc_sha != expected: raise SystemExit('OpenCC differs from the project lock')
    if subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],cwd=data.parent,text=True).strip():
        raise SystemExit('OpenCC source has local edits; preserved without rebuilding')
    converter_files = []
    for name in ['TSCharacters','TSPhrases']:
        original = data/'dictionary'/(name+'.txt'); compiled = conversion/(name+'.ocd2')
        subprocess.run([tools/'opencc_dict','-i',original,'-o',compiled,'-f','text','-t','ocd2'],check=True)
        converter_files.append({'source':str(original.relative_to(ROOT)),'sha256':digest(original),'compiledSHA256':digest(compiled)})
    config = json.loads((data/'config/t2s.json').read_text())
    def locate(value):
        if isinstance(value,dict):
            for key,child in value.items():
                if key=='file':value[key]=str(conversion/child)
                else:locate(child)
        elif isinstance(value,list):
            for child in value:locate(child)
    locate(config)
    configuration=conversion/'t2s.json';configuration.write_text(json.dumps(config))
    for source,target in [(sources['rime-luna-pinyin']/'luna_pinyin.dict.yaml',conversion/'luna-simp.yaml'),
                          (sources['rime-essay']/'essay.txt',conversion/'essay-simp.txt')]:
        subprocess.run([tools/'opencc','-c',configuration,'-i',source,'-o',target,'--noflush','1'],check=True)
    # Conversion can collapse traditional variants. Do not sum weights and
    # accidentally amplify duplicated source entries; preserve default weights
    # or take the maximum within the same explicit weight representation.
    original=(conversion/'luna-simp.yaml').read_text()
    head,body=original.split('\n...\n',1);records={};duplicates=0;excluded_dictionary=0;tier3_rows=0
    for line in body.splitlines():
        if not line or line.startswith('#'):continue
        fields=line.split('\t')
        if len(fields) not in [2,3] or not fields[0] or not re.fullmatch('[a-z]+(?: [a-z]+)*',fields[1]):
            raise SystemExit('Unexpected dictionary record; output not promoted')
        if not candidate_allowed(fields[0]):
            excluded_dictionary+=1;continue
        key=tuple(fields[:2]);weight=fields[2] if len(fields)==3 else ''
        if candidate_tier(fields[0]) == 3:
            weight='1';tier3_rows+=1
        if key in records:
            duplicates+=1;old=records[key]
            if not old or not weight:weight=''
            else:
                if old.endswith('%') != weight.endswith('%'):raise SystemExit('Mixed explicit weight representations')
                weight=max([old,weight],key=lambda x:Decimal(x.rstrip('%')))
        records[key]=weight
    # Public-domain classical lines and project-authored common phrases.
    for line in (ROOT/'resources/phrases/classics.tsv').read_text().splitlines():
        if not line or line.startswith('#'): continue
        word, reading = line.split('\t')
        if not re.fullmatch('[a-z]+(?: [a-z]+)*', reading): raise SystemExit('Invalid supplemental reading')
        if not candidate_allowed(word):
            excluded_dictionary+=1;continue
        records[(word, reading)] = '1' if candidate_tier(word)==3 else '100000'
    # Small project-authored recall supplement. This is availability, not a
    # forced top slot. Preserve any higher existing base-dictionary weight.
    supplement_rows=0
    for line in (ROOT/'resources/phrases/common-platforms.tsv').read_text().splitlines():
        if not line or line.startswith('#'):continue
        word,reading,weight=line.split('\t')
        if not candidate_allowed(word) or not re.fullmatch('[a-z]+(?: [a-z]+)*',reading):
            raise SystemExit('Invalid mainland public recall supplement')
        if not weight.isdigit() or not 1<=int(weight)<=500:raise SystemExit('Unexpected public recall base weight')
        key=(word,reading)
        if key not in records:records[key]='1' if candidate_tier(word)==3 else weight;supplement_rows+=1
    head=head.replace('name: luna_pinyin','name: private_pinyin')
    head=re.sub(r'version:.*',"version: '2026.10.21-mainland1'",head)
    note='# Modified by Private Input on 2026-10-21: pinned OpenCC t2s; 8105 mainland standard-character admission; variant deduplication. LGPL-3.0.\n'
    with (output/'private_pinyin.dict.yaml').open('w') as stream:
        stream.write(note+head+'\n...\n')
        for (word,reading),weight in sorted(records.items()):
            stream.write(word+'\t'+reading+('' if not weight else '\t'+weight)+'\n')
    frequencies={};essay_duplicates=0;excluded_vocabulary=0
    for line in (conversion/'essay-simp.txt').read_text().splitlines():
        word,count=line.split('\t');count=int(count)
        if count<0 or '\0' in word:raise SystemExit('Unexpected vocabulary record')
        if not candidate_allowed(word):
            excluded_vocabulary+=1;continue
        if candidate_tier(word)==3:count=min(count,1)
        if word in frequencies:essay_duplicates+=1
        frequencies[word]=max(count,frequencies.get(word,0))
    with (output/'essay.txt').open('w') as stream:
        for word,count in sorted(frequencies.items()):stream.write(word+'\t'+str(count)+'\n')
    for name in ['default.yaml','private_pinyin.schema.yaml','private_pinyin_private.schema.yaml','private_pinyin_exact.schema.yaml','private_nine.schema.yaml','private_nine_private.schema.yaml','private_nine_initials.schema.yaml']:
        text=(ROOT/'resources/rime'/name).read_text().replace("'0.1.0'","'0.2.0'")
        (output/name).write_text(text)
    charset=output/'charset';charset.mkdir()
    for source in DATA.parent.iterdir():
        if source.is_file():shutil.copy2(source,charset/source.name)
    notices=output/'licenses';notices.mkdir()
    for name,directory in sources.items():
        for document in ['LICENSE','AUTHORS']:
            shutil.copy2(directory/document,notices/(name+'-'+document))
    shutil.copy2(ROOT/'vendor/dictionaries/licenses/GPL-3.0.txt',notices/'GPL-3.0.txt')
    manifest={'version':1,'modifiedDate':'2026-10-21','license':'LGPL-3.0; preserve pinned upstream notices and corresponding source',
              'characterPolicy':{'id':POLICY,'source':json.loads(SOURCE.read_text()),'excludedDictionaryRows':excluded_dictionary,'excludedVocabularyWords':excluded_vocabulary,'tier3RowsCapped':tier3_rows,'tier3BaseWeightCap':1,'publicRecallRowsAdded':supplement_rows,'publicRecallSource':'resources/phrases/common-platforms.tsv'},
              'upstream':lock,'openccCommit':opencc_sha,'conversionFiles':converter_files,
              'dictionaryRows':len(records),'dictionaryDuplicatesCollapsed':duplicates,
              'vocabularyWords':len(frequencies),'vocabularyDuplicatesCollapsed':essay_duplicates,
              'policy':'t2s before compilation; only standard 8105 Chinese characters; tier3 base weight at most 1; retain other default dictionary weights or same-type maximum; vocabulary maximum for collapsed variants; no network/compilation in typing path',
              'generated':[{ 'path':str(p.relative_to(output)), 'bytes':p.stat().st_size,'sha256':digest(p)} for p in sorted(output.rglob('*')) if p.is_file()]}
    (output/'SOURCE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({k:manifest[k] for k in ['dictionaryRows','dictionaryDuplicatesCollapsed','vocabularyWords','vocabularyDuplicatesCollapsed']}))

if __name__=='__main__':main()
