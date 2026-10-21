#!/usr/bin/env python3
"""Synthetic C++/frozen-server canonical + CryptoKit-compatible crypto vector check."""
import base64,hashlib,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
root=Path(__file__).resolve().parents[1]
server=Path(sys.argv[1]) if len(sys.argv)>1 else root/'windows/tests/activity/relay_fixture'
sys.path.insert(0,str(server.resolve()))
import clipboard_live
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey,Ed25519PrivateKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
import uuid
v=json.loads((root/'evidence/windows047-live-clipboard/cpp-vectors.json').read_text());assert v['synthetic'] is True
b=lambda x:base64.b64decode(x,validate=True)
checks=0
def check(value):
 global checks
 checks+=1
 assert value,checks
c=v['certificate'];e=v['event'];r=v['request'];revoke=v['revoke'];cb=clipboard_live.certificate_bytes(c);eb=clipboard_live.event_header(e);rb=clipboard_live.request_header(r);vb=clipboard_live.revoke_header(revoke)
for actual,key in [(cb,'certificateCanonical'),(eb,'eventHeader'),(rb,'requestHeader'),(vb,'revokeHeader')]:check(actual==b(v[key]))
check(clipboard_live.certificate_digest(c)==b(v['certificateDigest']))
Ed25519PublicKey.from_public_bytes(b(c['signingPublic'])).verify(b(c['signature']),cb);checks+=1
Ed25519PublicKey.from_public_bytes(b(c['delegatePublic'])).verify(b(e['signature']),eb+b(e['ciphertext']));checks+=1
Ed25519PublicKey.from_public_bytes(b(c['delegatePublic'])).verify(b(r['signature']),rb);checks+=1
Ed25519PublicKey.from_public_bytes(b(c['signingPublic'])).verify(b(revoke['signature']),vb);checks+=1
salt=uuid.UUID(c['group']).bytes+c['epoch'].to_bytes(8,'big');who=uuid.UUID(c['parent']).bytes+b(c['signingPublic'])
k=HKDF(hashes.SHA256(),32,salt,b'PrivateInput/sender-domain-key/v1\0'+who+b'\x02').derive(b(v['master']));check(k==b(v['senderKey']))
live=HKDF(hashes.SHA256(),32,salt,b'PrivateInput/clipboard-live-key/v1\0'+who).derive(k);check(live==b(v['liveKey']))
check(ChaCha20Poly1305(live).decrypt(b(e['nonce']),b(e['ciphertext']),eb).decode()==v['text'])
old=v['legacy'];_,_,_,header,cipher=clipboard_live.__dict__.get('envelope_bytes',lambda x:__import__('private_input_relay').envelope_bytes(x))(old)
check(ChaCha20Poly1305(k).decrypt(b'\0'*4+old['sequence'].to_bytes(8,'big'),cipher,header).decode()==v['text'])
body=json.loads(b(r['body']));check(set(body)=={'after','limit','publish'} and body['publish']==e)
result={'synthetic':True,'checks':checks,'cppCanonicalMatchesFrozenServer':True,'pythonEd25519HKDFChaCha':True,'realNetwork':False,'realClipboard':False}
(root/'evidence/windows047-live-clipboard/vector-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
