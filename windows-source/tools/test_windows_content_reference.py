#!/usr/bin/env python3
"""Exact copied relay functions, temporary synthetic SQLite, no sockets or credentials."""
import argparse,hashlib,importlib,json,sys,tempfile,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--reference-server',type=Path,required=True);a=p.parse_args()
out=ROOT/'build/windows-activity/reference-server';out.mkdir(parents=True,exist_ok=True)
manifest={}
for name in ['private_input_relay.py','quick_pairing.py','device_administration.py','recent_learning.py']:
    data=(a.reference_server/name).read_bytes();(out/name).write_bytes(data);manifest[name]=hashlib.sha256(data).hexdigest()
sys.dont_write_bytecode=True;sys.path.insert(0,str(out));relay=importlib.import_module('private_input_relay');quick=importlib.import_module('quick_pairing')
fixture=json.loads((ROOT/'build/windows-activity/public-wire-fixture.json').read_text())
with tempfile.TemporaryDirectory(prefix='relay-fixture-',dir=out) as work:
    app=relay.Relay(Path(work)/'relay.sqlite',clock=lambda:fixture['now'])
    app.register(fixture['initial']);group=fixture['initial']['group']
    for prefix in ['first','second']:
        ticket=app.rpc(group,fixture[prefix+'Ticket'])
        invitation=quick.claim(app,{'code':ticket['code'],'request':fixture[prefix+'Request']},'synthetic-local')
        assert invitation['invitation']['anchor']['group']==group
        bundle=fixture[prefix+'Admission'];assert app.admit(group,bundle)['accepted'];assert app.admit(group,bundle)['accepted']
        # No unpublished metadata, full-copy package or prior founder key is
        # needed in compact admission. Server pins the predecessor and sponsor.
        assert all('membership' not in item for item in bundle['packages'])
    assert len(app.state(group)['members'])==3
    for event in fixture['events']:
        assert app.push(group,event)['accepted'];assert app.push(group,event)['accepted']
    result=app.rpc(group,fixture['pull']);assert len(result['events'])==2
    assert {e['domain'] for e in result['events']}=={1,2}
    assert app.rpc(group,fixture['ack'])['accepted']
    # Same RPC nonce cannot be replayed even when a content event is idempotent.
    try:app.rpc(group,fixture['ack'])
    except relay.RelayError as error:assert error.code=='request_replay'
    else:raise AssertionError('replayed acknowledgement RPC accepted')
    assert app.db.execute('SELECT count(*) FROM recipients WHERE recipient=?',(fixture['pull']['sender'],)).fetchone()[0]==0
    app.db.close()
result={'exactServerSourcesSHA256':manifest,'compactV2AdmissionOwnerAndIndependentMember':True,'sameAdmissionRetryIdempotent':True,'learningAndClipboardEventsAccepted':True,'sameEventRetryIdempotent':True,'signedPullAndAcknowledgement':True,'rpcNonceReplayRejected':True,'network':False,'productionDatabase':False}
(ROOT/'evidence/windows-parity-20261019/server-reference.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
