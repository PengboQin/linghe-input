"""Opt-in encrypted recency snapshots, isolated from legacy relay events.

Never receives plaintext words. Called inside Relay's lock/SQLite transaction.
"""
import hashlib
from private_input_relay import (b64, encoded, identifier, integer_bytes, number,
                                 reject, shape, strict_json, verify_signature)

def initialize(db):
    db.executescript('''
      CREATE TABLE IF NOT EXISTS recent_capabilities(group_id TEXT,sender TEXT,epoch TEXT,revision TEXT,key_hash BLOB,roles BLOB,expires INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(group_id,sender));
      CREATE TABLE IF NOT EXISTS recent_snapshots(group_id TEXT,sender TEXT,epoch TEXT,event TEXT,expires INTEGER,wire BLOB,PRIMARY KEY(group_id,sender));
      CREATE TABLE IF NOT EXISTS recent_receipts(group_id TEXT,sender TEXT,event TEXT,digest BLOB,expires INTEGER,PRIMARY KEY(group_id,sender,event));
      CREATE TABLE IF NOT EXISTS recent_nonces(group_id TEXT,sender TEXT,nonce TEXT,expires INTEGER,PRIMARY KEY(group_id,sender,nonce));
      CREATE TABLE IF NOT EXISTS recent_policy(group_id TEXT PRIMARY KEY,reference_day INTEGER NOT NULL);
    ''')
    # Pre-release optional schema migration; old capability declarations must
    # re-attest, not silently gain an unlimited capability lease.
    if 'expires' not in {row[1] for row in db.execute('PRAGMA table_info(recent_capabilities)')}:
        db.execute('ALTER TABLE recent_capabilities ADD COLUMN expires INTEGER NOT NULL DEFAULT 0')

def envelope_header(value):
    shape(value,'version group sender event epoch issuedAt expiresAt sealed signature')
    if type(value['version']) is not int or value['version'] != 1:reject('recent_version')
    group,gb=identifier(value['group']);sender,sb=identifier(value['sender']);event,eb=identifier(value['event'])
    epoch=number(value['epoch'],1);issued=number(value['issuedAt']);expires=number(value['expiresAt'])
    if expires<=issued or expires-issued>604800:reject('recent_expiry')
    sealed=b64(value['sealed'],28,2097152+28)
    header=(b'PrivateInput/recent-learning-envelope/v1\0'+b'\x01'+gb+sb+eb+
            integer_bytes(epoch)+integer_bytes(issued)+integer_bytes(expires))
    return group,sender,event,epoch,issued,expires,sealed,header

