"""Bounded additive decision evidence. No authorization, storage or networking here.
Existing authorized v1 payload fields are unchanged. Caller checks provider
consent first; neither old raw spelling nor new snapshots may use commit consent.
"""

KEY = 'org.linghe.decision.v1'
LINK_KEY = 'org.linghe.decision-link.v1'
STAGES = {'input', 'candidates', 'press', 'release', 'selection', 'commit', 'cancel', 'feedback', 'error', 'marked_text'}
SOURCES = {'exact', 'public', 'personal', 'cloud', 'correction', 'semantic', 'literal', 'unknown'}
IDS = {'composition_id', 'state_id', 'clock_domain', 'snapshot_id', 'decision_id', 'press_state_id', 'release_state_id', 'selected_candidate_id', 'output_event_id', 'related_decision_id'}
HASHES = {'core_hash', 'resource_hash', 'policy_hash', 'model_hash'}
COUNTS = {'revision', 'monotonic_us', 'total_count', 'observed_count', 'selected_rank', 'recall_count', 'filtered_count', 'press_monotonic_us', 'release_monotonic_us'}
REQUIRED = {'version', 'composition_id', 'revision', 'state_id', 'stage', 'clock_domain', 'monotonic_us'}
ALLOWED = REQUIRED | IDS | HASHES | COUNTS | {'candidates', 'selected_candidate', 'truncated', 'coverage', 'method', 'reason', 'model_version', 'local_overlay', 'filter_reason_counts', 'label_source', 'intended_text', 'marked_text', 'marked_status'}
MAX_INT = 9007199254740991  # lossless Swift/Java/JS/Python interchange


def validate_decision_extensions(event):
    """Return None on success, a stable content-free error tag otherwise."""
    ext = event.get('extensions') or {}
    if LINK_KEY in ext:
        link = ext[LINK_KEY]
        if (event.get('event_type') not in {'input_commit', 'paste_action', 'text_revise', 'text_retract'}
                or type(link) is not dict or not link or not set(link) <= {'composition_id', 'decision_id', 'state_id'}
                or not all(_tag(v) for v in link.values())):
            return 'diagnostic_link'
    if (KEY in ext or 'org.linghe.input.v1' in ext) and (event.get('provider_id') != 'ime.diagnostic.v1' or event.get('event_type') != 'source_import'
            or event.get('source_kind') != 'ime_diagnostic' or event.get('commit_confirmation') != 'not_applicable'):
        return 'diagnostic_provider'
    if KEY not in ext:
        return None
    value = ext[KEY]
    if type(value) is not dict or not REQUIRED <= set(value) or not set(value) <= ALLOWED:
        return 'diagnostic_fields'
    if type(value['version']) is not int or value['version'] != 1 or type(value['stage']) is not str or value['stage'] not in STAGES:
        return 'diagnostic_version_stage'
    for key in IDS & set(value):
        if not _tag(value[key]):
            return 'diagnostic_id'
    for key in HASHES & set(value):
        s = value[key]
        if type(s) is not str or len(s) != 64 or any(c not in '0123456789abcdef' for c in s):
            return 'diagnostic_hash'
    for key in COUNTS & set(value):
        if not _number(value[key]):
            return 'diagnostic_count'
    for key in {'reason', 'model_version'} & set(value):
        if not _tag(value[key]):
            return 'diagnostic_tag'
    for key in {'truncated', 'local_overlay'} & set(value):
        if type(value[key]) is not bool:
            return 'diagnostic_bool'
    if 'method' in value and (type(value['method']) is not str or value['method'] not in {'touch', 'mouse', 'space', 'number', 'enter', 'gesture', 'unknown'}):
        return 'diagnostic_method'
    if 'label_source' in value and (type(value['label_source']) is not str or value['label_source'] not in {'user_confirmed', 'weak_signal', 'synthetic'}):
        return 'diagnostic_label'
    if 'marked_text' in value and (type(value['marked_text']) is not str or not _text_limit(value['marked_text'], 4096)):
        return 'diagnostic_marked'
    if 'marked_status' in value and (type(value['marked_status']) is not str or value['marked_status'] not in {'not_used', 'insert_requested', 'host_acknowledged', 'host_rejected', 'unknown'}):
        return 'diagnostic_marked'
    if 'intended_text' in value and (value['stage'] != 'feedback' or 'label_source' not in value or not _text(value['intended_text'])):
        return 'diagnostic_intended'
    if 'filter_reason_counts' in value:
        rows = value['filter_reason_counts']
        if type(rows) is not dict or len(rows) > 8 or not all(_tag(k) and _number(v) for k, v in rows.items()):
            return 'diagnostic_filters'
    if 'selected_candidate' in value:
        selected = value['selected_candidate']
        if not _candidate(selected):
            return 'diagnostic_selected'
        if value.get('selected_candidate_id', selected['candidate_id']) != selected['candidate_id'] or value.get('selected_rank', selected['absolute_rank']) != selected['absolute_rank']:
            return 'diagnostic_selected'
    if 'candidates' in value:
        rows = value['candidates']
        if (type(rows) is not list or len(rows) > 5 or value.get('observed_count') != len(rows)
                or type(value.get('coverage')) is not str or value.get('coverage') not in {'published_subset', 'visible_subset', 'complete_set'} or type(value.get('truncated')) is not bool
                or not all(_candidate(row) for row in rows)):
            return 'diagnostic_candidates'
        if len({row['candidate_id'] for row in rows}) != len(rows) or len({row['absolute_rank'] for row in rows}) != len(rows):
            return 'diagnostic_candidates'
        if 'total_count' in value:
            total = value['total_count']
            if total < len(rows) or any(row['absolute_rank'] >= total for row in rows) or (not value['truncated'] and total > len(rows)) or (value['coverage'] == 'complete_set' and total != len(rows)):
                return 'diagnostic_candidates'
        if value['coverage'] == 'complete_set' and value['truncated']:
            return 'diagnostic_candidates'
    elif {'total_count', 'observed_count', 'truncated', 'coverage'} & set(value):
        return 'diagnostic_candidates'
    return None


def _tag(s):
    return type(s) is str and 0 < len(s) <= 96 and all(33 <= ord(c) <= 126 for c in s)


def _number(n):
    return type(n) is int and 0 <= n <= MAX_INT


def _text(s):
    return _text_limit(s, 256)


def _text_limit(s, limit):
    if type(s) is not str:
        return False
    try:
        return len(s.encode('utf-8')) <= limit
    except UnicodeEncodeError:
        return False


def _candidate(c):
    return (type(c) is dict and {'candidate_id', 'text', 'absolute_rank', 'source'} <= set(c)
            and set(c) <= {'candidate_id', 'text', 'absolute_rank', 'source', 'reading'}
            and _tag(c['candidate_id']) and _text(c['text']) and _number(c['absolute_rank'])
            and type(c['source']) is str and c['source'] in SOURCES
            and ('reading' not in c or _text(c['reading'])))
