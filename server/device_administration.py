"""Device metadata and admission policy. No typing, content or private keys."""
DAY=86400
KINDS={'ios','android','macos','windows','unknown'}
MOBILE={'ios','android'}

def initialize(db):
    db.execute('CREATE TABLE IF NOT EXISTS departed_devices(group_id TEXT NOT NULL,device TEXT NOT NULL,reason TEXT NOT NULL,PRIMARY KEY(group_id,device))')
    db.execute('CREATE TABLE IF NOT EXISTS device_profiles(group_id TEXT NOT NULL,device TEXT NOT NULL,kind TEXT NOT NULL,idle_days INTEGER NOT NULL,last_seen INTEGER NOT NULL,signing BLOB NOT NULL,PRIMARY KEY(group_id,device))')

def remember_members(relay,state):
    from private_input_relay import identifier,b64
    for member in state['members']:
        relay.db.execute('INSERT OR IGNORE INTO device_profiles VALUES(?,?,?,?,?,?)',(identifier(state['group'])[0],identifier(member['device'])[0],'unknown',30,0,b64(member['signingPublic'],32,32)))

def profile(relay,group,device):
    row=relay.db.execute('SELECT kind,idle_days,last_seen,signing FROM device_profiles WHERE group_id=? AND device=?',(group,device)).fetchone()
    # Optional local-only integration. It conveys successful authenticated archive
    # activity, never admission, new signing keys, content or management rights.
    # Missing/inaccessible metadata keeps the original idle policy unchanged.
    import os
    archive=os.environ.get('PRIVATE_INPUT_ACTIVITY_PRESENCE_DATABASE')
    if not row or not archive or relay.db.execute('SELECT 1 FROM departed_devices WHERE group_id=? AND device=?',(group,device)).fetchone():return row
    try:
        from activity_archive.metadata import latest_authorized_activity
        seen=latest_authorized_activity(archive,group,device,bytes(row[3]),now=int(relay.clock()))
        if seen is not None and seen>row[2]:return (row[0],row[1],seen,row[3])
    except (ImportError,OSError,ValueError,TypeError):pass
    return row

def expired(row,now):
    return bool(row and row[0] in MOBILE and now-row[2]>=row[1]*DAY)

def authorized_activity(relay,group,sender,now):
    from private_input_relay import reject
    row=profile(relay,group,sender)
    if relay.db.execute('SELECT 1 FROM departed_devices WHERE group_id=? AND device=?',(group,sender)).fetchone():reject('device_removed',410)
    if expired(row,now):reject('device_inactive',410)
    relay.db.execute('UPDATE device_profiles SET last_seen=? WHERE group_id=? AND device=?',(now,group,sender))

def rpc(relay,group,sender,operation,body,now):
    from private_input_relay import strict_json,shape,number,identifier,b64,reject
    state=relay.state(group);members={identifier(m['device'])[0]:m for m in state['members']}
    row=profile(relay,group,sender)
    if operation==12:
        if body:reject()
        left=relay.db.execute('SELECT reason FROM departed_devices WHERE group_id=? AND device=?',(group,sender)).fetchone()
        if left:return {'departed':True,'reason':left[0],'devices':[]}
        if sender not in members or expired(row,now):return {'departed':True,'reason':'inactive' if sender in members else 'removed','devices':[]}
        authorized_activity(relay,group,sender,now)
        devices=[]
        for device in members:
            p=profile(relay,group,device)
            left=relay.db.execute('SELECT 1 FROM departed_devices WHERE group_id=? AND device=?',(group,device)).fetchone()
            devices.append({'device':device,'kind':p[0] if p else 'unknown','idleDays':p[1] if p else 30,'lastSeen':p[2] if p else 0,'inactive':bool(left) or expired(p,now),'isSelf':device==sender})
        return {'departed':False,'devices':devices}
    if sender not in members:reject('member',403)
    if operation==14:
        if body:reject()
        relay.db.execute('INSERT OR REPLACE INTO departed_devices VALUES(?,?,?)',(group,sender,'left'))
        relay.db.execute('DELETE FROM key_packages WHERE group_id=? AND recipient=?',(group,sender))
        relay.db.execute('DELETE FROM recipients WHERE group_id=? AND recipient=?',(group,sender))
        return {'accepted':True}
    value=strict_json(body)
    if operation==11:
        shape(value,'kind')
        kind=value['kind']
        if kind not in KINDS or kind=='unknown':reject('device_kind')
        if row and row[0] not in {'unknown',kind}:reject('immutable_kind',403)
        relay.db.execute('INSERT INTO device_profiles VALUES(?,?,?,?,?,?) ON CONFLICT(group_id,device) DO UPDATE SET kind=excluded.kind,last_seen=excluded.last_seen',(group,sender,kind,30,now,b64(members[sender]['signingPublic'],32,32)))
    else:
        shape(value,'idleDays');days=number(value['idleDays'],1,90)
        if not row or row[0] not in MOBILE:reject('mobile_policy',403)
        relay.db.execute('UPDATE device_profiles SET idle_days=? WHERE group_id=? AND device=?',(days,group,sender))
    return {'accepted':True}

def authorize_change(relay,group,old,next_state,now):
    from private_input_relay import identifier,reject
    issuer=identifier(next_state['issuer'])[0];actor=relay.member(old,issuer)
    if actor['permissions']!=3:reject('manage_permission',403)
    authorized_activity(relay,group,issuer,now)
    new={identifier(m['device'])[0] for m in next_state['members']}
    removed=[identifier(m['device'])[0] for m in old['members'] if identifier(m['device'])[0] not in new]
    source=profile(relay,group,issuer)
    for target in removed:
        destination=profile(relay,group,target)
        already_left=relay.db.execute('SELECT 1 FROM departed_devices WHERE group_id=? AND device=?',(group,target)).fetchone()
        if target==issuer or expired(destination,now) or already_left:continue
        # Unknown devices remain protected until their own signed registration.
        if not source or source[0] in MOBILE or source[0]=='unknown':
            if not destination or destination[0] not in {'macos','windows'}:reject('mobile_cannot_remove_phone',403)
