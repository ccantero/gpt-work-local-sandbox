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
-   the earlier application source handoff passed real-host two-account
    validation. The current direct workspace preparation is covered by
    `tests/test-prepare-work-workspace.sh` and still needs live validation
    on a fresh host.

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

### Human checkout and Work directories

Run workspace preparation and the launcher from a human-controlled checkout.
Keep the application repository in human-controlled storage that the Work
account cannot access. Work receives only files from the approved commit in
its own independent workspace.

After the Work account exists, the authorized administrator creates
`/home/local-gpt-work/workspaces` if needed. It must be a real directory owned
by `local-gpt-work`. The operator also needs the existing authorization to
run workspace commands as that account. Check the directory before use:

```bash
stat -c '%F %U:%G %a %n' /home/local-gpt-work/workspaces
```

The reference directory mode is `0755`. Retain the human ownership and
access restrictions on the infrastructure and application checkouts. See
[WORKFLOW.md](WORKFLOW.md) for preparation and patch review.

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

Prepare an approved commit with `prepare-work-workspace.sh` and select its
independent workspace in ChatGPT Work. Follow [WORKFLOW.md](WORKFLOW.md) for
the exact preparation, launch and patch integration procedures.

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
-   [ ] `/home/local-gpt-work/workspaces` is
    `local-gpt-work:local-gpt-work` mode `0755`.
-   [ ] `/home/local-gpt-work/deliverables` is
    `local-gpt-work:local-gpt-work` mode `0755` (prepared on the reference host;
    use in a new E2E run remains unvalidated).
-   [ ] The human checkout is protected from Work and the human has the
    existing authorization needed to prepare an approved workspace.
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

## Persistent Work egress protection

`configure-work-ufw-policy.sh` is a root-managed UFW configuration helper. It
is not available to `local-gpt-work`, creates no sudo permission, and changes
neither PostgreSQL nor the reset policy. It resolves that account's UID when it
runs, then places a marked `work-uid-output` chain in UFW's `before.rules`.
That chain is called before UFW accepts `RELATED,ESTABLISHED` output, so the
specified destinations are rejected even if a Work-owned connection already
exists. The same controlled block can be placed in `before6.rules` only when
the administrator has approved IPv6 destinations and UFW IPv6 is enabled.

The following has **not** been validated by this repository: the host's active
UFW file shape, UFW/libvirt ordering, iptables-nft translation, live traffic,
or reboot persistence. Use a local console or another approved recovery path;
do not make the first reload over an unrecoverable remote-only session.

### Install after independent review

From the human-controlled checkout, first run the non-privileged fixture test:

```bash
tests/test-configure-work-ufw-policy.sh
```

As the human administrator, inspect the active policy and exact UFW hook
before changing anything. Stop if UFW is inactive, the shown `before.rules`
does not contain the expected `ufw-before-output` established rule, or local
libvirt policy is not understood:

```bash
sudo ufw status verbose
sudo iptables -V
sudo iptables -S ufw-before-output
sudo iptables -S | grep -E 'libvirt|ufw-' || true
sudo sed -n '/ufw-before-output/,+12p' /etc/ufw/before.rules
sudo sed -n '/ufw-before-output/,+12p' /etc/ufw/before6.rules
grep -Fx 'IPV6=yes' /etc/default/ufw || true
id -u local-gpt-work
```

Before installing, keep recoverable copies outside the Work account and copy
the reviewed helper to a protected path. The two SHA-256 values must match:

```bash
sudo cp -a /etc/ufw/before.rules /etc/ufw/before.rules.pre-gpt-work
sudo cp -a /etc/ufw/before6.rules /etc/ufw/before6.rules.pre-gpt-work
sudo install -o root -g root -m 0750 \
  ./configure-work-ufw-policy.sh /usr/local/sbin/configure-work-ufw-policy
sha256sum ./configure-work-ufw-policy.sh
sudo sha256sum /usr/local/sbin/configure-work-ufw-policy
sudo stat -c '%U:%G %a %n' /usr/local/sbin/configure-work-ufw-policy
```

Install approved addresses, replacing the placeholders with administrator-held
values. Do not use a production address merely as a connectivity-test target.
IPv6 arguments are optional; omit them until their production values are
approved and `IPV6=yes` is verified.

