"""Current self-hosted archive budgets; unrelated to keyboard learning capacity."""
import os

DEFAULT_DATABASE_BYTES = 16 * 1024 ** 3
MAX_DATABASE_BYTES = DEFAULT_DATABASE_BYTES
DEFAULT_GROUP_BYTES = 4 * 1024 ** 3
MAX_GROUP_BYTES = DEFAULT_GROUP_BYTES
MAX_LEDGER_BYTES = 1024 ** 3


def configured_database_bytes():
    value = int(os.environ.get('PRIVATE_INPUT_ACTIVITY_MAX_DATABASE_BYTES', str(DEFAULT_DATABASE_BYTES)))
    if not 16 * 1024 ** 2 <= value <= MAX_DATABASE_BYTES:
        raise ValueError('database capacity must be 16MiB..16GiB')
    return value
