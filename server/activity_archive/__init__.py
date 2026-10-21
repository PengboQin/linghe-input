"""Opt-in plaintext archive. Importing metadata helpers never opens a database."""
from .metadata import latest_authorized_activity

__all__ = ['ArchiveApplication', 'ArchiveStore', 'ArchiveError', 'MemoryAuthority',
           'RelayMembershipAuthority', 'latest_authorized_activity']


def __getattr__(name):
    if name in __all__ and name != 'latest_authorized_activity':
        from . import service
        return getattr(service, name)
    raise AttributeError(name)
