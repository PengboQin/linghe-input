"""Current archive capacity regressions, synthetic tiny files only."""
import contextlib
import io
import os
import sqlite3
from pathlib import Path
import unittest
from unittest.mock import patch

import test_archive as fixture
from activity_archive.admin import main as admin
from activity_archive.capacity import (DEFAULT_DATABASE_BYTES, DEFAULT_GROUP_BYTES,
                                       MAX_LEDGER_BYTES, configured_database_bytes)
from activity_archive.service import ArchiveStore
from activity_archive.production import create_app
from activity_archive.metadata import latest_authorized_activity


class CapacityTests(unittest.TestCase):
    setUp = fixture.ArchiveTests.setUp
    tearDown = fixture.ArchiveTests.tearDown
    envelope = fixture.ArchiveTests.envelope
    call = fixture.ArchiveTests.call
    assert_error = fixture.ArchiveTests.assert_error
    enable = fixture.ArchiveTests.enable
    event = fixture.ArchiveTests.event
    ingest = fixture.ArchiveTests.ingest

    def test_new_defaults_and_existing_policy_are_distinct(self):
        status = self.call(1, {})
        self.assertFalse(status['enabled'])
        self.assertIsNone(status['consent'])
        self.assertEqual(status['limits']['retention_days'], 30)
        self.assertEqual(status['limits']['max_group_bytes'], 4 * 1024 ** 3)
        self.enable()  # Existing explicit 100MiB policy stays intact on reopen.
        self.store.close()
        self.store = ArchiveStore(self.path, clock=lambda: self.now)
        self.app = fixture.ArchiveApplication(self.store, self.authority, clock=lambda: self.now)
        self.assertEqual(self.call(1, {})['limits']['max_group_bytes'], 104857600)
        # No schema migration: even an old table's100MiB SQL default must not
        # dictate a newly inserted group's current4GiB policy.
        old_path = self.path.parent / 'old-column-default.sqlite'
        old = sqlite3.connect(old_path)
        old.execute('CREATE TABLE archive_groups(group_id TEXT PRIMARY KEY, policy_version INTEGER NOT NULL DEFAULT 0, enabled INTEGER NOT NULL DEFAULT 0, retention_days INTEGER NOT NULL DEFAULT 30, max_group_bytes INTEGER NOT NULL DEFAULT 104857600, acl_version INTEGER NOT NULL DEFAULT 0)')
        old.execute('INSERT INTO archive_groups(group_id) VALUES(?)', (self.group,))
        old.commit(); old.close()
        reopened = ArchiveStore(old_path, clock=lambda: self.now)
        try:
            with reopened.transaction():
                self.assertEqual(reopened.group(self.group)['max_group_bytes'], 104857600)
                self.assertEqual(reopened.group(self.other_group)['max_group_bytes'], DEFAULT_GROUP_BYTES)
            self.assertIn('DEFAULT 104857600', reopened.db.execute("SELECT sql FROM sqlite_master WHERE name='archive_groups'").fetchone()[0])
        finally:
            reopened.close()

    def test_signed_four_gib_policy_preserves_device_consent(self):
        self.enable()
        consent = self.call(1, {})['consent']
        policy = {'expected_version': 1, 'enabled': True, 'retention_days': 30,
                  'max_group_bytes': 4 * 1024 ** 3}
        self.assert_error('manage_permission', 2, policy, actor=self.b)
        self.assertEqual(self.call(2, policy)['max_group_bytes'], 4294967296)
        status = self.call(1, {})
        self.assertEqual(status['limits']['max_group_bytes'], 4294967296)
        self.assertEqual(status['consent'], consent)
        self.assertEqual(status['limits']['retention_days'], 30)
        self.assert_error('policy_conflict', 2, policy)
        policy.update(expected_version=2, max_group_bytes=4294967297)
        self.assert_error('integer', 2, policy)
        self.assertEqual(self.call(1, {})['policy_version'], 2)

    def test_ingest_counts_bytes_once_and_duplicates_never_spend_quota(self):
        self.enable()
        first = self.event('synthetic prior')
        self.ingest(first)
        events = [first, self.event('synthetic second'), self.event('synthetic third')]
        sql = []
        self.store.db.set_trace_callback(sql.append)
        result = self.ingest(*events)
        self.store.db.set_trace_callback(None)
        aggregates = [q for q in sql if 'SUM(size_bytes)' in q]
        self.assertEqual(len(aggregates), 1)
        self.assertNotIn('COUNT', aggregates[0])
        self.assertEqual(result['duplicate_event_ids'], [first['event_id']])
        self.assertEqual(len(result['accepted_event_ids']), 2)
        used = self.store.db.execute('SELECT SUM(size_bytes) FROM events').fetchone()[0]
        self.assertEqual(used, sum(len(fixture.encode(e)) for e in events))
        sql.clear()
        self.store.db.set_trace_callback(sql.append)
        retry = self.ingest(*events)
        self.store.db.set_trace_callback(None)
        self.assertEqual(len([q for q in sql if 'SUM(size_bytes)' in q]), 1)
        self.assertEqual(retry['accepted_event_ids'], [])
        self.assertEqual(set(retry['duplicate_event_ids']), {e['event_id'] for e in events})
        self.assertEqual(self.store.db.execute('SELECT SUM(size_bytes) FROM events').fetchone()[0], used)

    def test_failed_batch_rolls_back_new_bytes_and_receipt(self):
        self.call(2, {'expected_version': 0, 'enabled': True, 'retention_days': 30, 'max_group_bytes': 1048576})
        self.call(3, {'expected_version': 0, 'enabled': True, 'providers': ['ime.commit.v1']})
        self.ingest(*[self.event('x' * 140000) for _ in range(3)])
        self.ingest(*[self.event('x' * 140000) for _ in range(3)])
        prior = self.store.db.execute('SELECT COUNT(*),SUM(size_bytes) FROM events').fetchone()
        receipts = self.store.db.execute('SELECT COUNT(*) FROM ingest_receipts').fetchone()[0]
        batch = fixture.identifier()
        rejected = [self.event('x' * 140000), self.event('x' * 140000)]
        self.assert_error('group_capacity', 4, {'batch_id': batch, 'events': rejected})
        after = self.store.db.execute('SELECT COUNT(*),SUM(size_bytes) FROM events').fetchone()
        self.assertEqual(tuple(prior), tuple(after))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM ingest_receipts').fetchone()[0], receipts)
        self.assertEqual(self.ingest(self.event('accepted after rollback'))['duplicate_event_ids'], [])

    def test_http_and_retention_cli_share_sixteen_gib_budget(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(configured_database_bytes(), 16 * 1024 ** 3)
        with patch.dict(os.environ, {'PRIVATE_INPUT_ACTIVITY_MAX_DATABASE_BYTES': str(16 * 1024 ** 3 + 1)}):
            with self.assertRaises(ValueError):
                configured_database_bytes()
        expected = DEFAULT_DATABASE_BYTES // self.store.db.execute('PRAGMA page_size').fetchone()[0]
        self.assertEqual(self.store.db.execute('PRAGMA max_page_count').fetchone()[0], expected)
        self.store.close()
        environment = {'PRIVATE_INPUT_ACTIVITY_MAX_DATABASE_BYTES': str(DEFAULT_DATABASE_BYTES),
                       'PRIVATE_INPUT_ACTIVITY_DATABASE': str(self.path),
                       'PRIVATE_INPUT_ACTIVITY_RELAY_DATABASE': str(self.path.parent / 'unused-relay.sqlite')}
        with patch.dict(os.environ, environment), patch('activity_archive.admin.ArchiveStore', wraps=ArchiveStore) as opened, contextlib.redirect_stdout(io.StringIO()):
            admin(['expire', '--database', str(self.path)])
            opened.assert_called_once_with(self.path, max_database_bytes=DEFAULT_DATABASE_BYTES)
        with patch.dict(os.environ, environment), patch('activity_archive.production.ArchiveStore', wraps=ArchiveStore) as opened, patch('activity_archive.production.RelayMembershipAuthority', return_value=self.authority):
            app = create_app()
            opened.assert_called_once_with(self.path.resolve(), max_database_bytes=DEFAULT_DATABASE_BYTES)
            app.app.store.close()
        self.store = ArchiveStore(self.path, clock=lambda: self.now)
        self.assertEqual(self.store.db.execute('PRAGMA max_page_count').fetchone()[0], expected)
        self.assertEqual(DEFAULT_GROUP_BYTES, 4294967296)
        self.assertEqual(MAX_LEDGER_BYTES, 1073741824)
        root = Path(__file__).resolve().parents[1]
        for unit in ['private-input-activity.service', 'private-input-activity-expire.service']:
            self.assertIn('PRIVATE_INPUT_ACTIVITY_MAX_DATABASE_BYTES=17179869184', (root / 'deploy' / unit).read_text())

    def test_database_page_limit_fails_atomically_without_allocating_large_file(self):
        self.enable()
        pages = self.store.db.execute('PRAGMA page_count').fetchone()[0]
        self.store.db.execute('PRAGMA max_page_count=' + str(pages + 2))
        before = self.store.db.execute('SELECT COUNT(*) FROM events').fetchone()[0]
        self.assert_error('archive_capacity', 4, {'batch_id': fixture.identifier(), 'events': [self.event('x' * 140000)]})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM events').fetchone()[0], before)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM ingest_receipts').fetchone()[0], 0)
        self.assertFalse(self.store.db.in_transaction)

    def test_liveness_reader_accepts_sixteen_gib_boundary_without_large_fixture(self):
        self.enable()
        self.ingest(self.event('synthetic liveness'))
        original_stat = Path.stat
        reported_size = 12 * 1024 ** 3
        def stat(path, *args, **kwargs):
            value = original_stat(path, *args, **kwargs)
            if path == self.path:
                fields = list(value); fields[6] = reported_size
                return os.stat_result(fields)
            return value
        with patch.object(Path, 'stat', stat):
            self.assertEqual(latest_authorized_activity(self.path, self.group, self.a, self.members[self.a][0], now=self.now), self.now)
            reported_size = DEFAULT_DATABASE_BYTES + 1
            self.assertIsNone(latest_authorized_activity(self.path, self.group, self.a, self.members[self.a][0], now=self.now))


if __name__ == '__main__':
    unittest.main()
