# SQLite amalgamation

This directory vendors the SQLite 3.53.3 amalgamation, downloaded on
2026-07-19 from
<https://www.sqlite.org/2026/sqlite-amalgamation-3530300.zip>.

- SQLite source ID: `2026-06-26 20:14:12 d4c0e51e4aeb96955b99185ab9cde75c339e2c29c3f3f12428d364a10d782c62`
- Archive SHA3-256: `d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9`
- `sqlite3.c` SHA3-256: `28e484abdaa43630e34040ef6ed92be973a1ad54107803d8af5145b889c23ed7`
- Compile flags: `SQLITE_THREADSAFE=1`, `SQLITE_OMIT_LOAD_EXTENSION`,
  `SQLITE_DEFAULT_MEMSTATUS=0`

SQLite is in the public domain. See <https://www.sqlite.org/copyright.html>.
The source is compiled into Nimbus so the control plane and all cross-built
artifacts do not depend on a system SQLite installation.

To update the vendored copy, download the official amalgamation archive,
verify the published SHA3-256 digest, replace `sqlite3.c` and `sqlite3.h`,
update the metadata above, and run `just ci`.