def handle(relay,group,request):
    shape(request,'version group sender nonce issuedAt operation body signature')
    actual,gb=identifier(request['group']);sender,sb=identifier(request['sender']);nonce,nb=identifier(request['nonce'])
    issued=number(request['issuedAt']);op=number(request['operation'],1,3)
    if actual!=group or type(request['version']) is not int or request['version']!=1:reject('recent_version')
    body=b64(request['body'],maximum=3*1024*1024)
    header=(b'PrivateInput/recency-request/v1\0'+b'\x01'+gb+sb+nb+integer_bytes(issued)+bytes([op])+hashlib.sha256(body).digest())
    now=int(relay.clock())
    if now<0 or abs(now-issued)>=300:reject('expired',410)
    with relay.transaction():
        state=relay.state(group);member=relay.member(state,sender)
        if not member['permissions']&1:reject('recent_permission',403)
        public=b64(member['signingPublic'],32,32)
        verify_signature(public,b64(request['signature'],64,64),header)
        import device_administration
        device_administration.authorized_activity(relay,group,sender,now)
        payload=strict_json(body)
        shape(payload,'epoch membershipRevision roles' if op==1 else ('epoch membershipRevision envelope expectedEvent' if op==2 else 'epoch membershipRevision after'))
        epoch=number(payload['epoch'],1);revision=number(payload['membershipRevision'],1)
        if epoch!=state['epoch'] or revision!=state['revision']:reject('recent_membership',409)
        day=now//86400
        if not 90<=day<=3000000:reject('recent_time_unavailable',503)
        old=relay.db.execute('SELECT reference_day FROM recent_policy WHERE group_id=?',(group,)).fetchone()
        if old and old[0]>day:reject('recent_time_unavailable',503)
        relay.db.execute('INSERT INTO recent_policy VALUES(?,?) ON CONFLICT(group_id) DO UPDATE SET reference_day=excluded.reference_day',(group,day))
        for table in ('recent_nonces','recent_receipts','recent_snapshots','recent_capabilities'):
            relay.db.execute('DELETE FROM '+table+' WHERE group_id=? AND expires<=?',(group,now))
        relay.db.execute('DELETE FROM recent_snapshots WHERE group_id=? AND epoch!=?',(group,str(epoch)))
        if relay.db.execute('SELECT 1 FROM recent_nonces WHERE group_id=? AND sender=? AND nonce=?',(group,sender,nonce)).fetchone():reject('request_replay',409)
        if relay.db.execute('SELECT count(*) FROM recent_nonces WHERE group_id=?',(group,)).fetchone()[0]>=8192:reject('quota',429)
        relay.db.execute('INSERT INTO recent_nonces VALUES(?,?,?,?)',(group,sender,nonce,now+600))
        if op==1:
            roles=payload['roles']
            if type(roles) is not list or not 1<=len(roles)<=4 or any(type(r) is not str or r not in ('app','keyboard','desktop','ime') for r in roles) or len(set(roles))!=len(roles) or not set(roles)&{'keyboard','ime'}:reject('recent_roles')
            relay.db.execute('INSERT INTO recent_capabilities VALUES(?,?,?,?,?,?,?) ON CONFLICT(group_id,sender) DO UPDATE SET epoch=excluded.epoch,revision=excluded.revision,key_hash=excluded.key_hash,roles=excluded.roles,expires=excluded.expires',(group,sender,str(epoch),str(revision),hashlib.sha256(public).digest(),encoded(roles),now+604800))
        missing=[]
        for peer in state['members']:
            if not peer['permissions']&1:continue
            device=identifier(peer['device'])[0]
            row=relay.db.execute('SELECT epoch,revision,key_hash FROM recent_capabilities WHERE group_id=? AND sender=?',(group,device)).fetchone()
            if not row or row!=(str(epoch),str(revision),hashlib.sha256(b64(peer['signingPublic'],32,32)).digest()):missing.append(device)
        response={'version':1,'group':group,'sender':sender,'nonce':nonce,'epoch':epoch,'membershipRevision':revision,
                  'serverTime':now,'referenceDay':day,'ready':not missing,'missing':sorted(missing)}
        own=relay.db.execute('SELECT event,wire FROM recent_snapshots WHERE group_id=? AND sender=? AND epoch=?',(group,sender,str(epoch))).fetchone()
        response['publishedEvent']=own[0] if own else ''
        if op==1:return dict(response,envelope=strict_json(own[1]) if own else None)
        if missing:reject('recent_not_ready',409)
        if op==2:
            message=payload['envelope']
            actual,actor,event,me,mi,mx,sealed,aad=envelope_header(message)
            if actual!=group or actor!=sender or me!=epoch:reject('recent_binding',403)
            if mx<=now or mi>now+300:reject('recent_expiry',410)
            verify_signature(public,b64(message['signature'],64,64),aad+sealed)
            digest=hashlib.sha256(aad+sealed).digest()
            receipt=relay.db.execute('SELECT digest FROM recent_receipts WHERE group_id=? AND sender=? AND event=?',(group,sender,event)).fetchone()
            if receipt:
                if receipt[0]!=digest:reject('recent_event_conflict',409)
                return dict(response,accepted=True,event=event)
            expected=payload['expectedEvent']
            if type(expected) is not str:reject('recent_parent')
            if expected:expected=identifier(expected)[0]
            if expected!=response['publishedEvent']:reject('recent_snapshot_conflict',409)
            # One latest slot per sender; old attempts cannot create unbounded history.
            if relay.db.execute('SELECT count(*) FROM recent_receipts WHERE group_id=?',(group,)).fetchone()[0]>=32768:reject('quota',429)
            wire=encoded(message)
            existing=relay.db.execute('SELECT coalesce(sum(length(wire)),0) FROM recent_snapshots WHERE group_id=? AND sender!=?',(group,sender)).fetchone()[0]
            if existing+len(wire)>32*1024*1024:reject('quota',429)
            relay.db.execute('INSERT INTO recent_receipts VALUES(?,?,?,?,?)',(group,sender,event,digest,mx))
            relay.db.execute('INSERT INTO recent_snapshots VALUES(?,?,?,?,?,?) ON CONFLICT(group_id,sender) DO UPDATE SET epoch=excluded.epoch,event=excluded.event,expires=excluded.expires,wire=excluded.wire',(group,sender,str(epoch),event,mx,wire))
            return dict(response,accepted=True,event=event,publishedEvent=event)
        after=payload['after']
        if type(after) is not str:reject('recent_cursor')
        if after:after=identifier(after)[0]
        allowed={identifier(m['device'])[0] for m in state['members'] if m['permissions']&1}
        rows=relay.db.execute('SELECT sender,wire FROM recent_snapshots WHERE group_id=? AND epoch=? AND sender>? AND sender!=? ORDER BY sender',(group,str(epoch),after,sender))
        for actor,wire in rows:
            if actor in allowed:return dict(response,envelope=strict_json(wire),next=actor)
        return dict(response,envelope=None,next='')
