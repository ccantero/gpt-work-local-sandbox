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

The validated reference installation has these directories:

``` text
/home/local-gpt-work/git/gpt-work-local-sandbox
/home/local-gpt-work/repos
/home/local-gpt-work/workspaces
```

The first is the restricted runtime checkout of this infrastructure
repository. The repository is public: reviewed infrastructure changes follow
the normal human commit/push and restricted clone/pull path over public HTTPS.
The restricted account needs no GitHub token, SSH key, or human credentials for
this synchronization. This control-plane exception applies only to the
infrastructure repository; application repositories continue to use approved
archives and provenance.

`repos/` receives prepared application source/provenance and, in a future
workflow, returned review artifacts. `workspaces/` contains disposable
application workspaces initialized from those snapshots. On the reference host
both directories were created and verified as:

``` text
owner: local-gpt-work
group: local-gpt-work
mode:  0755
```

For a new host, an authorized human administrator may create those two exact
directories after the account exists, using the host's normal administrative
procedure, then verify them:

``` bash
stat -c '%U:%G %a %n' \
  /home/local-gpt-work/repos \
  /home/local-gpt-work/workspaces
```

Do not move them to `/srv`, add a shared group or ACL, or create another sudo
boundary for source transfer. `local-gpt-work` intentionally controls both
directories, including the ability to modify or remove its handoff artifacts.
Archive SHA-256/provenance checks remain useful for integrity and deterministic
pairing, but do not protect artifacts from their owner.

Because mode `0755` does not normally let the human operator write into a
directory owned by `local-gpt-work`, prepare source artifacts in a
human-writable staging location and use the already-authorized host procedure
to place copies in `repos/` with `local-gpt-work` ownership. This repository
does not define a new privilege mechanism for that transfer.

The human-side preparation command has been exercised on the real host with a
disposable Git repository. Its approved commit contained tracked `.gitignore`
and `hello.txt` plus an ignored, untracked `.env`. The resulting mode-`0444`
archive and provenance were created successfully; the archive contained the
two tracked files and contained neither `.env` nor upstream `.git`. Copies were
then placed in `repos/` with `local-gpt-work` ownership.

The complete Step 3 flow was subsequently validated on the real host. As the
restricted account, `initialize-work-workspace.sh` created a clean independent
repository with exactly one baseline commit, no remote, the approved upstream
commit in the baseline message, both tracked files present, and the ignored
`.env` absent. A simulated Work edit produced only the expected `hello.txt`
status and diff. Step 3 therefore has no pending real-host initialization check;
see `WORKFLOW.md` for the concise validation record.

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

Repository snapshots may contain production data and must never be
committed.

Create the directory as the human user:

``` bash
mkdir -p snapshots
chmod 0700 snapshots
```

Verify:

``` bash
stat -c '%U:%G %a %n' snapshots
```

Expected:

``` text
<your-human-user>:<your-human-group> 700 snapshots
```

`do_snapshot.sh` is designed to create custom-format dumps privately and
to refuse an unsafe existing snapshot directory rather than silently
repair it.

After creating or importing an approved dump:

``` bash
chmod 0600 snapshots/*.dump
find snapshots -maxdepth 1 -type f -name '*.dump' \
  -exec stat -c '%U:%G %a %n' {} \;
```

Never commit dumps. Treat every production-derived dump as sensitive.

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
ERROR: baseline refresh must run as the postgres OS user
Run the protected installed helper; never elevate the repository source.
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
ERROR: snapshot must be a regular, non-symlink file: /tmp/THIS-SNAPSHOT-DOES-NOT-EXIST.dump
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

Do this only when there is an approved dump that should actually become
the baseline.

Before starting:

``` bash
df -h /

sudo -u postgres psql -X -d postgres -Atqc "
SELECT datname,
       pg_get_userbyid(datdba),
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
```

The refresh helper performs its own capacity check. It requires
approximately the current baseline size plus a 25% safety margin before
creating the candidate.

Run only the protected installed helper:

``` bash
sudo -u postgres /usr/local/sbin/refresh-binancebot-baseline \
  /absolute/path/to/approved.dump
```

The workflow is intentionally staged:

1.  copy the supplied regular non-symlink dump into protected temporary
    storage;
2.  validate and hash that protected copy;
3.  require baseline and refuse ambiguous candidate/previous state;
4.  check free capacity;
5.  create a protected candidate;
6.  restore under `SET ROLE local-gpt-work` while ignoring archive
    owner/ACL;
7.  validate candidate object presence and ownership;
8.  revoke temporary create privileges;
9.  rename baseline → previous;
10. rename candidate → baseline;
11. validate the promoted baseline;
12. invoke the separately installed reset helper;
13. validate work;
14. remove previous only after success.

A failed or ambiguous refresh is **not** a reason to manually delete
candidate or previous. Preserve recovery state and investigate.

### Resume

`--resume` is narrowly defined. Use it only when restore completed, the
completed-restore marker exists, a later candidate-stage step failed,
and the database is still named candidate.

``` bash
sudo -u postgres /usr/local/sbin/refresh-binancebot-baseline \
  --resume /absolute/path/to/the-same-approved.dump
```

The dump must be byte-for-byte identical to the one used for the
completed restore.

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

Human administrator only:

``` bash
sudo -u postgres /usr/local/sbin/refresh-binancebot-baseline \
  /absolute/path/to/approved.dump
```

A successful refresh also resets work from the newly promoted baseline.

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
