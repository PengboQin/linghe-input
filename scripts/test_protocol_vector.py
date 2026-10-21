#!/usr/bin/env python3
"""Independent Python cryptography verification of Apple's PUBLIC test vector."""
import base64, hashlib, hmac, json, struct, uuid
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
ROOT=Path(__file__).resolve().parents[1]
v=json.loads((ROOT/'fixtures/protocol/secure-message-v1.json').read_text())
e=v['envelope'];decode=lambda x:base64.b64decode(x,validate=True)
group=uuid.UUID(e['group']).bytes;sender=uuid.UUID(e['sender']).bytes;event=uuid.UUID(e['event']).bytes
number=lambda x:struct.pack('>Q',x)
header=b'PrivateInput/event/v1\0'+bytes([e['version']])+group+sender+event+number(e['epoch'])+number(e['sequence'])+bytes([e['domain']])+number(e['issuedAt'])+number(e['expiresAt'])
public=decode(v['signingPublic']);cipher=decode(e['ciphertext']);signature=decode(e['signature'])
Ed25519PublicKey.from_public_bytes(public).verify(signature,header+cipher)
private=Ed25519PrivateKey.from_private_bytes(decode(v['signingSeed']))
assert private.public_key().public_bytes_raw()==public
# CryptoKit randomizes Ed25519 signatures. Validate signatures, do not require
# signing implementations to produce byte-identical signatures for one message.
python_signature=private.sign(header+cipher)
Ed25519PublicKey.from_public_bytes(public).verify(python_signature,header+cipher)
salt=group+number(e['epoch']);info=b'PrivateInput/sender-domain-key/v1\0'+sender+public+bytes([e['domain']])
prk=hmac.new(salt,decode(v['masterKey']),hashlib.sha256).digest()
key=hmac.new(prk,info+b'\x01',hashlib.sha256).digest()
nonce=b'\0'*4+number(e['sequence']);plain=decode(v['plaintext'])
assert ChaCha20Poly1305(key).decrypt(nonce,cipher,header)==plain
assert ChaCha20Poly1305(key).encrypt(nonce,plain,header)==cipher
e['signature']=base64.b64encode(python_signature).decode()
(ROOT/'fixtures/protocol/secure-message-v1-python.json').write_text(json.dumps(e,sort_keys=True,indent=2)+'\n')
print('PASS: Apple signature verified independently; UUID/big-endian AAD, HKDF-SHA256 and IETF ChaCha20-Poly1305 exact ciphertext; Python signature generated for reverse verification')
