#!/usr/bin/env python3
"""Rebuild the pinned public dictionary with the audited modern carrier policy; no private lexicons or installers."""
import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from mainland_lexicon_policy import candidate_allowed, candidate_tier, POLICY, DATA, SOURCE
from dictionary_reading_projection import ReadingProjection
import modern_reading_reference as modern_readings

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
    raw_rows=list(modern_readings.dictionary_rows(sources['rime-luna-pinyin']/'luna_pinyin.dict.yaml'))
    converted_rows=[line for line in body.splitlines() if line and not line.startswith('#')]
    if len(raw_rows)!=len(converted_rows):raise SystemExit('Converted source alignment differs; no resource promoted')
    reading_projection=ReadingProjection()
    for source_row,line in zip(raw_rows,converted_rows):
        if not line or line.startswith('#'):continue
        fields=line.split('\t')
        if len(fields) not in [2,3] or not fields[0] or not re.fullmatch('[a-z]+(?: [a-z]+)*',fields[1]):
            raise SystemExit('Unexpected dictionary record; output not promoted')
        projected=reading_projection.project(source_row[0],fields[0],fields[1],fields[2] if len(fields)==3 else '')
        if projected is None:
            excluded_dictionary+=1;continue
        word,reading,weight=projected
        if not candidate_allowed(word):
            excluded_dictionary+=1;continue
        fields=[word,reading]
        key=(word,reading)
        if candidate_tier(fields[0]) == 3:
            weight='1';tier3_rows+=1
        if key in records:
            duplicates+=1;old=records[key]
            if not old or not weight:weight=''
            else:
                if old.endswith('%') != weight.endswith('%'):raise SystemExit('Mixed explicit weight representations')
                weight=max([old,weight],key=lambda x:Decimal(x.rstrip('%')))
        records[key]=weight
    for character,readings in reading_projection.allowed.items():
        for reading in readings:
            key=(character,reading)
            if key not in records:
                records[key]='1' if candidate_tier(character)==3 else reading_projection.character_weight(character,reading)
    # Public-domain classical lines and project-authored common phrases.
    for line in (ROOT/'resources/phrases/classics.tsv').read_text().splitlines():
        if not line or line.startswith('#'): continue
        word, reading = line.split('\t')
        if not re.fullmatch('[a-z]+(?: [a-z]+)*', reading): raise SystemExit('Invalid supplemental reading')
        if not candidate_allowed(word):
            excluded_dictionary+=1;continue
        projected=reading_projection.project(word,word,reading,'100000')
        if projected is None:
            excluded_dictionary+=1;continue
        word,reading,weight=projected
        records[(word, reading)] = '1' if candidate_tier(word)==3 else weight
    # Small project-authored recall supplement. This is availability, not a
    # forced top slot. Preserve any higher existing base-dictionary weight.
    supplement_rows=0
    for line in (ROOT/'resources/phrases/common-platforms.tsv').read_text().splitlines():
        if not line or line.startswith('#'):continue
        word,reading,weight=line.split('\t')
        if not candidate_allowed(word) or not re.fullmatch('[a-z]+(?: [a-z]+)*',reading):
            raise SystemExit('Invalid mainland public recall supplement')
        if not weight.isdigit() or not 1<=int(weight)<=500:raise SystemExit('Unexpected public recall base weight')
        projected=reading_projection.project(word,word,reading,weight)
        if projected is None:
            excluded_dictionary+=1;continue
        word,reading,weight=projected
        key=(word,reading)
        if key not in records:records[key]='1' if candidate_tier(word)==3 else weight;supplement_rows+=1
    head=head.replace('name: luna_pinyin','name: private_pinyin')
    head=re.sub(r'version:.*',"version: '2026.10.23-modern-carriers1'",head)
    note='# Modified by Private Input on 2026-10-23: pinned t2s and modern carrier reading/weight projection; combined GPL-3.0, original Luna portions LGPL-3.0.\n'
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
    shutil.copy2(modern_readings.REFERENCE/'LICENSE',notices/'rime-ice-LICENSE')
    manifest={'version':1,'modifiedDate':'2026-10-23','license':'GPL-3.0 combined reading projection; Luna/essay portions retain LGPL-3.0 notices; preserve corresponding pinned sources',
              'characterPolicy':{'id':POLICY,'source':json.loads(SOURCE.read_text()),'excludedDictionaryRows':excluded_dictionary,'excludedVocabularyWords':excluded_vocabulary,'tier3RowsCapped':tier3_rows,'tier3BaseWeightCap':1,'publicRecallRowsAdded':supplement_rows,'publicRecallSource':'resources/phrases/common-platforms.tsv'},
              'upstream':lock,'readingPolicy':{'id':modern_readings.POLICY,'reference':modern_readings.reference_metadata(),'statistics':reading_projection.stats,'scope':'Only conversion-affected carriers; community reference, not an official pronunciation standard'},'openccCommit':opencc_sha,'conversionFiles':converter_files,
              'dictionaryRows':len(records),'dictionaryDuplicatesCollapsed':duplicates,
              'vocabularyWords':len(frequencies),'vocabularyDuplicatesCollapsed':essay_duplicates,
              'policy':'pinned t2s with standard original carriers restored; modern affected-carrier reading admission and normalized per-character reading priors; unambiguous public word annotations projected offline; standard8105/tier3 cap retained; vocabulary maximum for collapsed variants; never touches private data or typing path',
              'generated':[{ 'path':str(p.relative_to(output)), 'bytes':p.stat().st_size,'sha256':digest(p)} for p in sorted(output.rglob('*')) if p.is_file()]}
    (output/'SOURCE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({k:manifest[k] for k in ['dictionaryRows','dictionaryDuplicatesCollapsed','vocabularyWords','vocabularyDuplicatesCollapsed']}))

if __name__=='__main__':main()
