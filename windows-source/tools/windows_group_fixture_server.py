#!/usr/bin/env python3
"""One synthetic relay operation. No listen socket, URL fetch, actual user data."""
import json,sys,os
from pathlib import Path
sys.dont_write_bytecode=True
request_path=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[1]
expected=root/'build/windows-activity/group-fixture'
assert request_path.parent==expected
fixture_server=root/'windows/tests/activity/relay_fixture'
# Opt-in synthetic integration may exercise the authoritative current server
# source. No files are copied, socket opened or production database accessed.
if os.environ.get('PRIVATE_INPUT_FIXTURE_CANONICAL_SERVER')=='1':
    choices=[root.parent/'private-input/server',root.parent/'server']
    fixture_server=next((p for p in choices if (p/'recent_learning.py').is_file()),None)
    assert fixture_server is not None
sys.path.insert(0,str(fixture_server if fixture_server.exists() else root/'build/windows-activity/reference-server'))
import private_input_relay as relay,quick_pairing,recent_learning
ArchiveError=relay.RelayError
request=json.loads(request_path.read_text());app=relay.Relay(expected/'relay.sqlite',clock=lambda:request['now'])
try:
    path=request['path'];body=request['body'];parts=path.strip('/').split('/')
    if path=='/_fixture/queue':
        # Read-only inspection of this disposable, signed-test relay database.
        # This is not a deployed HTTP route or a change to its quota policy.
        count,size=app.db.execute('SELECT count(*),coalesce(sum(length(wire)),0) FROM messages WHERE group_id=?',(body['group'],)).fetchone()
        recipients=app.db.execute('SELECT count(*) FROM recipients WHERE group_id=? AND recipient=?',(body['group'],body['recipient'])).fetchone()[0]
        result={'messages':count,'bytes':size,'recipients':recipients}
    elif path in ('/v1/learning/rpc','/_fixture/cloud-aggregate'):
        assert os.environ.get('PRIVATE_INPUT_FIXTURE_CANONICAL_SERVER')=='1'
        from cloud_learning.service import LearningStore,LearningApplication
        from cloud_learning.authority import LearningMembershipAuthority
        from activity_archive.service import ArchiveError
        cloud=LearningStore(expected/'cloud-learning.sqlite',clock=lambda:request['now'])
        authority=LearningMembershipAuthority(expected/'relay.sqlite')
        try:
            if path=='/v1/learning/rpc':result=LearningApplication(cloud,authority,clock=lambda:request['now']).dispatch(json.dumps(body,ensure_ascii=False,separators=(',',':')).encode())
            else:
                published,processed=cloud.aggregate_group(cloud.group(body['group']),authority,request['now'],10000)
                result={'published':published,'processed':processed}
        finally:cloud.db.close()
    elif path=='/v1/groups':result=app.register(body)
    elif path=='/v1/pairing/claim':result=quick_pairing.claim(app,body,'synthetic-fixture')
    else:
        assert len(parts)==4 and parts[:2]==['v1','groups'];group=parts[2]
        result={'rpc':app.rpc,'events':app.push,'admission':app.admit,'recency':lambda g,b:recent_learning.handle(app,g,b)}[parts[3]](group,body)
    print(json.dumps({'status':200,'result':result}))
except (relay.RelayError,ArchiveError) as error:print(json.dumps({'status':error.status,'error':error.code}))
finally:app.db.close()
