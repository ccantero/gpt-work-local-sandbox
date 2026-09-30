# Repository agent workflow

This file defines how agents work in this repository. See `README.md` for the
database architecture, security model, operating procedures, and recovery
guidance.

## Safety

- Treat `binancebot_work` as disposable and `binancebot_work_baseline` as
  protected.
- Do not access production credentials or production systems unless the human
  explicitly authorizes it.
- Do not use `sudo`, change system configuration, or execute
  `refresh_baseline.sh` unless the human explicitly authorizes it.
- Do not push Git changes unless the human explicitly authorizes it.
- Never weaken filesystem, PostgreSQL, or privilege boundaries to make a task
  easier.

## Git workflow

- Inspect the repository and current Git state before modifying files.
- Never commit unless the human explicitly authorizes the commit.
- For an authorized commit, stage only files relevant to the task and prefer one
  coherent commit for one coherent task.
- Never include temporary review or handoff artifacts in a commit.

## Mandatory handoff

At the end of every meaningful work session, generate or overwrite
`WORK_REPORT.md`. It must be self-contained and understandable without access to
the conversation. Include:

- the requested task;
- work performed;
- important decisions and assumptions;
- files changed;
- tests and checks executed, with results;
- the commit hash and message, if a commit was created;
- final Git status;
- unresolved issues or warnings; and
- the recommended next step.

If the session created a commit, generate or overwrite `WORK_CHANGES.patch`
with:

```bash
git format-patch -1 HEAD --stdout > WORK_CHANGES.patch
```

The patch must represent the commit created by the session. If no commit was
created, remove any stale `WORK_CHANGES.patch` so it cannot be mistaken for
current work.

`WORK_REPORT.md` and `WORK_CHANGES.patch` are ephemeral handoff artifacts. They
must remain ignored and must never be committed.
