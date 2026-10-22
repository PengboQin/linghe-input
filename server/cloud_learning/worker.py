"""One bounded learning tick, no plaintext output or automatic rescheduling."""
import argparse
import json
import os
from pathlib import Path
from .authority import LearningMembershipAuthority
from .service import LearningStore


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', required=True)
    parser.add_argument('--relay-database', required=True)
    parser.add_argument('--activity-database', default=os.environ.get('PRIVATE_INPUT_LEARNING_ACTIVITY_DATABASE'))
    parser.add_argument('--event-limit', type=int, default=1024)
    parser.add_argument('--group-limit', type=int, default=16)
    args = parser.parse_args(argv)
    database = Path(args.database).resolve()
    relay = Path(args.relay_database).resolve()
    archive = Path(args.activity_database).resolve() if args.activity_database else None
    if database in (relay, archive) or not database.is_file():
        parser.error('existing independent learning database required')
    store = LearningStore(database)
    try:
        result = store.worker_tick(LearningMembershipAuthority(relay, activity_database=archive), event_limit=args.event_limit, group_limit=args.group_limit)
        print(json.dumps(result, sort_keys=True))
    finally:
        store.close()


if __name__ == '__main__':
    main()
