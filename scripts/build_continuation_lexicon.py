#!/usr/bin/env python3
"""Bounded next-word recall from the bundled, pinned public Rime essay only."""
import pathlib,struct,collections,hashlib,json
root=pathlib.Path(__file__).resolve().parents[1];source=root/'resources/rime/essay.txt';out=root/'resources/semantic'
pairs=collections.defaultdict(dict);words=[]
def key(s):
 value=0
 for c in s:value=(value<<16)|ord(c)
 return (len(s)<<48)|value
for line in source.read_text().splitlines():
 cols=line.split('\t')
 if len(cols)<2 or not 2<=len(cols[0])<=7 or not all('\u4e00'<=c<='\u9fff' for c in cols[0]):continue
 try:freq=int(cols[1])
 except ValueError:continue
 if freq<50:continue
 words.append((cols[0],freq))
for word,freq in sorted(words,key=lambda x:(-x[1],x[0]))[:60000]:
 for size in range(1,min(3,len(word)-1)+1):
  tail=word[size:]
  if len(tail)>4:continue
  group=pairs[key(word[:size])];group[tail]=max(group.get(tail,0),min(freq,2**32-1))
records=[];strings=bytearray()
for k,group in sorted(pairs.items()):
 for text,freq in sorted(group.items(),key=lambda x:(-x[1],x[0]))[:6]:
  data=text.encode();records.append((k,len(strings),len(data),0,freq));strings+=data
payload=b'PINEXT01'+struct.pack('<II',len(records),20)+b''.join(struct.pack('<QIHHI',*r) for r in records)+strings
(out/'continuation.bin').write_bytes(payload)
info={'format':'PINEXT01','records':len(records),'prefixes':len(pairs),'bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest(),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'license':'LGPL-3.0, derived from bundled pinned rime-essay; original license remains bundled','method':'Public word prefix continuation; not a generated sentence or conversational training corpus'}
(out/'CONTINUATION.json').write_text(json.dumps(info,indent=2)+'\n');print(info)
