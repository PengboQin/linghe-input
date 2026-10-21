# Disposable relay fixture

These are copies of the project's existing public relay implementation, pinned in SOURCE-SHA256.json. They are used only by `tools/windows_group_fixture_server.py`, without a listening socket and with a new SQLite database under `build/windows-activity/group-fixture`.

The real 32 MiB group quota and signed-message validation are retained. The wrapper adds a read-only fixture queue inspection operation; no production route or deployed server is changed. It requires an existing Python 3 interpreter with `cryptography`, and does not download dependencies or touch a configured relay origin.
