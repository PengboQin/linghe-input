#!/usr/bin/env python3
"""Verify C++ recency requests and envelopes against copied server, no sockets."""
import importlib,json,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];reference=ROOT/'build/windows-activity/reference-server';sys.dont_write_bytecode=True;sys.path.insert(0,str(reference));relay=importlib.import_module('private_input_relay');recent=importlib.import_module('recent_learning')
v=json.loads((ROOT/'build/windows-activity/recency-wire-vector.json').read_text());cpp=json.loads((ROOT/'evidence/windows-parity-20261019/recent-host.json').read_text());group=v['membership']['group']
with tempfile.TemporaryDirectory(prefix='recent-fixture-',dir=reference) as work:
    app=relay.Relay(Path(work)/'relay.sqlite',clock=lambda:v['serverTime']);app.register(v['membership'])
    hello=recent.handle(app,group,cpp['request']);assert hello['ready']
    old=recent.handle(app,group,v['request']);assert old['accepted']
    pushed=recent.handle(app,group,cpp['push']);assert pushed['accepted'] and pushed['event']==cpp['envelope']['event']
    pulled=recent.handle(app,group,cpp['pull']);assert pulled['envelope'] is None and pulled['next']==''
    try:recent.handle(app,group,cpp['request'])
    except relay.RelayError as error:assert error.code=='request_replay'
    else:raise AssertionError('replayed recency nonce accepted')
    app.db.close()
(ROOT/'build/windows-activity/recent-status-fixture.json').write_text(json.dumps({'status':hello,'request':cpp['request']}))
result={'cppHelloPushPullVerifiedByExactServer':True,'swiftGoldenRequestAccepted':True,'cppRandomNonceEnvelopeAccepted':True,'nonceReplayRejected':True,'sameSenderPullSkipped':True,'network':False,'productionDatabase':False}
(ROOT/'evidence/windows-parity-20261019/recent-server-reference.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
