#!/usr/bin/env python3
"""Classify explicitly labelled, bounded offline diagnostic replays.
Never reads NAS, changes learning, sends data, or guesses an intended phrase.
Published previews are not complete recall or proof of viewport exposure.
"""
import argparse, collections, json
from pathlib import Path


def classify(case):
    label=case.get('label',{})
    if label.get('source') not in ('synthetic','user_confirmed') or not isinstance(label.get('target_text'),str):
        return 'evidence_insufficient'
    if case.get('eligible_after_policy') is False:
        return 'excluded_by_policy'
    decision=case.get('decision',{})
    if not decision:
        return 'evidence_insufficient'
    if case.get('selection_policy')=='frozen_press_target' and case.get('press_candidate_id') and decision.get('selected_candidate_id') and case['press_candidate_id']!=decision['selected_candidate_id']:
        return 'selection_target_mismatch'
    observation=case.get('output',{})
    expected=case.get('expected_inserted_text')
    if observation.get('status')=='editor_acknowledged' and isinstance(expected,str) and isinstance(observation.get('text'),str) and observation['text']!=expected:
        return 'selection_output_mismatch'
    if decision.get('stage')=='commit' and observation.get('status')!='editor_acknowledged':
        return 'commit_unconfirmed'
    rows=decision.get('candidates',[])
    if not isinstance(rows,list) or len(rows)>5:
        raise ValueError('Only the bounded published snapshot is accepted')
    matches=[r for r in rows if r.get('text')==label['target_text'] and ('target_reading' not in label or r.get('reading')==label['target_reading'])]
    if matches:
        if case.get('visible_snapshot_complete') is True and isinstance(case.get('visible_candidate_ids'),list) and all(r.get('candidate_id') not in case['visible_candidate_ids'] for r in matches):
            return 'not_exposed_in_observed_viewport'
        return 'recalled_in_observed_snapshot'
    if decision.get('coverage')=='complete_set' and decision.get('truncated') is False and case.get('enumeration_complete') is True and isinstance(case.get('search_scope'),str) and case.get('eligible_after_policy') is True:
        return 'not_recalled_in_declared_scope'
    if decision.get('coverage') in ('published_subset','visible_subset'):
        return 'not_observed_in_bounded_snapshot'
    return 'evidence_insufficient'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture',type=Path)
    parser.add_argument('--result',type=Path)
    args=parser.parse_args()
    if args.fixture.stat().st_size>2*1024*1024:
        raise ValueError('Replay fixture exceeds bound')
    data=json.loads(args.fixture.read_text(encoding='utf-8'));cases=data['cases']
    if not isinstance(cases,list) or len(cases)>128:
        raise ValueError('Invalid replay case bound')
    outcomes=[]
    for case in cases:
        name=case['id']
        if not isinstance(name,str) or not name.isascii() or not name.isprintable() or len(name)>96:
            raise ValueError('Invalid replay identifier')
        actual=classify(case);outcomes.append({'id':name,'classification':actual,'expected':case.get('expected'),'passed':actual==case.get('expected')})
    result={'fixtureVersion':data['version'],'syntheticOnly':data.get('synthetic_only') is True,'cases':outcomes,'allPassed':all(r['passed'] for r in outcomes),'counts':dict(collections.Counter(r['classification'] for r in outcomes)),'liveAccuracyMeasured':False,'rawRecordsPrinted':False}
    if args.result:
        args.result.parent.mkdir(parents=True,exist_ok=True);args.result.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'cases':len(outcomes),'allPassed':result['allPassed'],'counts':result['counts'],'liveAccuracyMeasured':False}))
    return 0 if result['allPassed'] else 1

if __name__=='__main__':
    raise SystemExit(main())
