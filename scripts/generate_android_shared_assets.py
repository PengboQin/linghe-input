#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Derive Android's public vocabulary from the existing Apple-owned sources."""
from pathlib import Path
import re,json
root=Path(__file__).resolve().parents[1]
output=root/'build/android-app/assets';output.mkdir(parents=True,exist_ok=True)
english=(root/'shared/PrivateInputKit/Sources/PrivateInputKit/MixedEnglishLexicon.swift').read_text().split('"""')[1].split()
assert 100<=len(english)<=1000 and all(re.fullmatch('[A-Za-z]{2,32}',v) for v in english)
p=output/'mixed-english.txt';value='\n'.join(english)+'\n'
if not p.exists() or p.read_text()!=value:p.write_text(value)
source=(root/'apple/iOS/Keyboard/SymbolCatalog.swift').read_text();categories=[]
for m in re.finditer(r'category\("([^"]+)",\s*"([^"]+)",\s*"((?:\\.|[^"\\])*)"\)',source):
 raw=json.loads('"'+m[3]+'"');categories.append({'id':m[1],'title':m[2],'symbols':list(dict.fromkeys(raw))})
assert len(categories)==12
value=json.dumps({'version':1,'source':'apple/iOS/Keyboard/SymbolCatalog.swift','categories':categories},ensure_ascii=False,indent=2)
for p in [root/'shared/contracts/symbol-catalog-v1.json',output/'symbols.json']:
 if not p.exists() or p.read_text()!=value:p.write_text(value)
print('Derived native assets:',len(english),'English words;',len(categories),'symbol categories')
