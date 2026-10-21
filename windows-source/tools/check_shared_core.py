#!/usr/bin/env python3
"""Verify the authoritative core before building this platform workspace."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
for source in (ROOT.parent / 'private-input', ROOT.parent):
    checker = source / 'scripts/verify_shared_core.py'
    if checker.is_file():
        raise SystemExit(subprocess.call([sys.executable, str(checker), '--consumer', str(ROOT)]))
raise SystemExit('Shared core unavailable. Use the unified source tree; do not restore an independent fork.')
