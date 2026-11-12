# SETUP --- Reproducible host setup for the GPT Work PostgreSQL sandbox

This runbook reproduces the local PostgreSQL sandbox described in
`README.md`.

Its purpose is operational: start from a new host, establish the
privilege boundary, install the reviewed helpers, and prove that the
boundary works.

The architecture is generic, but the checked-in privileged helpers are a
fixed-purpose reference implementation. Commands in this runbook therefore use
the validated installation names `local-gpt-work`, `binancebot_work`, and
`binancebot_work_baseline*`. Treat those values as implementation coupling to
adapt and review before deploying another application; never turn the reset
helper into a runtime-selectable database administration command.

`README.md` remains the architecture contract. `AGENTS.md` remains the
agent behavior contract. If this runbook conflicts with either one, stop
and resolve the discrepancy before continuing.

> **Important:** repository scripts are reviewable source, not
> privileged executables. Never run `refresh_baseline.sh` or
> `reset-binancebot-work` from the repository with `sudo` or as
> `postgres`. Privileged execution uses only separately reviewed copies
> installed under `/usr/local/sbin`.

------------------------------------------------------------------------

## Install the reviewed BinanceBot helpers

The human preparation command requires Ubuntu with Python 3.11 or newer,
PostgreSQL 17 server and clients, Bash, GNU coreutils, `flock` and the
existing reference accounts. Workspace and launch operations additionally
use Git, tar, X11, ChatGPT and the existing `iptables` policy.

