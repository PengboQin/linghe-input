"""Synthetic cross-language golden; no runtime/NAS/user data."""
import copy
import json
from pathlib import Path
import unittest
from activity_archive.diagnostics import validate_decision_extensions
from activity_archive.tests import test_archive as archive_fixtures
identifier = archive_fixtures.identifier

FIXTURE = Path(__file__).resolve().parents[1] / 'fixtures' / 'decision-chain-v1.json'


class DiagnosticContractTests(unittest.TestCase):
    def test_shared_golden(self):
        cases = json.loads(FIXTURE.read_text())['cases']
        for case in cases:
            with self.subTest(name=case['name']):
                self.assertEqual(validate_decision_extensions(case['event']) is None, case['valid'])

    def test_malformed_json_types_never_raise(self):
        base = json.loads(FIXTURE.read_text())['cases'][0]['event']
        fields = list(base['extensions']['org.linghe.decision.v1'])
        for field in fields:
            for value in [None, [], {}, True, -1, 1.5]:
                if field in {'local_overlay', 'truncated'} and type(value) is bool: continue
                event = copy.deepcopy(base)
                event['extensions']['org.linghe.decision.v1'][field] = value
                with self.subTest(field=field, value_type=type(value).__name__):
                    self.assertIsNotNone(validate_decision_extensions(event))


class DiagnosticIngestTests(unittest.TestCase):
    setUp = archive_fixtures.ArchiveTests.setUp
    tearDown = archive_fixtures.ArchiveTests.tearDown
    envelope = archive_fixtures.ArchiveTests.envelope
    call = archive_fixtures.ArchiveTests.call
    assert_error = archive_fixtures.ArchiveTests.assert_error
    enable = archive_fixtures.ArchiveTests.enable
    event = archive_fixtures.ArchiveTests.event
    ingest = archive_fixtures.ArchiveTests.ingest
    # ArchiveTests supplies the exact signed ingestion/consent fixture. These
    # dedicated cases are run with an explicit test selector (no duplicated suite).
    def test_decision_provider_and_revocation_fences(self):
        self.enable()
        detail = json.loads(FIXTURE.read_text())['cases'][0]['event']
        event = self.event('444', **detail)
        self.assert_error('provider_not_allowed', 4, {'batch_id':identifier(),'events':[event]})
        self.call(3, {'expected_version':1,'enabled':True,'providers':['ime.commit.v1','ime.diagnostic.v1']})
        event['consent_version'] = 2
        self.ingest(event)
        self.call(3, {'expected_version':2,'enabled':True,'providers':['ime.commit.v1']})
        event = self.event('444', **detail); event['consent_version'] = 3
        self.assert_error('provider_not_allowed', 4, {'batch_id':identifier(),'events':[event]})
        event['provider_id']='ime.commit.v1'
        self.assert_error('diagnostic_provider', 4, {'batch_id':identifier(),'events':[event]})

    def test_golden_new_extensions_on_signed_ingestion(self):
        self.enable()
        self.call(3, {'expected_version':1,'enabled':True,'providers':['ime.commit.v1','ime.diagnostic.v1']})
        accepted = {}
        for case in json.loads(FIXTURE.read_text())['cases']:
            with self.subTest(name=case['name']):
                event = self.event('444', **case['event']); event['consent_version'] = 2
                if case['valid']:
                    result = self.ingest(event)
                    self.assertIn(event['event_id'], result['accepted_event_ids'])
                    accepted[event['event_id']] = event['extensions']
                else:
                    from activity_archive.service import ArchiveError
                    with self.assertRaises(ArchiveError): self.ingest(event)
        queried = self.call(5, {'limit':50})['events']
        self.assertEqual({event['event_id']:event['extensions'] for event in queried}, accepted)
        exported = self.call(8, {'limit':50})['jsonl']
        rows = [json.loads(line) for line in exported.splitlines()]
        self.assertEqual(rows[0]['record_type'], 'manifest')
        self.assertEqual({row['event']['event_id']:row['event']['extensions'] for row in rows[1:]}, accepted)
