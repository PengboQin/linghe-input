"""Optional loopback WSGI service; never turns learning on automatically."""
import os
from pathlib import Path
from activity_archive.production import LocalArchiveProxy
from .authority import LearningMembershipAuthority
from .service import LearningApplication, LearningStore


def create_app():
    database = Path(os.environ['PRIVATE_INPUT_LEARNING_DATABASE']).resolve()
    relay = Path(os.environ['PRIVATE_INPUT_LEARNING_RELAY_DATABASE']).resolve()
    archive_value = os.environ.get('PRIVATE_INPUT_LEARNING_ACTIVITY_DATABASE')
    archive = Path(archive_value).resolve() if archive_value else None
    if database == relay or database == archive:
        raise ValueError('learning database must be independent')
    if not database.parent.is_dir():
        raise ValueError('provision learning parent directory first')
    authority = LearningMembershipAuthority(relay, activity_database=archive)
    return LocalArchiveProxy(LearningApplication(LearningStore(database), authority))
