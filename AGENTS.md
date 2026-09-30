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

## Work artifacts

At the end of substantive work, generate or overwrite the artifact appropriate
to the work performed:

- Investigation, research, or substantial analysis: `INVESTIGATION_WORK.md`.
- Planning, design, or architecture: `PLANNING_WORK.md`.
- Implementation or repository modification: `IMPLEMENTATION_WORK.md`.

Multiple artifacts are appropriate only when a task genuinely contains multiple
substantive phases. Do not create separate investigation or planning artifacts
for routine analysis or planning performed as part of a normal implementation.
Every artifact must be self-contained and understandable without access to the
conversation.

`INVESTIGATION_WORK.md` must include:

- the question or problem investigated;
- relevant context;
- evidence inspected;
- findings;
- uncertainties and limitations;
- conclusions; and
- the recommended next step.

`PLANNING_WORK.md` must include:

- the objective;
- relevant current state;
- proposed approach;
- important design decisions;
- implementation steps;
- risks and failure modes;
- acceptance criteria; and
- unresolved questions.

`IMPLEMENTATION_WORK.md` must include:

- the requested task;
- implementation performed;
- important decisions and assumptions;
- files changed;
- tests and checks executed, with results;
- deviations from the plan, if any;
- the commit hash and message, if applicable;
- final Git status;
- unresolved issues or warnings; and
- the recommended next step.

If the task created a commit, additionally generate or overwrite
`WORK_CHANGES.patch` with:

```bash
git format-patch -1 HEAD --stdout > WORK_CHANGES.patch
```

The patch must represent the commit created during the current task. If no
commit was created during the current task, remove any stale
`WORK_CHANGES.patch` so it cannot be mistaken for current work.

`INVESTIGATION_WORK.md`, `PLANNING_WORK.md`, `IMPLEMENTATION_WORK.md`, and
`WORK_CHANGES.patch` are ephemeral handoff artifacts. They must remain ignored
and must never be committed.
