#!/usr/bin/env python3
"""Derive a read-only, bounded nine-key code/frequency index from pinned Rime data.
No host text, user dictionary, network access or training data enters this build.
"""
import pathlib,re,itertools,struct,json,hashlib
root=pathlib.Path(__file__).resolve().parents[1];rime=root/'resources/rime';out=root/'resources/semantic';out.mkdir(parents=True,exist_ok=True)
letters=dict(zip('abcdefghijklmnopqrstuvwxyz','22233344455566677778889999'))
def encode(reading):return ''.join(letters[c] for c in reading if c!=' ')
def key(code):
 value=0
 for c in code:value=(value<<3)|(int(c)-2)
 return (len(code)<<54)|value
readings={}
for line in (rime/'private_pinyin.dict.yaml').read_text().splitlines():
 cols=line.split('\t')
 if len(cols)>=2 and len(cols[0])==1 and re.fullmatch('[a-z ]+',cols[1]):
  code=encode(cols[1]);group=readings.setdefault(cols[0],[])
  if code and code not in group:group.append(code)
words=[]
for line in (rime/'essay.txt').read_text().splitlines():
 cols=line.split('\t')
 if len(cols)>=2 and 2<=len(cols[0])<=4 and all('\u4e00'<=c<='\u9fff' and c in readings for c in cols[0]):
  try:frequency=int(cols[1])
  except ValueError:continue
  if frequency>=3:words.append((cols[0],frequency))
words.sort(key=lambda x:(-x[1],x[0]));codes={}
for word,frequency in words[:60000]:
 for parts in itertools.islice(itertools.product(*(readings[c][:4] for c in word)),16):
  code=''.join(parts)
  if len(code)<=18:codes[key(code)]=max(codes.get(key(code),0),min(frequency,2**32-1))
payload=bytearray(b'PI9LEX01')+struct.pack('<II',len(codes),12)
for value,frequency in sorted(codes.items()):payload+=struct.pack('<QI',value,frequency)
(out/'nine-lexicon.bin').write_bytes(payload)
info={'format':'PI9LEX01','words':min(len(words),60000),'codeCount':len(codes),'bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest(),'sourceFiles':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [rime/'private_pinyin.dict.yaml',rime/'essay.txt']},'license':'LGPL-3.0, derived from bundled pinned Rime dictionaries; original notices preserved'}
(out/'LEXICON.json').write_text(json.dumps(info,indent=2)+'\n');print(info)
