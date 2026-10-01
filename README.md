# GPT Work PostgreSQL sandbox

This repository contains reviewable source and operating guidance for a local
PostgreSQL development sandbox. Its central security property is that the
development database is disposable while its source baseline is protected from
the development account.

## Architecture contract

The two databases deliberately have different trust levels.

| Database | Owner | Contract |
| --- | --- | --- |
| `binancebot_work_baseline` | `postgres` | Protected reference database. `local-gpt-work` must not be able to connect, create in it, replace it, refresh it, rename it, drop it, or administer it. |
| `binancebot_work` | `local-gpt-work` | Disposable development database. `local-gpt-work` may freely use, modify, or destroy it. It can be recreated from the protected baseline. |

Baseline refresh may temporarily use
`binancebot_work_baseline_candidate` and
`binancebot_work_baseline_previous`. Both are protected databases owned and
administered by `postgres`; they are not additional development databases.

The two administrative operations are deliberately separate:

- **Baseline refresh** is an occasional operation initiated by `cristhian`.
  It replaces the protected baseline from an approved production-derived dump
  through the candidate/promotion workflow. `local-gpt-work` is not authorized
  to perform it.
- **Work reset** is a routine operation available to `local-gpt-work`. It drops
  and recreates only `binancebot_work` from the protected baseline.

These operations must never be combined. Access to work reset must expose no
path that can refresh, replace, drop, rename, or otherwise administer the
baseline.

## Source and installed commands

Repository files are editable source for review and testing. They are never the
privileged executables:

| Repository source | Protected installed command | Authorized actor |
| --- | --- | --- |
| `refresh_baseline.sh` | `/usr/local/sbin/refresh-binancebot-baseline` | `cristhian`, manually as the `postgres` OS user |
| `reset-binancebot-work` | `/usr/local/sbin/reset-binancebot-work` | `local-gpt-work`, exactly as the `postgres` OS user with no arguments |

Both installed files and every controlling parent directory must be protected
from modification by `local-gpt-work`. Editing repository source must never
implicitly update either installed command. A human separately reviews and
installs the desired bytes, then verifies ownership, mode, parent-directory
permissions, and source/installed SHA-256 digests.

The intended sudo boundary for the development account is only exact,
no-argument execution of `/usr/local/sbin/reset-binancebot-work` as the
`postgres` OS user. The local sudo implementation's syntax must enforce zero
arguments, and the helper independently rejects arguments. Do not grant
`local-gpt-work` access to refresh, PostgreSQL clients, a shell, an interpreter,
an editor, or an argument-bearing reset variant.

## Fixed endpoint and verified state

Administrative sources pin PostgreSQL 17 at socket `/var/run/postgresql`, port
`5432`, and database role `postgres`. They clear connection-related `PG*` state
so a caller cannot redirect privileged operations.

These host facts were human-verified for this project:

- PostgreSQL server version is 17.10;
- both databases use `pg_default` and are approximately 21 GB;
- work is owned by `local-gpt-work`, which has `CONNECT` and `CREATE` there;
- baseline is owned by `postgres`, and `local-gpt-work` has neither `CONNECT`
  nor `CREATE` there;
- `local-gpt-work` has `LOGIN`, but not `SUPERUSER`, `CREATEDB`, `CREATEROLE`,
  `REPLICATION`, or `BYPASSRLS`;
- `local-gpt-work` has no inherited role memberships; and
- no candidate or previous database was present when these facts were checked.

Baseline application objects are owned by `local-gpt-work`, allowing a
physical `file_copy` clone to remain usable by the application role. Database
ownership and access restrictions, not application-object ownership, protect
the baseline.

This is a PostgreSQL and filesystem boundary, not general operating-system
isolation. Use a VM or container when stronger process isolation is required.

## Routine development and work reset

Connect only to the disposable work database:

```bash
psql -h /var/run/postgresql -p 5432 -d binancebot_work
```

When a clean copy is needed, the intended installed invocation is:

```bash
sudo -u postgres /usr/local/sbin/reset-binancebot-work
```

The installed reset helper accepts no arguments and contains fixed database
names, endpoint, administrator, and owner. Before destructive work begins, it
uses that fixed endpoint and administrator identity to verify that baseline
exists; a failed check or missing baseline aborts without modifying work. It may
drop/recreate only work and reads baseline only as the fixed clone source. Reset
is destructive to work and may terminate work connections. It has no refresh
mode and no baseline mutation command.

## Dumps and snapshots

