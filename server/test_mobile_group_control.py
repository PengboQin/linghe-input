"""Synthetic memberships only; no live group or device configuration."""
import copy
import base64
import unittest

import device_administration as admin
import test_relay
import test_quick_pairing
from private_input_relay import RelayError


class MobileGroupControlTests(unittest.TestCase):
    def setUp(self):
        test_relay.RelayTests.setUp(self)
        self.app.db.execute("UPDATE device_profiles SET kind='unknown',last_seen=0 WHERE group_id=?",(self.group,))
    tearDown=test_relay.RelayTests.tearDown
    request=test_relay.RelayTests.request
    pairing=test_relay.RelayTests.pairing
    wsgi=test_relay.RelayTests.wsgi
    issue=test_quick_pairing.QuickPairTests.issue
    claim=test_quick_pairing.QuickPairTests.claim

    def register_kind(self,device,seed,kind):
        self.app.rpc(self.group,self.request(11,{'kind':kind},sender=device,seed=seed))

    def creator_device(self):
        return self.fixture['initial']['members'][0]['device']

    def test_new_phone_controls_even_when_desktop_created_group(self):
        desktop=self.creator_device()
        self.register_kind(desktop,self.fixture['senderSeed'],'macos')
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'ios')
        self.assertIn('code',self.issue())
        with self.assertRaises(RelayError) as rejected:
            self.app.rpc(self.group,self.request(8,self.ticket,sender=desktop,seed=self.fixture['senderSeed']))
        self.assertEqual(rejected.exception.status,403)
        # The separate founding root key is not an escape from mobile authority.
        self.assertEqual(self.app.rpc(self.group,self.request(9,sender=self.fixture['paired']['ownerID'],seed=self.fixture['ownerSeed']))['claims'],[])
        self.assertEqual(self.app.rpc(self.group,self.request(5,sender=self.fixture['paired']['ownerID'],seed=self.fixture['ownerSeed']))['requests'],[])
        self.assertIn('membership',self.app.rpc(self.group,self.request(1,sender=desktop,seed=self.fixture['senderSeed'])),'Old polling does not stop ordinary sync')

    def test_existing_desktop_ticket_cannot_be_claimed_after_phone_registers(self):
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'windows')
        self.register_kind(self.creator_device(),self.fixture['senderSeed'],'macos')
        old=self.issue()
        # Seed a newly unclassified mobile presence as a unit-test fixture;
        # production kind reclassification remains forbidden by signed op11.
        self.app.db.execute("UPDATE device_profiles SET kind='unknown' WHERE group_id=? AND device=?",(self.group,self.creator_device()))
        self.register_kind(self.creator_device(),self.fixture['senderSeed'],'android')
        pair,_=self.pairing()
        self.assertEqual(self.claim({'code':old['code'],'request':pair})[0],404)
        self.assertEqual(self.app.rpc(self.group,self.request(9))['claims'],[])
        with self.assertRaises(RelayError):self.app.rpc(self.group,self.request(10,{'ticket':old['ticket']}))

    def test_mobile_offline_does_not_transfer_control_to_desktop(self):
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'windows')
        self.register_kind(self.creator_device(),self.fixture['senderSeed'],'ios')
        self.now+=29*admin.DAY
        with self.assertRaises(RelayError):
            admin.require_group_control(self.app,self.group,self.recipient,self.now)
        # Once the existing inactivity policy actually expires the phone, this
        # is a desktop-only active group; no timer/online-status heuristic.
        self.now+=admin.DAY+1
        admin.require_group_control(self.app,self.group,self.recipient,self.now)

    def test_desktop_only_group_keeps_control(self):
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'windows')
        self.register_kind(self.creator_device(),self.fixture['senderSeed'],'macos')
        self.assertIn('code',self.issue())
        admin.require_group_control(self.app,self.group,self.creator_device(),self.now)

    def test_unclassified_joiner_does_not_open_desktop_management_window(self):
        self.register_kind(self.creator_device(),self.fixture['senderSeed'],'macos')
        with self.assertRaises(RelayError):
            admin.require_group_control(self.app,self.group,self.creator_device(),self.now)
        from activity_archive.service import RelayMembershipAuthority
        self.assertFalse(RelayMembershipAuthority(self.path).resolve(self.group,self.creator_device(),self.now).can_manage)
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'ios')
        admin.require_group_control(self.app,self.group,self.recipient,self.now)

    def test_unclassified_legacy_root_cannot_bypass_atomic_admission(self):
        from private_input_relay import Relay
        relay=Relay(self.path.parent/'unclassified.sqlite',clock=lambda:self.now)
        try:
            relay.register(self.fixture['initial'])
            with self.assertRaises(RelayError) as denied:
                relay.update(self.group,self.fixture['paired'])
            self.assertEqual(denied.exception.status,403)
            self.assertEqual(relay.state(self.group),self.fixture['initial'])
        finally:relay.db.close()

    def test_completed_admission_can_recover_lost_claim_reply_after_mobile_takeover(self):
        from private_input_relay import membership_canonical,membership_bytes
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        self.register_kind(self.creator_device(),self.fixture['senderSeed'],'macos')
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'windows')
        issued=self.issue();pair,seed=self.pairing()
        self.assertEqual(self.claim({'code':issued['code'],'request':pair})[0],200)
        # Verified historical membership + accepted-admission ledger represent
        # the completed server transaction; this is not a client pairing test.
        state=copy.deepcopy(self.app.state(self.group));state['revision']+=1;state['epoch']+=1;state['members'].append(pair['member'])
        state['signature']=base64.b64encode(Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.fixture['ownerSeed'])).sign(membership_canonical(state))).decode()
        test_relay.seed_existing_membership(self.app,state)
        phone=pair['member']['device'];self.register_kind(phone,seed,'ios')
        self.assertEqual(self.claim({'code':issued['code'],'request':pair})[0],404,'An old unaccepted claim cannot retain desktop control')
        self.app.db.execute('INSERT INTO admissions VALUES(?,?,?,?)',(self.group,pair['session'],membership_bytes(state)[2],pair['expiresAt']))
        self.assertEqual(self.claim({'code':issued['code'],'request':pair})[0],200,'Already-admitted recipient may recover metadata without new management')
        self.assertEqual(self.app.state(self.group),state)
        self.app.db.execute('INSERT INTO departed_devices VALUES(?,?,?)',(self.group,phone,'left'))
        self.assertEqual(self.claim({'code':issued['code'],'request':pair})[0],404)

    def test_readonly_desktop_poll_does_not_schedule_forbidden_expiry_cleanup(self):
        from private_input_relay import membership_canonical
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        desktop=self.creator_device()
        self.register_kind(desktop,self.fixture['senderSeed'],'macos')
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'ios')
        pair,seed=self.pairing();state=copy.deepcopy(self.app.state(self.group));state['revision']+=1;state['epoch']+=1;state['members'].append(pair['member'])
        state['signature']=base64.b64encode(Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.fixture['ownerSeed'])).sign(membership_canonical(state))).decode()
        test_relay.seed_existing_membership(self.app,state)
        phone=pair['member']['device'];self.register_kind(phone,seed,'android')
        self.now+=29*admin.DAY
        self.app.rpc(self.group,self.request(12,sender=phone,seed=seed))
        self.now+=2*admin.DAY
        pc=self.app.rpc(self.group,self.request(12,sender=desktop,seed=self.fixture['senderSeed']))
        self.assertFalse(any(d['inactive'] for d in pc['devices']),'Old desktop sync cannot enter its privileged pruning branch')
        mobile=self.app.rpc(self.group,self.request(12,sender=phone,seed=seed))
        self.assertTrue(any(d['device']==self.recipient and d['inactive'] for d in mobile['devices']),'Mobile controller retains complete cleanup information')
        with self.assertRaises(RelayError):admin.require_group_control(self.app,self.group,desktop,self.now)

    def test_archive_and_cloud_authorities_separate_control_from_sharing(self):
        from activity_archive.service import RelayMembershipAuthority
        from cloud_learning.authority import LearningMembershipAuthority
        desktop=self.creator_device()
        self.register_kind(desktop,self.fixture['senderSeed'],'macos')
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'android')
        for authority in [RelayMembershipAuthority(self.path),LearningMembershipAuthority(self.path)]:
            pc=authority.resolve(self.group,desktop,self.now)
            phone=authority.resolve(self.group,self.recipient,self.now)
            self.assertFalse(pc.can_manage)
            self.assertTrue(phone.can_manage)
            self.assertEqual(pc.permissions,3,'Normal learning and clipboard permissions stay enabled')

    def test_mobile_cannot_remove_another_phone(self):
        self.register_kind(self.recipient,self.fixture['recipientSeed'],'ios')
        self.register_kind(self.creator_device(),self.fixture['senderSeed'],'android')
        state=self.app.state(self.group);proposed=copy.deepcopy(state)
        proposed['issuer']=self.recipient
        proposed['members']=[m for m in proposed['members'] if m['device']==self.recipient]
        with self.assertRaises(RelayError):admin.authorize_change(self.app,self.group,state,proposed,self.now)

if __name__=='__main__':unittest.main()
