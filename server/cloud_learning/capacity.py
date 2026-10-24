"""One capacity contract for both learning producers; no implicit negotiation.

The development cutover uses one current profile across all updated devices.
Legacy is retained for old data fixtures, not a mixed-client operating mode.
Raw observations, controls and tombstones are never evicted to satisfy it.
"""
from dataclasses import dataclass
from activity_archive.service import fail
from .generated_capacity_profiles import LEGACY_5000 as CONTRACT_LEGACY_5000, EXPANDED_10000


@dataclass(frozen=True)
class CapacityProfile:
    identifier: str
    version: int
    distinct_terms: int
    model_terms: int
    response_bytes: int


def _server_profile(contract):
    return CapacityProfile(contract.id, contract.version, contract.term_rows,
                           contract.model_term_rows, contract.response_bytes)


LEGACY_5000 = _server_profile(CONTRACT_LEGACY_5000)
CURRENT = _server_profile(EXPANDED_10000)


def profile_for_group(group_id, generation):
    # Root deploys this cutover only after the current clients are delivered.
    # No arbitrary max override, device-capability table or dual-track mode.
    return CURRENT


def distinct_term_rows(db, group_id, generation):
    return db.execute('''SELECT COUNT(*) FROM (
        SELECT reading,text FROM cl_terms WHERE group_id=? AND generation=?
        UNION
        SELECT reading,text FROM cl_components WHERE group_id=? AND generation=?
    )''', (group_id, generation, group_id, generation)).fetchone()[0]


def require_term_admission(db, group_id, generation, reading, text):
    """Called under the store's existing BEGIN IMMEDIATE transaction.

    A key already held by either producer is not a new allocation, including
    deleted/reset controls. Do not count only currently active projection rows.
    At/over capacity old keys can still progress; no new key is acknowledged.
    """
    if not db.in_transaction:
        raise RuntimeError('learning capacity admission requires a transaction')
    exists = db.execute('''SELECT 1 FROM cl_terms
        WHERE group_id=? AND generation=? AND reading=? AND text=?
        UNION ALL SELECT 1 FROM cl_components
        WHERE group_id=? AND generation=? AND reading=? AND text=? LIMIT 1''',
        (group_id, generation, reading, text) * 2).fetchone()
    if exists is not None:
        return
    profile = profile_for_group(group_id, generation)
    if distinct_term_rows(db, group_id, generation) >= profile.distinct_terms:
        fail('term_capacity', 503)
