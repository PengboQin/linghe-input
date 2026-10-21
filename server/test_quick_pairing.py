import base64
import copy
import hashlib
import unittest
import uuid
import test_relay
from private_input_relay import RelayError

class QuickPairTests(unittest.TestCase):
    setUp=test_relay.RelayTests.setUp
    tearDown=test_relay.RelayTests.tearDown
    request=test_relay.RelayTests.request
    pairing=test_relay.RelayTests.pairing
    wsgi=test_relay.RelayTests.wsgi
    def issue(self):
        self.secret=b'q'*32
        state=self.fixture['paired']
        self.ticket={'ticket':str(uuid.uuid4()).upper(),'secretHash':base64.b64encode(hashlib.sha256(self.secret).digest()).decode(),'expiresAt':self.now+300,
                     'invitation':{'version':1,'endpoint':'https://sync.example.invalid','anchor':{k:state[k] for k in ['group','ownerID','ownerPublic']}}}
        return self.app.rpc(self.group,self.request(8,self.ticket))
    def claim(self,payload):
        return self.wsgi('POST','/v1/pairing/claim',payload)
    def test_code_single_use_same_signed_request_retry_and_owner_poll(self):
        issued=self.issue();pair,_=self.pairing()
        status,result=self.claim({'code':issued['code'],'request':pair});self.assertEqual(status,200);self.assertEqual(result['invitation'],self.ticket['invitation'])
        self.assertEqual(self.claim({'code':issued['code'],'request':pair})[0],200)
        other,_=self.pairing();self.assertEqual(self.claim({'code':issued['code'],'request':other})[0],404)
        owner=self.fixture['paired']['ownerID'];seed=self.fixture['ownerSeed']
        result=self.app.rpc(self.group,self.request(9,sender=owner,seed=seed));self.assertEqual(result['claims'][0]['request'],pair)
    def test_qr_secret_and_expiry(self):
        issued=self.issue();pair,_=self.pairing()
        data={'ticket':issued['ticket'],'secret':base64.b64encode(b'x'*32).decode(),'request':pair}
        self.assertEqual(self.claim(data)[0],404)
        data['secret']=base64.b64encode(self.secret).decode();self.assertEqual(self.claim(data)[0],200)
        self.now+=301;fresh,_=self.pairing();data['request']=fresh;self.assertEqual(self.claim(data)[0],404)
    def test_new_ticket_cancels_previous_and_explicit_cancel(self):
        first=self.issue();second=self.issue();pair,_=self.pairing()
        self.assertEqual(self.claim({'code':first['code'],'request':pair})[0],404)
        self.app.rpc(self.group,self.request(10,{'ticket':second['ticket']}))
        self.assertEqual(self.claim({'code':second['code'],'request':pair})[0],404)
    def test_failed_code_attempts_consume_budget(self):
        self.issue();pair,_=self.pairing()
        for _ in range(5):self.assertEqual(self.claim({'code':'invalid','request':pair})[0],404)
        self.assertEqual(self.claim({'code':'000000','request':pair})[0],429)
        self.now+=61;pair,_=self.pairing();self.assertEqual(self.claim({'code':'invalid','request':pair})[0],404)
    def test_unrelated_group_invitation_rejected(self):
        self.issue();self.ticket['ticket']=str(uuid.uuid4()).upper();self.ticket['invitation']['anchor']['group']=str(uuid.uuid4()).upper()
        with self.assertRaises(RelayError):self.app.rpc(self.group,self.request(8,self.ticket))
    def test_member_reads_only_own_invitation_claims(self):
        issued=self.issue();pair,_=self.pairing();self.claim({'code':issued['code'],'request':pair})
        self.assertEqual(len(self.app.rpc(self.group,self.request(9))['claims']),1)
    def test_forged_pair_cannot_claim_ticket(self):
        issued=self.issue();pair,_=self.pairing();pair['member']['device']=str(uuid.uuid4()).upper()
        self.assertEqual(self.claim({'code':issued['code'],'request':pair})[0],401)
    def test_issue_retry_retains_code(self):
        issued=self.issue();again=self.app.rpc(self.group,self.request(8,self.ticket));self.assertEqual(issued,again)
