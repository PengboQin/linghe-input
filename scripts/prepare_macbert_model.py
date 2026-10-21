#!/usr/bin/env python3
"""Read-only audit of the Mac-only pinned model. Build recipe lives in experiments/macbert."""
import pathlib,json,hashlib
root=pathlib.Path(__file__).resolve().parents[1];folder=root/'resources/semantic-mac';manifest=json.loads((folder/'MODEL.json').read_text());lock=json.loads((root/'docs/stages/P2/dictionary/macbert.lock.json').read_text())
assert manifest['upstream']==lock['model'] and manifest['revision']==lock['revision']
for name,digest in manifest['files'].items():
 p=folder/name;assert p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==digest,name
assert not list((root/'apple/iOS').rglob('*MacBERT*'))
print(json.dumps({'verifiedFiles':len(manifest['files']),'revision':manifest['revision'],'compiledBytes':sum(p.stat().st_size for p in (folder/'MacBERT.mlmodelc').rglob('*') if p.is_file())}))
