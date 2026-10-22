import base64
import copy
import hashlib
import io
import json
import tempfile
import unittest
import uuid
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from private_input_relay import Relay, RelayError, encoded, integer_bytes, strict_json, membership_canonical
from recent_learning import handle, envelope_header
from expire_relay import expire_existing, RECENT_TABLES

class RecentLearningTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='PrivateInput-Recent-Test-')
        self.now=1800000000
        self.relay=Relay(Path(self.temp.name)/'relay.sqlite',clock=lambda:self.now)
        self.fixture=json.loads((Path(__file__).resolve().parents[1]/'fixtures/protocol/relay-membership-v1.json').read_text())
        self.relay.register(self.fixture['initial']);self.relay.update(self.fixture['paired']['group'],self.fixture['paired'])
        self.group=self.fixture['paired']['group'];self.members=self.fixture['paired']['members']
        self.owner=self.fixture['initial']['members'][0]['device']
        self.peer=next(m['device'] for m in self.members if m['device']!=self.owner)
        self.seeds={self.owner:self.fixture['senderSeed'],self.peer:self.fixture['recipientSeed']}
        self.epoch=self.fixture['paired']['epoch'];self.revision=self.fixture['paired']['revision']
    def tearDown(self):
        self.relay.db.close();self.temp.cleanup()
    def request(self,op,payload,sender=None):
        sender=sender or self.owner;nonce=str(uuid.uuid4()).upper();body=encoded(payload)
        header=(b'PrivateInput/recency-request/v1\0\x01'+uuid.UUID(self.group).bytes+uuid.UUID(sender).bytes+
                uuid.UUID(nonce).bytes+integer_bytes(self.now)+bytes([op])+hashlib.sha256(body).digest())
        sig=Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.seeds[sender])).sign(header)
        return dict(version=1,group=self.group,sender=sender,nonce=nonce,issuedAt=self.now,operation=op,
                    body=base64.b64encode(body).decode(),signature=base64.b64encode(sig).decode())
    def body(self,**kw):
        if 'envelope' in kw and 'expectedEvent' not in kw:
            own=self.relay.db.execute('SELECT event FROM recent_snapshots WHERE group_id=? AND sender=?',(self.group,self.owner)).fetchone()
            kw['expectedEvent']=own[0] if own else ''
        return dict(epoch=self.epoch,membershipRevision=self.revision,**kw)
    def hello(self,sender=None):return handle(self.relay,self.group,self.request(1,self.body(roles=['app','keyboard']),sender))
    def ready(self):self.hello();self.assertTrue(self.hello(self.peer)['ready'])
    def envelope(self,sender=None,sealed_bytes=None):
        sender=sender or self.owner
        m=dict(version=1,group=self.group,sender=sender,event=str(uuid.uuid4()).upper(),epoch=self.epoch,
               issuedAt=self.now,expiresAt=self.now+604800,sealed=base64.b64encode(sealed_bytes or b'Synthetic encrypted opaque data').decode(),signature='')
        *_,sealed,header=envelope_header(m)
        m['signature']=base64.b64encode(Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.seeds[sender])).sign(header+sealed)).decode()
        return m
    def testOldMemberBlocksPushButLegacyMembershipUnchanged(self):
        self.assertFalse(self.hello()['ready'])
        with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(2,self.body(envelope=self.envelope())))
        self.assertEqual(self.relay.state(self.group),self.fixture['paired'])
    def testIndependentNonceReplayRejectedWithoutReceiptMutation(self):
        req=self.request(1,self.body(roles=['desktop','ime']))
        handle(self.relay,self.group,req)
        with self.assertRaises(RelayError):handle(self.relay,self.group,req)
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_capabilities').fetchone()[0],1)
    def testPushRepeatedAndPaginationOnlyOtherMember(self):
        self.ready();message=self.envelope()
        for _ in range(2):self.assertTrue(handle(self.relay,self.group,self.request(2,self.body(envelope=message)))['accepted'])
        page=handle(self.relay,self.group,self.request(3,self.body(after=''),self.peer))
        self.assertEqual(page['envelope'],message);self.assertEqual(page['next'],self.owner)
        self.assertIsNone(handle(self.relay,self.group,self.request(3,self.body(after=page['next']),self.peer))['envelope'])
        self.assertIsNone(handle(self.relay,self.group,self.request(3,self.body(after='')))['envelope'])
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_receipts').fetchone()[0],1)
    def testInvalidSignatureContextAndRolesDoNotPartiallyMutate(self):
        for roles in ([],['app'],['ime','ime'],['unknown']):
            with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(1,self.body(roles=roles)))
        req=self.request(1,self.body(roles=['ime']));req['signature']=base64.b64encode(bytes(64)).decode()
        with self.assertRaises(RelayError):handle(self.relay,self.group,req)
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_capabilities').fetchone()[0],0)
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_nonces').fetchone()[0],0)
    def testConflictingEventOrExpiredEnvelopePreservesLatestSlot(self):
        self.ready();message=self.envelope();handle(self.relay,self.group,self.request(2,self.body(envelope=message)))
        bad=copy.deepcopy(message);bad['sealed']=base64.b64encode(bytes(32)).decode()
        *_,sealed,header=envelope_header(bad)
        bad['signature']=base64.b64encode(Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.seeds[self.owner])).sign(header+sealed)).decode()
        with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(2,self.body(envelope=bad)))
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_snapshots').fetchone()[0],1)
        self.now+=604800
        with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(2,self.body(envelope=message)))
    def testWrongMembershipAndBackwardServerDayFailClosed(self):
        self.ready()
        body=self.body(roles=['ime']);body['epoch']+=1
        with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(1,body))
        self.now-=86400
        with self.assertRaises(RelayError):self.hello()
    def testNewHTTPRouteAndBoundedMalformedBody(self):
        req=self.request(1,self.body(roles=['ime']));data=encoded(req);status=[]
        env={'REQUEST_METHOD':'POST','PATH_INFO':f'/v1/groups/{self.group}/recency','CONTENT_LENGTH':str(len(data)),
             'wsgi.input':io.BytesIO(data),'REMOTE_ADDR':'127.0.0.1'}
        result=b''.join(self.relay(env,lambda s,h:status.append(s)))
        self.assertTrue(status[0].startswith('200'));self.assertEqual(strict_json(result)['nonce'],req['nonce'])
        env['CONTENT_LENGTH']=str(5*1024*1024+1);status.clear()
        b''.join(self.relay(env,lambda s,h:status.append(s)));self.assertTrue(status[0].startswith('413'))
    def testScheduledExpirySupportsCompleteNewAndUnchangedOldSchemas(self):
        self.ready();message=self.envelope()
        handle(self.relay,self.group,self.request(2,self.body(envelope=message)))
        result=expire_existing(Path(self.temp.name)/'relay.sqlite',self.now+604800)
        self.assertGreater(result['expiredRows'],0)
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_snapshots').fetchone()[0],0)
        for table in RECENT_TABLES:self.relay.db.execute('DROP TABLE '+table)
        self.assertFalse(expire_existing(Path(self.temp.name)/'relay.sqlite',self.now)['physicalErasureProven'])
    def testPartialOrUnknownOptionalSchemaRefusesMaintenance(self):
        self.relay.db.execute('DROP TABLE recent_policy')
        with self.assertRaises(ValueError):expire_existing(Path(self.temp.name)/'relay.sqlite',self.now)
    def testSameSecondOldFirstPublicationCannotOverwriteNewerSlot(self):
        self.ready();old=self.envelope();new=self.envelope()
        # Both events are signed in the same second. Timestamp comparison is
        # insufficient; the previous-slot precondition is in the signed body.
        delayed=self.request(2,self.body(envelope=old,expectedEvent=''))
        handle(self.relay,self.group,self.request(2,self.body(envelope=new,expectedEvent='')))
        with self.assertRaises(RelayError) as failure:handle(self.relay,self.group,delayed)
        self.assertEqual(failure.exception.status,409);self.assertEqual(failure.exception.code,'recent_snapshot_conflict')
        own=self.hello();self.assertEqual(own['publishedEvent'],new['event']);self.assertEqual(own['envelope'],new)
        page=handle(self.relay,self.group,self.request(3,self.body(after=''),self.peer))
        self.assertEqual(page['envelope'],new)
    def testCapabilityLeaseDoesNotRemainReadyAfterAWriterStopsAttesting(self):
        self.ready();self.now+=604800
        response=self.hello()
        self.assertFalse(response['ready']);self.assertEqual(response['missing'],[self.peer])
    def testConditionalHelloOmitsKnownOwnEnvelopeButPreservesPublishedEvent(self):
        self.ready();message=self.envelope()
        handle(self.relay,self.group,self.request(2,self.body(envelope=message)))
        legacy=self.hello()
        self.assertTrue(legacy['conditionalSnapshots']);self.assertEqual(legacy['envelope'],message)
        same=handle(self.relay,self.group,self.request(1,self.body(roles=['ime'],knownEvent=message['event'].lower())))
        self.assertIsNone(same['envelope']);self.assertEqual(same['publishedEvent'],message['event'])
        # Empty/unknown hints still bootstrap the full slot, never assume merged.
        for known in ('',str(uuid.uuid4()).upper()):
            current=handle(self.relay,self.group,self.request(1,self.body(roles=['ime'],knownEvent=known)))
            self.assertEqual(current['envelope'],message)
        newer=self.envelope();handle(self.relay,self.group,self.request(2,self.body(envelope=newer)))
        current=handle(self.relay,self.group,self.request(1,self.body(roles=['ime'],knownEvent=message['event'])))
        self.assertEqual(current['envelope'],newer)
    def testConditionalPullSkipsUnchangedAndReturnsNewSnapshot(self):
        self.ready();message=self.envelope()
        handle(self.relay,self.group,self.request(2,self.body(envelope=message)))
        known={self.owner.lower():message['event'].lower()}
        same=handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots=known),self.peer))
        self.assertIsNone(same['envelope']);self.assertEqual(same['next'],'')
        newer=self.envelope();handle(self.relay,self.group,self.request(2,self.body(envelope=newer)))
        changed=handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots=known),self.peer))
        self.assertEqual(changed['envelope'],newer);self.assertEqual(changed['next'],self.owner)
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_snapshots').fetchone()[0],1)
    def add_member(self):
        from cryptography.hazmat.primitives.serialization import Encoding,PublicFormat
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        device=str(uuid.uuid4()).upper();seed=bytes([199])*32
        self.seeds[device]=base64.b64encode(seed).decode()
        public=Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(Encoding.Raw,PublicFormat.Raw)
        exchange=X25519PrivateKey.from_private_bytes(bytes(reversed(range(32)))).public_key().public_bytes(Encoding.Raw,PublicFormat.Raw)
        state=copy.deepcopy(self.relay.state(self.group));state['revision']+=1;state['epoch']+=1
        state['members'].append({'device':device,'signingPublic':base64.b64encode(public).decode(),'exchangePublic':base64.b64encode(exchange).decode(),'permissions':3})
        state['signature']=base64.b64encode(Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.fixture['ownerSeed'])).sign(membership_canonical(state))).decode()
        self.relay.update(self.group,state);self.epoch=state['epoch'];self.revision=state['revision']
        for member in state['members']:self.hello(member['device'])
        return device
    def testConditionalPullContinuesPastKnownPeerRatherThanEndingEarly(self):
        third=self.add_member()
        for actor in (self.owner,self.peer):
            message=self.envelope(sender=actor)
            handle(self.relay,self.group,self.request(2,self.body(envelope=message,expectedEvent=''),actor))
        rows=self.relay.db.execute('SELECT sender,event FROM recent_snapshots WHERE group_id=? ORDER BY sender',(self.group,)).fetchall()
        page=handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots={rows[0][0]:rows[0][1]}),third))
        self.assertEqual(page['next'],rows[1][0]);self.assertEqual(page['envelope']['event'],rows[1][1])
    def testConditionalHintsDoNotBypassEpochChangeOrExposeAnotherGroup(self):
        self.ready();old=self.envelope()
        handle(self.relay,self.group,self.request(2,self.body(envelope=old)))
        old_body=self.body(roles=['ime'],knownEvent=old['event'])
        self.add_member()
        with self.assertRaises(RelayError) as caught:
            handle(self.relay,self.group,self.request(1,old_body))
        self.assertEqual(caught.exception.code,'recent_membership')
        self.assertIsNone(self.relay.db.execute('SELECT 1 FROM recent_snapshots WHERE group_id=?',(self.group,)).fetchone())
        current=self.envelope();handle(self.relay,self.group,self.request(2,self.body(envelope=current,expectedEvent='')))
        changed=handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots={self.owner:old['event']}),self.peer))
        self.assertEqual(changed['envelope'],current)
        # A foreign group slot with the same sender must never become a match or
        # leak its ciphertext/event even when supplied in a conditional hint.
        other=str(uuid.uuid4()).upper();foreign=self.envelope();foreign['group']=other
        self.relay.db.execute('INSERT INTO recent_snapshots VALUES(?,?,?,?,?,?)',(other,self.owner,str(self.epoch),foreign['event'],self.now+1000,encoded(foreign)))
        same=handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots={self.owner:current['event']}),self.peer))
        self.assertIsNone(same['envelope']);self.assertNotIn(foreign['event'],encoded(same).decode())
        hello=handle(self.relay,self.group,self.request(1,self.body(roles=['ime'],knownEvent=foreign['event'])))
        self.assertEqual(hello['envelope'],current)
    def testConditionalHintsStrictBoundsAndShapePreserveStateOnFailure(self):
        self.ready();baseline=self.relay.db.execute('SELECT count(*) FROM recent_nonces').fetchone()[0]
        bad_hints=[None,[],{str(uuid.uuid4()):'not-a-uuid'},
                   {str(uuid.uuid4()):str(uuid.uuid4()) for _ in range(65)},
                   {self.owner:str(uuid.uuid4()),self.owner.lower():str(uuid.uuid4())}]
        # Fixture numeric UUIDs have no case variants; use a UUID containing A-F.
        actor='ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDEF'
        bad_hints[-1]={actor:str(uuid.uuid4()),actor.lower():str(uuid.uuid4())}
        for hints in bad_hints:
            with self.subTest(hints_type=type(hints).__name__),self.assertRaises(RelayError):
                handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots=hints),self.peer))
        for known in (None,4,'invalid'):
            with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(1,self.body(roles=['ime'],knownEvent=known)))
        with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(2,self.body(envelope=self.envelope(),knownEvent='')))
        with self.assertRaises(RelayError):handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots={},unexpected=True),self.peer))
        self.assertEqual(self.relay.db.execute('SELECT count(*) FROM recent_nonces').fetchone()[0],baseline)
    def testConditionalSnapshotResponseBodyByteReduction(self):
        self.ready();message=self.envelope(sealed_bytes=b'S'*(512*1024))
        handle(self.relay,self.group,self.request(2,self.body(envelope=message)))
        old_hello=encoded(self.hello())
        old_pull=encoded(handle(self.relay,self.group,self.request(3,self.body(after=''),self.peer)))
        new_hello=encoded(handle(self.relay,self.group,self.request(1,self.body(roles=['ime'],knownEvent=message['event']))))
        new_pull=encoded(handle(self.relay,self.group,self.request(3,self.body(after='',knownSnapshots={self.owner:message['event']}),self.peer)))
        self.assertLess(len(new_hello)+len(new_pull),(len(old_hello)+len(old_pull))//100)
        self.assertNotIn(b'"sealed"',new_hello);self.assertNotIn(b'"sealed"',new_pull)

if __name__=='__main__':unittest.main()
