#!/usr/bin/env python3
"""Pinned conservative reading boundary for affected simplified carriers.

No network or mutation on import. Data is a community pronunciation reference,
not an official language standard. Uncovered/unaffected characters stay unknown.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import os
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REFERENCE_REVISION = 'da1fbe602e38f26db846fa10120ee64c2b0324c0'
REFERENCE = ROOT / 'vendor/dictionaries/rime-ice' / REFERENCE_REVISION
HEADER = ROOT / 'core/include/private_modern_readings.h'
POLICY = 'modern-collapsed-carriers-v1'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def standard_characters():
    path = ROOT / 'resources/rime/charset/standard-8105.txt'
    metadata = json.loads(path.with_name('SOURCE.json').read_text())
    if digest(path) != metadata['sha256']:
        raise ValueError('Standard-character source differs from lock')
    result = path.read_text().splitlines()
    if len(result) != 8105 or len(set(result)) != 8105 or any(len(c) != 1 for c in result):
        raise ValueError('Invalid standard-character table')
    return set(result)


def dictionary_rows(path):
    text = path.read_text()
    if '\n...\n' not in text:
        raise ValueError('Dictionary header separator missing')
    for line in text.split('\n...\n', 1)[1].splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) not in (2, 3) or not fields[0] or not re.fullmatch('[a-z]+(?: [a-z]+)*', fields[1]):
            raise ValueError('Unexpected public dictionary row')
        yield fields[0], fields[1], fields[2] if len(fields) == 3 else ''


def reference_metadata():
    metadata = json.loads((REFERENCE / 'SOURCE.json').read_text())
    if metadata['revision'] != REFERENCE_REVISION:
        raise ValueError('Reading-reference revision differs')
    for record in metadata['files']:
        if digest(REFERENCE / record['path']) != record['sha256']:
            raise ValueError('Reading-reference file differs from lock')
    return metadata


def load_reference():
    reference_metadata()
    standard = standard_characters()
    result = {}
    for character, reading, _ in dictionary_rows(REFERENCE / 'cn_dicts/8105.dict.yaml'):
        if len(character) == 1 and character in standard:
            result.setdefault(character, set()).add(reading)
    return result


def load_luna():
    lock = json.loads((ROOT / 'docs/stages/P2/dictionary/upstream.lock.json').read_text())
    record = next(x for x in lock['repositories'] if x['repository'].endswith('/rime-luna-pinyin'))
    path = ROOT / 'vendor/dictionaries/rime-luna-pinyin' / record['revision'] / 'luna_pinyin.dict.yaml'
    file = next(x for x in record['files'] if x['path'] == 'luna_pinyin.dict.yaml')
    if digest(path) != file['sha256']:
        raise ValueError('Original Luna source differs from lock')
    return path


def load_character_mapping():
    metadata = reference_metadata()['opencc']
    dependency = next(x for x in json.loads((ROOT / 'docs/stages/P1/dependencies.lock.json').read_text()) if x['name'] == 'opencc')
    path = ROOT / metadata['path']
    if dependency['commit'] != metadata['revision'] or digest(path) != metadata['sha256']:
        raise ValueError('Character conversion source differs from lock')
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) != 2:
            raise ValueError('Unexpected OpenCC character mapping')
        # OpenCC's character dictionary uses the first candidate by default.
        result[fields[0]] = fields[1].split(' ')[0]
    return result


def affected_from_rows(rows, mapping, standard):
    """Only original single-character rows define the influence boundary.

    Include both a converted-to standard carrier and a standard original that
    conversion would erase (e.g.乾/徵). Different readings of an unchanged glyph
    alone do not make it affected. Zero-weight rows cannot introduce a new
    reading, but still document that a glyph participated in conversion.
    """
    affected, provenance = set(), {}
    for character, reading, _ in rows:
        if len(character) != 1:
            continue
        target = mapping.get(character, character)
        if target == character or len(target) != 1:
            continue
        carriers = {c for c in (character, target) if c in standard}
        for carrier in carriers:
            affected.add(carrier)
            provenance.setdefault(carrier, set()).add((character, target))
    return affected, provenance


def load_affected():
    return affected_from_rows(dictionary_rows(load_luna()), load_character_mapping(), standard_characters())


def allowed_readings():
    reference = load_reference()
    affected, _ = load_affected()
    # Unknown reference coverage must not become an empty/deny-all rule.
    return {character: set(reference[character]) for character in affected if reference.get(character)}


def is_automatic_reading_allowed(character, reading):
    values = allowed_readings().get(character)
    return values is None or reading in values


def generate_header(values=None):
    values = allowed_readings() if values is None else values
    lines = [
        '// Generated by scripts/modern_reading_reference.py; do not edit.',
        '// Conservative community reference, not an official pronunciation standard.',
        '// GPL-3.0 source/header notices: vendor/dictionaries/rime-ice/' + REFERENCE_REVISION + '/SOURCE.json and LICENSE.',
        '// Membership/source provenance: resources/rime/charset/SOURCE.json; pinned OpenCC TSCharacters.',
        '#pragma once', '#include <cstdint>',
        'namespace private_input { namespace mainland {',
        'struct ModernReadingCharacter { uint32_t codepoint; const char *readings; };',
        'inline constexpr const char modern_reading_policy[] = "' + POLICY + '";',
        'inline constexpr ModernReadingCharacter modern_reading_characters[] = {'
    ]
    for character in sorted(values, key=ord):
        readings = sorted(values[character])
        if not readings or any(not re.fullmatch('[a-z]+', p) for p in readings):
            raise ValueError('Unexpected generated reading token')
        lines.append('  {0x%Xu, "%s"},' % (ord(character), ' '.join(readings)))
    lines += ['};', 'inline constexpr auto modern_reading_character_count = sizeof(modern_reading_characters) / sizeof(modern_reading_characters[0]);', '}}', '']
    return '\n'.join(lines)


def analysis_report():
    reference = load_reference()
    affected, provenance = load_affected()
    values = allowed_readings()
    current_path = ROOT / 'resources/rime/private_pinyin.dict.yaml'
    singles, words = {}, []
    for text, reading, _ in dictionary_rows(current_path):
        if len(text) == 1:
            singles.setdefault(text, set()).add(reading)
        else:
            words.append((text, reading))
    blocked, added = [], []
    for character, readings in values.items():
        blocked.extend([character, reading] for reading in singles.get(character, set()) - readings)
        added.extend([character, reading] for reading in readings - singles.get(character, set()))
    exceptions, unaligned = [], []
    for text, reading in words:
        parts = reading.split(' ')
        if len(text) != len(parts):
            if any(c in values for c in text):
                unaligned.append({'text': text, 'reading': reading})
            continue
        invalid = [[c, p] for c, p in zip(text, parts) if c in values and p not in values[c]]
        if invalid:
            exceptions.append({'text': text, 'reading': reading, 'blockedPairs': invalid})
    all_reference_characters = {c for c, _, _ in dictionary_rows(REFERENCE / 'cn_dicts/8105.dict.yaml') if len(c) == 1}
    standard = standard_characters()
    metadata = reference_metadata()
    return {
        'policy': POLICY, 'referenceRepository': metadata['repository'], 'referenceRevision': REFERENCE_REVISION,
        'referenceLicense': metadata['license'], 'referenceIsOfficialNormativeAuthority': False,
        'referenceInputSHA256': metadata['files'], 'originalLunaSHA256': digest(load_luna()),
        'openccInput': metadata['opencc'], 'standardCharacters': 8105,
        'referenceCoveredStandardCharacters': len(reference),
        'referenceMissingStandardCharacters': sorted(standard - set(reference)),
        'referenceExtraCharactersExcluded': len(all_reference_characters - standard),
        'affectedCharacters': len(affected), 'controlledCharacters': len(values),
        'affectedButUncoveredNotDenied': sorted(affected - set(values)),
        'controlledReadingPairs': sum(map(len, values.values())),
        'blockedCurrentSinglePairs': sorted(blocked), 'addedReferenceSinglePairs': sorted(added),
        'restoredCarrierCharactersPendingResourceGeneration': sorted(c for c in values if c not in singles),
        'existingMultiwordRows': len(words), 'multiwordRowsRequiringExplicitExceptionReview': exceptions,
        'unalignedExistingMultiwordRowsRequiringReview': unaligned,
        'affectedCarrierProvenance': {c: [list(x) for x in sorted(provenance[c])] for c in sorted(affected)},
        'headerSHA256': hashlib.sha256(generate_header(values).encode()).hexdigest(),
        'scope': 'Only source-influenced standard single carriers. Runtime use is automatic candidates only; never user records/literal/archive rewriting. Explicit personal entries require separate provenance-aware handling.'
    }


def output_path(path):
    path = path.absolute()
    resolved = path.resolve()
    if not any(resolved.is_relative_to(ROOT / root) for root in ['build', 'evidence']):
        raise ValueError('Research outputs must stay in project build/evidence')
    return path


def write_text_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix='.modern-reading-', suffix='.tmp', delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(content); handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, path); temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Write a reproducible header copy under build/evidence')
    parser.add_argument('--report', type=Path, help='Write statistics/provenance under build/evidence')
    parser.add_argument('--write-header', action='store_true', help='Explicitly replace only the generated formal header')
    args = parser.parse_args()
    target_header = output_path(args.output) if args.output else None
    target_report = output_path(args.report) if args.report else None
    content = generate_header()
    if args.write_header:
        write_text_atomic(HEADER, content)
    elif not args.output and (not HEADER.is_file() or HEADER.read_text() != content):
        raise SystemExit('Generated modern-reading header differs from pinned input')
    if target_header:
        write_text_atomic(target_header, content)
    report = analysis_report()
    if target_report:
        write_text_atomic(target_report, json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['policy', 'affectedCharacters', 'controlledCharacters', 'controlledReadingPairs', 'headerSHA256']}))


if __name__ == '__main__':
    main()
