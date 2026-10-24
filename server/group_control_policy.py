"""Shared role decision only; no database, network, credentials or mutations."""
MOBILE=frozenset({'ios','android'})
DESKTOP=frozenset({'macos','windows'})

def management_kind_allowed(actor_kind,active_kinds):
    # Unknown members may be newly admitted phones. Their own authenticated
    # profile registration must finish before desktop control can be enabled.
    return actor_kind in MOBILE or (actor_kind in DESKTOP | {'root'} and
        all(kind in DESKTOP for kind in active_kinds))
