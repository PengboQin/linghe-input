"""Deterministic synthetic native component / shared-model interoperability."""
import base64
import json
from pathlib import Path
import tempfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from activity_archive.service import MemoryAuthority, encode
from .service import LearningStore, LearningApplication, canonical


def generate():
    now=1792600000;group='11111111-1111-4111-8111-111111111111';device='22222222-2222-4222-8222-222222222222';install='33333333-3333-4333-8333-333333333333';producer='66666666-6666-4666-8666-666666666666'
    key=Ed25519PrivateKey.from_private_bytes(bytes(range(32)));public=key.public_key().public_bytes(Encoding.Raw,PublicFormat.Raw)
    authority=MemoryAuthority();authority.put(group,{device:(public,3)})
    with tempfile.TemporaryDirectory(prefix='native-components-wire-') as temp:
        store=LearningStore(Path(temp)/'learning.sqlite',clock=lambda:now);app=LearningApplication(store,authority,clock=lambda:now);nonce=0
        def call(op,body):
            nonlocal nonce
            nonce+=1;raw=encode(body);value={'version':1,'group':group,'sender':device,'nonce':'44444444-4444-4444-8444-'+str(nonce).zfill(12),'issuedAt':now,'operation':op,'body':base64.b64encode(raw).decode()};value['signature']=base64.b64encode(key.sign(canonical(value,raw))).decode();return app.dispatch(encode(value))
        call(2,{'expected_version':0,'enabled':True});status=call(3,{'expected_version':0,'enabled':True,'installation_id':install})
        records=[{'reading':reading,'text':text,'generation':0,'deleted':False,'counts':{producer:count},'pinned':False,'pinVersion':{'sequence':0,'device':''}} for reading,text,count in [('hao','好',3),('tao bao','淘宝',7)]]
        base={'generation':1,'consent_version':1,'installation_id':install,'producer_id':producer}
        receipt=call(6,base|{'publication_id':'77777777-7777-4777-8777-777777777771','history_mode':'historical_undated','records':records})
        store.worker_tick(authority,force=True);first=call(5,{'generation':1,'from_version':0})
        updated=dict(records[0],counts={producer:4},pinned=True,pinVersion={'sequence':1,'device':producer})
        second_receipt=call(6,base|{'publication_id':'77777777-7777-4777-8777-777777777772','history_mode':'incremental','records':[updated]})
        store.worker_tick(authority,force=True);second=call(5,{'generation':1,'from_version':1})
        bootstrap=call(7,{'generation':1,'consent_version':1,'installation_id':install,'producer_id':producer})
        fixture={'bootstrap':bootstrap,'fixture_kind':'synthetic_only','group':group,'device':device,'installation':install,'producer':producer,'issued_at':now,'public_key':base64.b64encode(public).decode(),'status':status,'records_initial':records,'records_updated':[updated],'merged_records':[updated,records[1]],'receipt_initial':receipt,'receipt_incremental':second_receipt,'pull_initial':first,'pull_incremental':second}
        store.close();return fixture

if __name__=='__main__':print(json.dumps(generate(),ensure_ascii=False,sort_keys=True,indent=2))
