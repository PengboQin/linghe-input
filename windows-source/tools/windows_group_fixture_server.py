#!/usr/bin/env python3
"""One synthetic relay operation. No listen socket, URL fetch, actual user data."""
import json,sys
from pathlib import Path
sys.dont_write_bytecode=True
request_path=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[1]
expected=root/'build/windows-activity/group-fixture'
assert request_path.parent==expected
fixture_server=root/'windows/tests/activity/relay_fixture'
sys.path.insert(0,str(fixture_server if fixture_server.exists() else root/'build/windows-activity/reference-server'))
import private_input_relay as relay,quick_pairing,recent_learning
request=json.loads(request_path.read_text());app=relay.Relay(expected/'relay.sqlite',clock=lambda:request['now'])
try:
    path=request['path'];body=request['body'];parts=path.strip('/').split('/')
    if path=='/_fixture/queue':
        # Read-only inspection of this disposable, signed-test relay database.
        # This is not a deployed HTTP route or a change to its quota policy.
        count,size=app.db.execute('SELECT count(*),coalesce(sum(length(wire)),0) FROM messages WHERE group_id=?',(body['group'],)).fetchone()
        recipients=app.db.execute('SELECT count(*) FROM recipients WHERE group_id=? AND recipient=?',(body['group'],body['recipient'])).fetchone()[0]
        result={'messages':count,'bytes':size,'recipients':recipients}
    elif path=='/v1/groups':result=app.register(body)
    elif path=='/v1/pairing/claim':result=quick_pairing.claim(app,body,'synthetic-fixture')
    else:
        assert len(parts)==4 and parts[:2]==['v1','groups'];group=parts[2]
        result={'rpc':app.rpc,'events':app.push,'admission':app.admit,'recency':lambda g,b:recent_learning.handle(app,g,b)}[parts[3]](group,body)
    print(json.dumps({'status':200,'result':result}))
except relay.RelayError as error:print(json.dumps({'status':error.status,'error':error.code}))
finally:app.db.close()
