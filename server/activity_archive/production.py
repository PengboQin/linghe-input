"""Separate WSGI process, protected by an existing HTTPS reverse proxy."""
import ipaddress
import os
from pathlib import Path

from .service import ArchiveApplication, ArchiveStore, RelayMembershipAuthority
from .capacity import configured_database_bytes


class LocalArchiveProxy:
    def __init__(self, app):
        self.app = app
    def __call__(self, environ, start_response):
        if environ.get('REMOTE_ADDR') not in {'127.0.0.1', '::1'}:
            start_response('403 Forbidden', [('Content-Type', 'application/json'), ('Cache-Control', 'no-store')])
            return [b'{"version":1,"error":"proxy_required"}']
        if environ.get('PATH_INFO') != '/healthz':
            try:
                ipaddress.ip_address(environ.get('HTTP_X_PRIVATEINPUT_PEER', ''))
            except ValueError:
                start_response('400 Bad Request', [('Content-Type', 'application/json'), ('Cache-Control', 'no-store')])
                return [b'{"version":1,"error":"peer_required"}']
        return self.app(environ, start_response)


def create_app():
    database = Path(os.environ['PRIVATE_INPUT_ACTIVITY_DATABASE']).resolve()
    relay = Path(os.environ['PRIVATE_INPUT_ACTIVITY_RELAY_DATABASE']).resolve()
    if database == relay:
        raise ValueError('archive and relay databases must differ')
    # Directory must exist and be provisioned by deployment; no anonymous auth fallback.
    if not database.parent.is_dir():
        raise ValueError('provision archive database parent first')
    capacity = configured_database_bytes()
    return LocalArchiveProxy(ArchiveApplication(ArchiveStore(database, max_database_bytes=capacity), RelayMembershipAuthority(relay, activity_database=database)))
