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
from private_input_relay import Relay, RelayError, encoded, integer_bytes, strict_json
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
    def envelope(self):
        m=dict(version=1,group=self.group,sender=self.owner,event=str(uuid.uuid4()).upper(),epoch=self.epoch,
               issuedAt=self.now,expiresAt=self.now+604800,sealed=base64.b64encode(b'Synthetic encrypted opaque data').decode(),signature='')
        *_,sealed,header=envelope_header(m)
        m['signature']=base64.b64encode(Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.seeds[self.owner])).sign(header+sealed)).decode()
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

if __name__=='__main__':unittest.main()