```bash
sudo /usr/local/sbin/configure-work-ufw-policy install \
  --ipv4 '<APPROVED_PRODUCTION_IPV4>' \
  --ipv6 '<APPROVED_PRODUCTION_IPV6>'
```

Repeated installation rebuilds only the managed block, deduplicates supplied
addresses, and reloads UFW. The helper requires root and the canonical
installed path. It serializes transactions with a lock in `/etc/ufw` and
leaves UFW activation to the administrator.
It rejects an unexpected, incomplete, duplicated, or incorrectly ordered
managed block rather than guessing. It first generates and validates both IPv4
and IPv6 candidate files, requiring the matching `iptables-restore --test`
utility before replacing either live file. Custom-chain
declarations are emitted in the *filter declaration section before any -A
rules. It verifies and preserves owner, group, mode, and modification time on
candidates and rollback copies; ACLs, extended attributes, and security labels
are not independently verified. It retains copies of both original files until
the reload succeeds. If either replacement or the first reload fails, it
restores both files by staging a verified same-directory copy and atomically
replacing each target; after a reload failure it also reloads that restored
configuration.

`HUP`, `INT`, or `TERM` during either file replacement triggers the same
persistent-file restoration. An interruption during restoration, the first
reload, or the rollback reload can leave the effective kernel state unknown, so
the helper retains and reports rollback-copy paths rather than guessing. The
same retention occurs when a file restoration or rollback reload fails. In
every such case, stop and use the recovery procedure below; do not retry
blindly.

### Executable non-production validation

Before inserting production addresses, use administrator-controlled,
non-production IPv4 and optional IPv6 endpoints. Install those test
destinations with the protected helper, then use a bounded request as the Work
user and a comparison request as the human user. The Work request must reject;
the comparison is governed by the existing UFW policy. Remove the test policy
with the documented rollback command before installing approved production
addresses. This procedure must never contact a production destination.

### Verify and validate

After installation, confirm the ordering and the exact numeric UID, then run
the non-production traffic test below before considering the production policy
accepted:

```bash
sudo iptables -S ufw-before-output
sudo iptables -S work-uid-output
sudo ip6tables -S work-uid-output
sudo ufw status numbered
```

| Check | Expected result | Status in this repository |
| --- | --- | --- |
| Fixture install/update/remove and injected validator/replacement/interruption/reload/restore failures | Candidates and restored files retain contents and selected metadata; unrecoverable fixture failures retain rollback artifacts | Verified by `tests/test-configure-work-ufw-policy.sh`; does not validate live kernel state |
| IPv4 non-production destination as `local-gpt-work` | Rejected | Human must perform with a controlled non-production endpoint |
| Same IPv4 as another local user | Existing UFW policy decides; UID rule does not match | Human must perform |
| Unlisted Internet destination as Work | Existing UFW policy decides; no broad deny added | Human must perform |
| Approved IPv6 destination as Work | Rejected when IPv6 policy was installed | Human must perform |
| Existing Work connection during installation | New packets to a listed destination reject because hook precedes established accept | Human must perform |
| libvirt guest/network traffic | Existing libvirt policy remains functional | Human must perform locally |
| Reboot | UFW reloads its persistent files and the `work-uid-output` chain/rules reappear | Human must perform from recoverable access |

For reboot validation, record `iptables -S work-uid-output` and the relevant
counter output before reboot, restart from console/recovery-capable access,
then repeat `ufw status verbose`, the chain inspection, and the controlled
non-production test. Do not remove the old temporary launcher protection as
part of this validation.

### Rollback and recovery

The normal rollback removes only the marked managed block and reloads UFW:

```bash
sudo /usr/local/sbin/configure-work-ufw-policy remove
sudo iptables -S work-uid-output
```

If the helper cannot safely remove an incomplete block, restore the pre-change
copies after inspecting their ownership and contents, then reload UFW:

```bash
sudo cp -a /etc/ufw/before.rules.pre-gpt-work /etc/ufw/before.rules
sudo cp -a /etc/ufw/before6.rules.pre-gpt-work /etc/ufw/before6.rules
sudo ufw reload
```

If a reload disrupts management access, use the host console or the approved
out-of-band recovery channel, restore those copies, and inspect UFW and
libvirt state before retrying. Do not disable UFW, flush firewall tables, add
sudo rights, or edit PostgreSQL as a recovery shortcut.