`do_snapshot.sh <postgres-service>` creates a timestamped custom-format dump in
`snapshots/`. It accepts a conservative service name, sets a private umask,
requires an existing snapshot directory to be owned by the current user with
mode `0700`, and creates new dumps as `0600` without overwriting a final path.
It deliberately refuses to repair an unsafe existing directory; a human must
inspect and correct existing permissions separately.

Dumps may contain production data. They must not be committed, and the
repository ignores `snapshots/` and common dump suffixes. Confirm that a dump
is approved and trusted before refresh; restoring it executes schema
definitions as the application role.

## Protected baseline refresh

Never run `refresh_baseline.sh` from the repository with privilege. After a
reviewed version has been deliberately installed, `cristhian` invokes only the
protected copy as the `postgres` OS user:

```bash
sudo -u postgres /usr/local/sbin/refresh-binancebot-baseline \
  /absolute/path/to/approved.dump
```

The installed refresh source does not call `sudo`, acquire credentials, or keep
sudo credentials alive. It rejects another OS identity, pins the local
endpoint, copies the regular non-symlink input once to a private temporary file,
and validates, hashes, and restores only that copy.

The refresh workflow preserves the candidate/promotion safety state machine:

1. validate and hash the protected dump copy;
2. require baseline and refuse to overwrite an existing candidate or previous;
3. check capacity, create an inaccessible candidate, and restore under
   `SET ROLE local-gpt-work` while ignoring archive owners and ACLs;
4. write the completed-restore digest marker, validate object ownership and
   presence, and remove temporary create privileges;
5. rename old baseline to previous and promote candidate;
6. validate promoted baseline, invoke the separately installed reset helper,
   and validate rebuilt work; and
7. remove previous only after every validation succeeds.

No application anchor tables are contractual yet. `bot.event_log`,
`bot.portfolio`, `bot.trades`, and `django.django_migrations` remain candidates
requiring a human decision. Current object-presence checks must not be
represented as stronger application-level validation.

### Resume and recovery

Resume applies only when restore completed, its marker was written, a later
candidate-stage step failed, and the database is still named candidate:

```bash
sudo -u postgres /usr/local/sbin/refresh-binancebot-baseline \
  --resume /absolute/path/to/the-same-approved.dump
```

Every invocation, including `--resume`, creates a new protected temporary copy
from the supplied original dump. Resume does not reuse protected temporary bytes
from the earlier execution. It is valid only if the supplied original is still
byte-for-byte identical to the dump used for the completed restore, as proven
by the new copy's SHA-256 matching the candidate marker. Do not resume a
failed/partial restore, use a changed or different dump, or resume after
promotion.

The helper refuses to overwrite candidate or previous state. A promotion
rename failure attempts to restore the old baseline name. Any failure after
promotion preserves previous; work may be absent because it is disposable and
reset is drop-then-create. Preserve ambiguous state and escalate rather than
deleting it.

## Human-only installation and configuration

Repository implementation does not change the host. An authorized human must:

1. review the exact refresh and reset source versions and record their SHA-256
   digests;
2. install them separately at the protected paths above without executing
   repository files with privilege;
3. compare installed digests with reviewed digests and verify `/usr/local`,
   `/usr/local/sbin`, and both files are not writable by `local-gpt-work`
   through owner, group, mode, or ACL;
4. configure and validate a sudoers rule permitting `local-gpt-work` only the
   exact no-argument reset invocation as `postgres`; and
5. use `sudo -l -U local-gpt-work` to confirm refresh and broader commands are
   absent before any destructive acceptance test.

Changing source later does not change or invalidate an intentionally installed
version. Installation is a separate reviewed human action.

## Read-only verification

As `local-gpt-work`, confirm the role and work connection, then baseline denial:

```bash
psql -h /var/run/postgresql -p 5432 -d binancebot_work -Atqc \
  "SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname=current_user;"
# expected: f|f|f|f|f

psql -h /var/run/postgresql -p 5432 -d binancebot_work -Atqc \
  'SELECT current_database(), current_user;'
# expected: binancebot_work|local-gpt-work

psql -h /var/run/postgresql -p 5432 -d binancebot_work_baseline -c 'SELECT 1;'
# expected: permission denied
```

An authorized administrator should also verify database ownership, effective
`CONNECT`/`CREATE`, role memberships, installed file/parent permissions,
installed digests, and exact sudo policy. Candidate and previous, when present,
must have the same protected access posture as baseline.

## Repository contents

- `refresh_baseline.sh`: source for protected baseline refresh.
- `reset-binancebot-work`: source for narrow work reset.
- `do_snapshot.sh`: private custom-format snapshot creation.
