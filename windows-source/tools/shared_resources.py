"""Locate the single public input resource source; never sync a writable fork."""
from pathlib import Path

def canonical_resources(workspace=None):
    root=Path(workspace).resolve() if workspace else Path(__file__).resolve().parents[1]
    for candidate in (root.parent/'private-input/resources',root.parent/'resources'):
        if (candidate/'rime/SOURCE.json').is_file() and (candidate/'semantic/pinyin-syllables.txt').is_file():
            return candidate.resolve()
    raise RuntimeError('Unified input resources unavailable. Use the authoritative sibling or unified public source tree; do not package the historical Windows resources copy.')