`db_refresh` uses the reviewed helper versions below. Verify that the
existing human noninteractive authorization and the approved read-only
`vpsdatabase` login work in the intended detached session. See the
[database runbook](RUNBOOK.md#unattended-postgresql-dump-and-restore).

From the human-controlled checkout, run the tests in [README.md](README.md).
Review both helper diffs and preserve the currently installed versions in
administrator-controlled storage before replacing them. The human
administrator installs the reviewed sources and verifies the bytes:

```bash
sudo install -o root -g root -m 0755 ./reset-binancebot-work \
  /usr/local/sbin/reset-binancebot-work
sudo install -o root -g root -m 0755 ./refresh_baseline.sh \
  /usr/local/sbin/refresh-binancebot-baseline
sha256sum ./reset-binancebot-work /usr/local/sbin/reset-binancebot-work
sha256sum ./refresh_baseline.sh /usr/local/sbin/refresh-binancebot-baseline
```

Verify ownership, modes and ACLs on both installed files and their parent
directories. Work's only allowed sudo command remains the installed reset
helper as `postgres` with exact empty arguments. Keep the refresh helper
and other administrative commands restricted to the human operator.

The operator uses `sudo -n` for local catalog inspection as `postgres`,
verification as `local-gpt-work`, and the requested helper. Workspace
creation uses the existing human user-switch permission. The separate
graphical launcher uses the existing X11 and firewall permissions.
Validate the approved human database policy from the
intended unattended session. A terminal-bound authentication cache may not
carry into a detached command. Have the administrator review the exact
human-only operations if noninteractive authorization fails. The command
does not install sudo rules. Keep sudo input recording disabled for the
reviewed archive stream because it carries confidential data.

As the human operator, create the private snapshot store outside Git and Work:

```bash
mkdir -m 0700 "$HOME/binancebot-snapshots"
./prepare-codex-env --status
```

Provide the existing approved `vpsdatabase` libpq service and unattended
authentication in the human account for `--refresh`. Use the site's
approved credential store and verify the source identity out of band. The
database size query and dump require the role's existing read permissions.
Verify the live PostgreSQL connection policy, including peer access for Work
to `binancebot_work`, protection of the baseline, and restrictions on
connections to unrelated databases. The tool validates the four fixed names
and does not exercise unrelated databases. Capacity checks require the human
to be able to stat the PostgreSQL data directory and filesystem.

The disposable PostgreSQL fixture exercises the helper sources. Live sudo
authorization, host firewall state, GUI startup, and production service access
require separate human verification. During rollback, stop automated runs,
inspect the four fixed database names, and resolve any in-progress v2 refresh
before reinstalling older reviewed helper bytes.

## 1. Target architecture

The design deliberately separates two PostgreSQL databases and two
administrative operations.

  ----------------------------------------------------------------------------
  Resource                     Owner / actor           Purpose
  ---------------------------- ----------------------- -----------------------
  `binancebot_work_baseline`   `postgres`              Protected reference
                                                       database

  `binancebot_work`            `local-gpt-work`        Disposable development
                                                       database

  baseline refresh             human administrator     Replace baseline from
                                                       an approved dump

  work reset                   `local-gpt-work` via    Recreate only
                               narrow sudo rule        `binancebot_work` from
                                                       baseline
  ----------------------------------------------------------------------------

The development account must be able to destroy its work database
without gaining a path to modify, replace, rename, drop, refresh, or
connect to the baseline.

The only privileged operation exposed to `local-gpt-work` is:

``` bash
sudo -u postgres /usr/local/sbin/reset-binancebot-work
```

with **no arguments**.

Baseline refresh is human-only:

``` bash
sudo -u postgres /usr/local/sbin/refresh-binancebot-baseline \
  /absolute/path/to/approved.dump
```

This is a PostgreSQL/filesystem privilege boundary. It is not a
replacement for a VM or container when process-level isolation is
required.

------------------------------------------------------------------------

## 2. What was actually verified

The HUMAN HOST PROMOTION procedure in this document was exercised on the
reference notebook and reached the following accepted state:

-   PostgreSQL 17.10;
-   Unix socket `/var/run/postgresql`;
-   port `5432`;
-   `binancebot_work` owned by `local-gpt-work`;
-   `binancebot_work_baseline` owned by `postgres`;
-   both databases approximately 21 GiB at verification time;
-   `local-gpt-work` can connect to work;
-   `local-gpt-work` cannot connect to baseline;
-   `local-gpt-work` is not superuser and has no `CREATEDB`,
    `CREATEROLE`, `REPLICATION`, or `BYPASSRLS`;
-   no inherited PostgreSQL role memberships;
-   reset helper installed `root:root 0755`;
-   refresh helper installed `root:root 0755`;
-   sudo exposes only the exact no-argument reset as OS user `postgres`;
-   snapshot directory is `0700`;
-   snapshot dumps are `0600`;
-   the public infrastructure repository can be cloned and pulled over HTTPS
    by the restricted account without GitHub credentials; and
-   the complete application source handoff and isolated workspace
    initialization flow passed its real-host two-account validation.

The fresh-machine bootstrap below is intended to reproduce that state,
but was not itself executed end-to-end during the reference promotion.
Treat its checkpoints as mandatory.

------------------------------------------------------------------------

## 3. Host-specific values --- verify before copying commands

Do not assume the desktop matches the reference notebook.

Run:

``` bash
hostname
psql --version
sudo -u postgres psql -X -d postgres -Atqc \
  "SELECT version(); SHOW unix_socket_directories; SHOW port; SHOW data_directory;"
sudo --version | head -n 3
df -h /
```

The reviewed helper sources currently pin:

``` text
PostgreSQL major: 17
PG binaries:      /usr/lib/postgresql/17/bin
socket:           /var/run/postgresql
port:             5432
admin role:       postgres
```

If the new host differs, **do not edit the installed helper in place**.
Update and review repository source first, then install the reviewed
bytes.

The reference notebook uses `sudo-rs 0.2.8`. Its installed `sudoers(5)`
documentation confirms that `""` after a command means that the command
may only be invoked with no command-line arguments.

On another sudo implementation/version, verify the local documentation
before copying that syntax:

``` bash
man sudoers | grep -n -A15 -B10 'command line arguments' | head -n 60
```

------------------------------------------------------------------------

## 4. Create or verify the isolated OS account

The intended development OS account is:

``` text
local-gpt-work
```

If it does not exist, create it using the host's normal administrative
policy. Do not add it to `sudo`, `docker`, `adm`, `libvirt`, or other
privileged groups merely to make Work convenient.

Inspect:

``` bash
id local-gpt-work
getent passwd local-gpt-work
```

Also inspect the human home and sensitive paths. The development account
should not gain access to the human user's private files or credentials.

This project does not claim that Unix-user separation is equivalent to a
VM.

### Infrastructure checkout and application directories

The current reference installation has these directories:

``` text
/home/local-gpt-work/git/gpt-work-local-sandbox
/home/local-gpt-work/repos
/home/local-gpt-work/workspaces
/home/local-gpt-work/deliverables
```

The application handoff and workspace workflow has been validated using the
first three paths. The `deliverables/` path was prepared later and is addressed
separately below.

The first is the restricted runtime checkout of this infrastructure
repository. The repository is public: reviewed infrastructure changes follow
the normal human commit/push and restricted clone/pull path over public HTTPS.
The restricted account needs no GitHub token, SSH key, or human credentials for
this synchronization. This control-plane exception applies only to the
infrastructure repository; application repositories continue to use approved
archives and provenance.

`repos/` receives prepared application source/provenance. `workspaces/`
contains disposable application workspaces initialized from those snapshots.
`deliverables/` is the intended stable location for reports and patches kept
outside application repositories. On the reference host `repos/` and
`workspaces/` were created and verified as:

``` text
owner: local-gpt-work
group: local-gpt-work
mode:  0755
```

For a new host, an authorized human administrator may create those three exact
directories after the account exists, using the host's normal administrative
procedure, then verify them:

``` bash
stat -c '%U:%G %a %n' \
  /home/local-gpt-work/repos \
  /home/local-gpt-work/workspaces \
  /home/local-gpt-work/deliverables
```

Do not move them to `/srv`, add a shared group or ACL, or create another sudo
boundary for source transfer. `local-gpt-work` intentionally controls both
source and workspace directories and the deliverables directory, including the
ability to modify or remove artifacts in them.
Archive SHA-256/provenance checks remain useful for integrity and deterministic
pairing, but do not protect artifacts from their owner.

Because mode `0755` does not normally let the human operator write into a
directory owned by `local-gpt-work`, prepare source artifacts in a
human-writable staging location and use the already-authorized host procedure
to place copies in `repos/` with `local-gpt-work` ownership. This repository
does not define a new privilege mechanism for that transfer.

The complete source preparation and workspace initialization flow was validated
on the reference host. It produced a verified source snapshot and a clean,
independent one-commit workspace with no remote, containing only the approved
tracked source. Step 3 therefore has no pending real-host initialization check;
see `WORKFLOW.md` for the concise validation record.

The `deliverables/` directory was created later as
`local-gpt-work:local-gpt-work` mode `0755`. It was prepared after the
successful E2E validation, so its future use has not yet been validated by
another E2E run.

------------------------------------------------------------------------

## 5. Create or verify the PostgreSQL role

Inspect first:

``` bash
sudo -u postgres psql -X -d postgres -c '\du+ local-gpt-work'
```

The target role is a login role without administrative attributes.

For a fresh role, the intended shape is:

``` sql
CREATE ROLE "local-gpt-work"
  LOGIN
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION
  NOBYPASSRLS;
```

Apply PostgreSQL role changes only as an authorized human administrator.

Verify:

``` bash
sudo -u postgres psql -X -d postgres -Atqc "
SELECT rolname,
       rolsuper,
       rolcreatedb,
       rolcreaterole,
       rolreplication,
       rolbypassrls
FROM pg_roles
WHERE rolname='local-gpt-work';
"

sudo -u postgres psql -X -d postgres -Atqc "
SELECT r.rolname
FROM pg_auth_members m
JOIN pg_roles r ON r.oid=m.roleid
JOIN pg_roles u ON u.oid=m.member
WHERE u.rolname='local-gpt-work';
"
```

Expected privilege flags:

``` text
local-gpt-work|f|f|f|f|f
```

The membership query should return no inherited memberships unless the
architecture is deliberately revised.

------------------------------------------------------------------------

## 6. Bootstrap the database names on a new host

The protected refresh helper expects the baseline database name to
exist.

For a truly new host, create an initial protected baseline shell as
`postgres` before the first approved refresh:

``` bash
sudo -u postgres createdb \
  --owner=postgres \
  binancebot_work_baseline
```

Immediately protect it:

``` bash
sudo -u postgres psql -X -d postgres -v ON_ERROR_STOP=1 <<'SQL'
REVOKE CONNECT ON DATABASE binancebot_work_baseline FROM PUBLIC;
REVOKE CREATE ON DATABASE binancebot_work_baseline FROM PUBLIC;
SQL
```

Do **not** manually populate this shell from the repository. The
approved production-derived dump is promoted through the protected
refresh workflow.

Before the first real refresh, verify:

``` bash
sudo -u postgres psql -X -d postgres -Atqc "
SELECT datname, pg_get_userbyid(datdba)
FROM pg_database
WHERE datname IN (
  'binancebot_work',
  'binancebot_work_baseline',
  'binancebot_work_baseline_candidate',
  'binancebot_work_baseline_previous'
)
ORDER BY datname;
"
```

At initial bootstrap, baseline may be empty. Candidate and previous
should not already exist.

> If candidate or previous exists unexpectedly, stop. Do not delete
> ambiguous recovery state just to make the helper proceed.

------------------------------------------------------------------------

## 7. Prepare snapshots safely

Create the human-owned snapshot directory outside Git and Work with mode
`0700`. Keep approved archives mode `0600`. See the
[database runbook](RUNBOOK.md) for acquisition, verification, and reuse.

------------------------------------------------------------------------

## 8. Review helper source before installation

From the repository:

``` bash
git status --short
git log -1 --oneline

sha256sum \
  reset-binancebot-work \
  refresh_baseline.sh
```

Record the hashes you actually reviewed.

Hashes from the reference promotion were:

``` text
reset-binancebot-work
3d74dfc5f40b32e2d3c9ed0bdc8c4f3a042f8a8f2eae245fdfd5a96a834199a8

refresh_baseline.sh
6fece6ab25521b4ecbeb20a33a51f2207447f675bfecad61df72c7561d016b09
```

These hashes are historical evidence, **not permanent expected values**.
If the repository source changes intentionally, the correct hashes will
change too. Review the new source rather than forcing it to match this
document.

------------------------------------------------------------------------

## 9. Install and test the reset helper as a candidate

Install reviewed bytes without executing repository source with
privilege:

``` bash
sudo install -o root -g root -m 0755 \
  reset-binancebot-work \
  /usr/local/sbin/reset-binancebot-work.candidate
```

Verify:

``` bash
sha256sum reset-binancebot-work
sudo sha256sum /usr/local/sbin/reset-binancebot-work.candidate
sudo stat -c '%U:%G %a %n' \
  /usr/local/sbin/reset-binancebot-work.candidate
sudo getfacl -p /usr/local/sbin/reset-binancebot-work.candidate
```

The source and candidate hashes must match exactly. The candidate should
be `root:root 0755` with no extended ACL granting modification.

The reset helper accepts no arguments. A safe rejection test is:

``` bash
sudo -u postgres \
  /usr/local/sbin/reset-binancebot-work.candidate SHOULD-FAIL
```

Expected: a usage error. It must reject the argument before destructive
work.

### Controlled reset acceptance test

A real reset destroys `binancebot_work`. Perform this only when work is
disposable and baseline is known-good.

Check state and free space first:

``` bash
sudo -u postgres psql -X -d postgres -Atqc "
SELECT datname,
       pg_get_userbyid(datdba),
       pg_size_pretty(pg_database_size(datname))
FROM pg_database
WHERE datname IN ('binancebot_work','binancebot_work_baseline')
ORDER BY datname;
"

df -h /
```

Then:

``` bash
time sudo -u postgres \
  /usr/local/sbin/reset-binancebot-work.candidate
```

Verify afterward that work exists, is owned by `local-gpt-work`, and
baseline still exists and is owned by `postgres`.

On the reference notebook, a 21 GiB work database reset using PostgreSQL
`file_copy` took roughly two minutes. Do not treat that timing as a
guarantee.

------------------------------------------------------------------------

## 10. Promote the reset helper

After candidate acceptance:

``` bash
sudo install -o root -g root -m 0755 \
  /usr/local/sbin/reset-binancebot-work.candidate \
  /usr/local/sbin/reset-binancebot-work
```

Verify source/candidate/installed hashes and permissions:

``` bash
sudo sha256sum \
  /usr/local/sbin/reset-binancebot-work.candidate \
  /usr/local/sbin/reset-binancebot-work

sudo stat -c '%U:%G %a %n' \
  /usr/local/sbin/reset-binancebot-work.candidate \
  /usr/local/sbin/reset-binancebot-work

sudo getfacl -p /usr/local/sbin/reset-binancebot-work
```

------------------------------------------------------------------------

## 11. Configure the narrow sudo boundary

The intended rule gives `local-gpt-work` exactly one privileged
operation: execute the installed reset helper as OS user `postgres`,
with no arguments.

On the reference host using `sudo-rs 0.2.8`, the rule is:

``` sudoers
local-gpt-work ALL=(postgres) NOPASSWD: /usr/local/sbin/reset-binancebot-work ""
```

Store it in a dedicated file such as:

``` text
/etc/sudoers.d/local-gpt-work-db-reset
```

Use `visudo` and validate the complete configuration. When changing sudo
policy, keeping a separate authenticated root shell open during
validation is a reasonable recovery precaution.

After editing:

``` bash
sudo visudo -c
sudo -l -U local-gpt-work
```

The effective list must contain the reset and **must not** contain
refresh, `psql`, `createdb`, `dropdb`, a shell, an interpreter, an
editor, or other broad privilege.

### Prove that arguments are denied by sudo itself

``` bash
sudo -u local-gpt-work -H \
  sudo -n -u postgres \
  /usr/local/sbin/reset-binancebot-work SHOULD-BE-DENIED
```

Expected: sudo rejects the command.

On the reference `sudo-rs` host the rejection was:

``` text
sudo-rs: I'm sorry local-gpt-work. I'm afraid I can't do that
```

A `Usage:` message from the helper is **not sufficient** here: it means
sudo allowed the argument-bearing invocation and only the helper
rejected it.

This gives two independent barriers:

1.  sudo policy permits only zero arguments;
2.  the helper itself also rejects arguments.

------------------------------------------------------------------------

## 12. Install and test the refresh helper as a candidate

Install reviewed bytes:

``` bash
sudo install -o root -g root -m 0755 \
  refresh_baseline.sh \
  /usr/local/sbin/refresh-binancebot-baseline.candidate
```

Verify:

``` bash
sha256sum refresh_baseline.sh
sudo sha256sum \
  /usr/local/sbin/refresh-binancebot-baseline.candidate

sudo stat -c '%U:%G %a %n' \
  /usr/local/sbin/refresh-binancebot-baseline.candidate

sudo getfacl -p \
  /usr/local/sbin/refresh-binancebot-baseline.candidate
```

Safe identity rejection test:

``` bash
/usr/local/sbin/refresh-binancebot-baseline.candidate
```

Expected:

``` text
Run only the protected installed helper as the postgres OS user.
```

Safe argument validation test:

``` bash
sudo -u postgres \
  /usr/local/sbin/refresh-binancebot-baseline.candidate
```

Expected usage message.

Safe nonexistent-snapshot test:

``` bash
sudo -u postgres \
  /usr/local/sbin/refresh-binancebot-baseline.candidate \
  /tmp/THIS-SNAPSHOT-DOES-NOT-EXIST.dump
```

Expected:

``` text
Use a regular, non-symlink dump.
```

Do not perform a real baseline refresh merely to test installation.

------------------------------------------------------------------------

## 13. Promote the refresh helper

After the non-destructive candidate checks:

``` bash
sudo install -o root -g root -m 0755 \
  /usr/local/sbin/refresh-binancebot-baseline.candidate \
  /usr/local/sbin/refresh-binancebot-baseline
```

Verify:

``` bash
sudo sha256sum \
  /usr/local/sbin/refresh-binancebot-baseline.candidate \
  /usr/local/sbin/refresh-binancebot-baseline

sudo stat -c '%U:%G %a %n' \
  /usr/local/sbin/refresh-binancebot-baseline.candidate \
  /usr/local/sbin/refresh-binancebot-baseline

sudo getfacl -p /usr/local/sbin/refresh-binancebot-baseline

sudo -l -U local-gpt-work
sudo visudo -c
```

`local-gpt-work` must still have **no sudo authorization for refresh**.

------------------------------------------------------------------------

## 14. First real baseline refresh

Follow [the database runbook](RUNBOOK.md) after completing the reviewed helper
installation and verifying the human sudo policy. Stop Work and application
writers. The refresh tool reports the database state, estimates capacity, and
validates the promoted baseline and disposable Work database.

------------------------------------------------------------------------

## 15. Final acceptance test

This block does not run reset or refresh. The negative tests are
expected to fail.

``` bash
echo '=== 1. DATABASE STATE ==='
sudo -u postgres psql -X -d postgres -Atqc "
SELECT datname || '|' || pg_get_userbyid(datdba) || '|' ||
       pg_size_pretty(pg_database_size(datname))
FROM pg_database
WHERE datname IN (
  'binancebot_work',
  'binancebot_work_baseline',
  'binancebot_work_baseline_candidate',
  'binancebot_work_baseline_previous'
)
ORDER BY datname;
"

echo
echo '=== 2. WORK CAN CONNECT TO WORK ==='
sudo -u local-gpt-work -H \
  psql -X -h /var/run/postgresql -p 5432 \
  -d binancebot_work \
  -Atqc 'SELECT current_database(), current_user;'

echo
echo '=== 3. WORK MUST NOT CONNECT TO BASELINE ==='
sudo -u local-gpt-work -H \
  psql -X -h /var/run/postgresql -p 5432 \
  -d binancebot_work_baseline \
  -Atqc 'SELECT current_database(), current_user;' \
  && echo 'ERROR: WORK CONNECTED TO BASELINE' \
  || echo 'OK: baseline connection denied'

echo
echo '=== 4. WORK SUDO AUTHORITY ==='
sudo -l -U local-gpt-work

echo
echo '=== 5. RESET WITH ARGUMENT MUST BE DENIED BY SUDO ==='
sudo -u local-gpt-work -H \
  sudo -n -u postgres \
  /usr/local/sbin/reset-binancebot-work SHOULD-BE-DENIED \
  && echo 'ERROR: sudo accepted reset arguments' \
  || echo 'OK: reset arguments denied'

echo
echo '=== 6. INSTALLED HELPER HASHES ==='
sudo sha256sum \
  /usr/local/sbin/reset-binancebot-work \
  /usr/local/sbin/refresh-binancebot-baseline

echo
echo '=== 7. INSTALLED HELPER PERMISSIONS ==='
sudo stat -c '%U:%G %a %n' \
  /usr/local/sbin/reset-binancebot-work \
  /usr/local/sbin/refresh-binancebot-baseline

echo
echo '=== 8. SNAPSHOT PERMISSIONS ==='
stat -c '%U:%G %a %n' snapshots
find snapshots -maxdepth 1 -type f -name '*.dump' \
  -exec stat -c '%U:%G %a %n' {} \;

echo
echo '=== 9. SUDOERS VALIDATION ==='
sudo visudo -c
```

Acceptance criteria:

``` text
work owner                         local-gpt-work
baseline owner                     postgres
candidate                          absent in steady state
previous                           absent in steady state
Work -> work CONNECT               allowed
Work -> baseline CONNECT           denied
Work sudo                          reset only
reset arguments                    denied by sudo
refresh sudo for Work              absent
installed helpers                  root:root 0755
snapshot directory                 0700
snapshot dumps                     0600
sudoers                            valid
```

------------------------------------------------------------------------

## 16. Routine operation

### Application source, implementation, and integration

For each application task:

1.  The human selects an approved commit and runs `prepare-work-source.sh` to
    create a new archive and provenance pair in human-writable staging.
2.  Using the already-authorized host transfer procedure, place copies in
    `/home/local-gpt-work/repos` with restricted-account ownership.
3.  As `local-gpt-work`, run `initialize-work-workspace.sh` with that pair and
    a new path under `/home/local-gpt-work/workspaces`. Verify a clean
    one-commit repository with no remote.
4.  Launch ChatGPT Work and explicitly select that application workspace. Work
    may edit, test, and make local commits without GitHub credentials.
5.  Have Work write a self-contained implementation report and a patch covering
    the complete baseline-to-final-`HEAD` difference outside the application
    repository. Record the patch SHA-256. The intended future location is
    `/home/local-gpt-work/deliverables`; it is prepared but has not yet been
    exercised in an E2E run.
6.  Copy the deliverables to a human-owned review directory. The human verifies
    the SHA-256, runs `git apply --check` against the original repository,
    applies the patch, inspects the actual diff, and runs the relevant tests.
7.  If accepted, the human creates an independent commit in the original
    repository and alone decides whether to publish it.

Do not use Work's internal commit hashes in the human repository. Do not make
the Work workspace a shared repository, change its ownership, or add
`safe.directory`; the patch is the supported integration boundary. See
`WORKFLOW.md` for the validated workflow and detailed rationale.

### Launch ChatGPT Work

The human starts Work from a terminal in their existing graphical Linux
session; `local-gpt-work` does not need or use a separate graphical login.
Provide the production VPS IPv4 address at invocation time without storing it
in the repository:

``` bash
PROD_VPS_IP='<production-vps-ip>' \
  /home/local-gpt-work/git/gpt-work-local-sandbox/run-work.sh
```

The launcher temporarily grants X access to `local-gpt-work`, ensures the
owner-matched firewall reject rule exists, and switches users to start ChatGPT
with the restricted account's runtime and D-Bus paths. Its cleanup revokes X
access and removes the firewall rule only when that invocation added it.

Logging, sudo prompt handling, firewall lifecycle, and process shutdown
behavior remain known follow-up improvements. Do not redesign those behaviors
during routine setup or operation.

### Development

Work only against:

``` text
binancebot_work
```

### Reset disposable work

From the restricted account:

``` bash
sudo -u postgres /usr/local/sbin/reset-binancebot-work
```

This destroys and recreates work from baseline.

### Refresh baseline

Human administrator only. Follow [the database runbook](RUNBOOK.md).
A successful refresh also resets Work from the promoted baseline.

------------------------------------------------------------------------

## 17. Things not to do

Do not:

-   run repository helper source with `sudo`;
-   run repository helper source as OS user `postgres`;
-   give `local-gpt-work` `CREATEDB`, superuser, or broad PostgreSQL
    privileges;
-   allow `local-gpt-work` to connect to baseline;
-   add refresh to Work's sudoers policy;
-   authorize `psql`, `createdb`, `dropdb`, a shell, interpreter,
    editor, or wildcard command through Work sudoers;
-   omit the zero-argument restriction from the reset sudo rule;
-   make `/usr/local/sbin` or either installed helper writable by Work;
-   combine reset and refresh into one privileged command;
-   automatically delete candidate/previous after an ambiguous refresh
    failure;
-   commit production-derived dumps;
-   assume a PostgreSQL/sudo version from another machine matches this
    one;
-   treat object-count validation as application-level semantic
    validation.

------------------------------------------------------------------------

## 18. Cleanup after successful promotion

Once the definitive helpers have been verified and the host is accepted,
the `.candidate` installed files are no longer required.

Before removing them, confirm the definitive hashes one final time.
Then:

``` bash
sudo rm -- \
  /usr/local/sbin/reset-binancebot-work.candidate \
  /usr/local/sbin/refresh-binancebot-baseline.candidate
```

This cleanup is optional and should happen only after acceptance.

------------------------------------------------------------------------

## 19. Porting checklist for another machine

Before declaring another host equivalent to the reference notebook,
answer all of these with evidence:

-   [ ] PostgreSQL major/version checked.
-   [ ] Socket, port, and data directory checked.
-   [ ] Local sudo implementation/version checked.
-   [ ] `local-gpt-work` OS account exists and is not in privileged
    groups.
-   [ ] `/home/local-gpt-work/repos` is `local-gpt-work:local-gpt-work`
    mode `0755`.
-   [ ] `/home/local-gpt-work/workspaces` is
    `local-gpt-work:local-gpt-work` mode `0755`.
-   [ ] `/home/local-gpt-work/deliverables` is
    `local-gpt-work:local-gpt-work` mode `0755` (prepared on the reference host;
    use in a new E2E run remains unvalidated).
-   [ ] Public-HTTPS infrastructure Git distribution is distinct from
    application source handoff and requires no GitHub credentials.
-   [ ] PostgreSQL role has only intended attributes.
-   [ ] PostgreSQL role has no unintended memberships.
-   [ ] Baseline is owned/administered by `postgres`.
-   [ ] Work is owned by `local-gpt-work`.
-   [ ] Work can connect to work.
-   [ ] Work cannot connect to baseline.
-   [ ] Reviewed reset bytes match installed reset bytes.
-   [ ] Reviewed refresh bytes match installed refresh bytes.
-   [ ] Installed helpers and parent directories are protected from Work
    writes.
-   [ ] Sudo policy exposes only exact no-argument reset.
-   [ ] Argument-bearing reset is rejected by sudo itself.
-   [ ] Refresh is absent from Work sudo policy.
-   [ ] Snapshot directory/dumps have private permissions.
-   [ ] Candidate/previous state is understood before any refresh.
-   [ ] Final acceptance block passes.

When all boxes are supported by actual host output, the machine
reproduces the intended sandbox boundary.
