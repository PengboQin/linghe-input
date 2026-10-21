"""Synthetic source contracts only; no deployment, relay mutation or NAS access."""
import contextlib
import io
from pathlib import Path
import shutil
import test_archive as fixture
import unittest

from activity_archive.admin import main as admin


class GroupRecoveryTests(unittest.TestCase):
    setUp = fixture.ArchiveTests.setUp
    tearDown = fixture.ArchiveTests.tearDown
    envelope = fixture.ArchiveTests.envelope
    call = fixture.ArchiveTests.call
    assert_error = fixture.ArchiveTests.assert_error
    enable = fixture.ArchiveTests.enable
    event = fixture.ArchiveTests.event
    ingest = fixture.ArchiveTests.ingest

    def reopen(self, path=None):
        self.store = fixture.ArchiveStore(path or self.path, clock=lambda: self.now)
        self.app = fixture.ArchiveApplication(self.store, self.authority, clock=lambda: self.now)

    def raw_rollback(self, snapshot):
        self.store.close()
        for suffix in ['', '-wal', '-shm']:
            Path(str(self.path) + suffix).unlink(missing_ok=True)
        shutil.copyfile(snapshot, self.path)
        self.reopen()

    def test_unrotated_rollback_rejects_increment_and_snapshot_above_watermark(self):
        self.enable()
        self.ingest(self.event())
        backup = Path(self.temp.name) / 'early.sqlite'
        self.store.backup(backup)
        self.ingest(self.event(), self.event())
        changes = self.call(6, {})['next_cursor']
        page = self.call(5, {'limit': 1})['next_cursor']
        self.raw_rollback(backup)
        self.assert_error('cursor_source_rewound', 6, {'cursor': changes})
        self.assert_error('cursor_source_rewound', 5, {'cursor': page})

    def test_admin_restore_rotates_identity_even_when_new_history_catches_up(self):
        self.enable()
        self.ingest(self.event('synthetic original'))
        backup = Path(self.temp.name) / 'early.sqlite'
        self.store.backup(backup)
        self.ingest(self.event(), self.event())
        changes = self.call(6, {})['next_cursor']
        page = self.call(5, {'limit': 1})['next_cursor']
        key = self.store.cursor_key
        ledger = Path(str(self.path) + '.erase-ledger.jsonl')
        ledger.touch(exist_ok=True)
        self.store.close()
        target = Path(self.temp.name) / 'restored.sqlite'
        with contextlib.redirect_stdout(io.StringIO()):
            admin(['restore', '--database', str(target), '--snapshot', str(backup), '--ledger', str(ledger)])
        self.reopen(target)
        self.assertNotEqual(key, self.store.cursor_key)
        self.assertEqual(self.store.cursor_key, bytes(self.store.db.execute("SELECT value FROM metadata WHERE key='cursor_key'").fetchone()[0]))
        self.ingest(self.event('synthetic replacement'), self.event('synthetic replacement 2'))
        self.assertEqual(self.store.high(self.group), 3)
        self.assert_error('cursor', 6, {'cursor': changes})
        self.assert_error('cursor', 5, {'cursor': page})
        self.assertEqual(len(self.call(7, {})['events']), 3)
        restored_key = self.store.cursor_key
        current = self.call(6, {})['next_cursor']
        self.store.close()
        self.reopen(target)
        self.assertEqual(restored_key, self.store.cursor_key)
        self.assertEqual(self.call(6, {'cursor': current})['changes'], [])

    def test_group_same_ids_increment_erase_and_ledger_restore_remain_isolated(self):
        self.enable()
        self.enable(actor=self.d, group=self.other_group)
        left = self.event('synthetic A', seq=1)
        right = self.event('synthetic B', actor=self.d, group=self.other_group, seq=1, event_id=left['event_id'])
        self.ingest(left)
        self.ingest(right, actor=self.d, group=self.other_group)
        cursor_b = self.call(6, {}, actor=self.d, group=self.other_group)['next_cursor']
        self.assertEqual(self.call(5, {})['events'][0]['content'], left['content'])
        self.assertEqual(self.call(5, {}, actor=self.d, group=self.other_group)['events'][0]['content'], right['content'])
        self.assertNotIn('synthetic B', self.call(8, {})['jsonl'])
        backup = Path(self.temp.name) / 'two-groups.sqlite'
        self.store.backup(backup)
        self.call(9, {'event_ids': [left['event_id']]})
        self.assertEqual(self.call(6, {'cursor': cursor_b}, actor=self.d, group=self.other_group)['changes'], [])
        self.raw_rollback(backup)  # Exercises newest ledger replay, not sanctioned cursor recovery.
        self.assertEqual(self.call(5, {})['events'], [])
        self.assertEqual(self.call(5, {}, actor=self.d, group=self.other_group)['events'][0]['content'], right['content'])
        self.assert_error('event_erased', 4, {'batch_id': fixture.identifier(), 'events': [left]})
        self.assertEqual(self.store.erase_reason(self.group, left['event_id']), 'user_erase')
        self.assertEqual(self.store.high(self.other_group), 1)

    def test_retention_and_explicit_erase_reason_do_not_cross_groups(self):
        self.enable()
        self.enable(actor=self.d, group=self.other_group)
        left = self.event('synthetic expiry')
        right = self.event('synthetic retained', actor=self.d, group=self.other_group, event_id=left['event_id'])
        self.ingest(left)
        self.ingest(right, actor=self.d, group=self.other_group)
        self.call(2, {'expected_version': 1, 'enabled': True, 'retention_days': 1, 'max_group_bytes': 104857600})
        self.now += 2 * 86400
        self.assertEqual(self.call(5, {})['events'], [])
        self.assertEqual(self.store.erase_reason(self.group, left['event_id']), 'retention_expire')
        self.call(9, {'event_ids': [left['event_id']]})
        self.assertEqual(self.store.erase_reason(self.group, left['event_id']), 'user_erase')
        self.assertEqual(len(self.call(5, {}, actor=self.d, group=self.other_group)['events']), 1)
        self.assertEqual(self.store.high(self.other_group), 1)

    def test_reader_revocation_and_policy_reopen_do_not_restore_old_grants(self):
        self.enable(actor=self.b, readers=[self.a])
        item = self.event(actor=self.b)
        self.ingest(item, actor=self.b)
        cursor = self.call(6, {})['next_cursor']
        self.call(3, {'expected_version': 1, 'enabled': False, 'providers': ['ime.commit.v1'], 'readers': []}, actor=self.b)
        self.assert_error('cursor_stale', 6, {'cursor': cursor})
        self.assertEqual(self.call(5, {})['events'], [])
        # Own historical read is an explicit v1 contract, even while capture is paused.
        self.assertEqual(len(self.call(5, {}, actor=self.b)['events']), 1)
        self.call(2, {'expected_version': 1, 'enabled': False, 'retention_days': 30, 'max_group_bytes': 104857600})
        self.call(2, {'expected_version': 2, 'enabled': True, 'retention_days': 30, 'max_group_bytes': 104857600})
        self.assertFalse(self.call(1, {}, actor=self.b)['consent']['enabled'])
        self.assert_error('consent_disabled', 4, {'batch_id': fixture.identifier(), 'events': [item]}, actor=self.b)
        self.assert_error('group', 1, {}, group=fixture.identifier())

    def test_rejoin_current_membership_stales_cursor_but_same_identity_retains_consent(self):
        self.enable(actor=self.b)
        self.ingest(self.event(actor=self.b), actor=self.b)
        cursor = self.call(6, {}, actor=self.b)['next_cursor']
        remaining = {k: v for k, v in self.members.items() if k != self.b}
        self.authority.put(self.group, remaining, revision=2)
        self.assert_error('member', 1, {}, actor=self.b)
        self.authority.put(self.group, self.members, revision=3)
        self.assert_error('cursor_stale', 6, {'cursor': cursor}, actor=self.b)
        # Characterizes an existing boundary: same ID/key re-admission is not a
        # new consent incarnation. Do not claim new opt-in is enforced here.
        self.assertTrue(self.call(1, {}, actor=self.b)['consent']['enabled'])
        self.ingest(self.event('synthetic after readmission', actor=self.b), actor=self.b)

    def test_installation_reset_and_group_switch_do_not_relabel_history(self):
        self.enable()
        old = self.event('synthetic old group', seq=1)
        self.ingest(old)
        members = {self.d: (self.keys[self.d].public_key().public_bytes(fixture.Encoding.Raw, fixture.PublicFormat.Raw), 3), self.a: self.members[self.a]}
        self.authority.put(self.other_group, members, revision=2)
        self.enable(actor=self.a, group=self.other_group)
        new = self.event('synthetic new group', group=self.other_group, seq=1, installation_id=fixture.identifier())
        self.ingest(new, group=self.other_group)
        self.assert_error('event_identity', 4, {'batch_id': fixture.identifier(), 'events': [old]}, group=self.other_group)
        self.assertEqual(self.call(5, {})['events'][0]['device_group'], self.group)
        self.assertEqual(self.call(5, {}, group=self.other_group)['events'][0]['installation_id'], new['installation_id'])
        self.assertNotEqual(new['installation_id'], old['installation_id'])
        replacement = self.event('synthetic reinstall same group', seq=1, installation_id=fixture.identifier())
        self.ingest(replacement)
        self.assertEqual(len(self.call(5, {})['events']), 2)

    def test_admin_restore_corrupt_ledger_does_not_return_success(self):
        self.enable()
        backup = Path(self.temp.name) / 'snapshot.sqlite'
        self.store.backup(backup)
        ledger = Path(self.temp.name) / 'corrupt.jsonl'
        ledger.write_text('invalid ledger\n')
        with self.assertRaises((ValueError, fixture.ArchiveError)), contextlib.redirect_stdout(io.StringIO()):
            admin(['restore', '--database', str(Path(self.temp.name) / 'failed.sqlite'), '--snapshot', str(backup), '--ledger', str(ledger)])

    def test_official_restore_replays_latest_ledger_and_invalidates_both_groups(self):
        self.enable()
        self.enable(actor=self.d, group=self.other_group)
        left = self.event('synthetic erased A')
        right = self.event('synthetic surviving B', actor=self.d, group=self.other_group, event_id=left['event_id'])
        self.ingest(left)
        self.ingest(right, actor=self.d, group=self.other_group)
        cursor_a = self.call(6, {})['next_cursor']
        cursor_b = self.call(6, {}, actor=self.d, group=self.other_group)['next_cursor']
        backup = Path(self.temp.name) / 'snapshot.sqlite'
        self.store.backup(backup)
        self.call(9, {'event_ids': [left['event_id']]})
        ledger = Path(str(self.path) + '.erase-ledger.jsonl')
        self.store.close()
        target = Path(self.temp.name) / 'restored.sqlite'
        with contextlib.redirect_stdout(io.StringIO()):
            admin(['restore', '--database', str(target), '--snapshot', str(backup), '--ledger', str(ledger)])
        self.reopen(target)
        self.assert_error('cursor', 6, {'cursor': cursor_a})
        self.assert_error('cursor', 6, {'cursor': cursor_b}, actor=self.d, group=self.other_group)
        self.assertEqual(self.call(5, {})['events'], [])
        self.assertEqual(self.call(5, {}, actor=self.d, group=self.other_group)['events'][0]['content'], right['content'])
        self.assertEqual(self.store.erase_reason(self.group, left['event_id']), 'user_erase')


if __name__ == '__main__':
    unittest.main()
