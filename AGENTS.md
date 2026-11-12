# Repository agent workflow

See `README.md` for architecture, commands, boundaries, and E2E prerequisites.

## Safety

- Treat `binancebot_work` as disposable and its baseline as protected.
- Keep refresh and reset separate.
- Never elevate repository helper source.
- Never execute administrative helpers or change PostgreSQL, sudoers, firewall,
  permissions, installed files, or host configuration without explicit human
  authorization.
- Never access production systems, credentials, or dump contents without
  explicit authorization. Dumps remain human-controlled and outside Work.
- Work receives only exact no-argument execution of the installed reset helper.
- Preparation and launch scripts run only from a human-controlled checkout.
- `db_refresh`, its database backend, and its archive storage are human-only.
  Implement and test with synthetic data. Only an explicitly authorized
  human refresh may access the production service.
- Never weaken security boundaries or publish remotely without authorization.

## Four-script architecture

The primary scripts are:

1. `refresh_baseline.sh`: source for human-only protected refresh;
2. `reset-binancebot-work`: source for fixed protected Work reset;
3. `prepare-work-workspace.sh`: human-created workspace from approved commit;
4. `run-work.sh`: human-launched ChatGPT process as `local-gpt-work`.

Do not reintroduce repository dumps, repository-local snapshot acquisition, source archives,
provenance sidecars, separate initialization, inventories, or additional
installation frameworks without an approved design. The human preparation
entry point may acquire an explicitly requested snapshot and record its
checksum in private storage outside Git and Work.

## Documentation Maintenance Policy

The authoritative documentation is:

- `README.md`: architecture, objectives, security model, and accepted design
  decisions;
- `SETUP.md`: first-time Ubuntu installation/configuration, including
  prerequisites, commands, permissions, security controls, verification, and
  recovery;
- `WORKFLOW.md`: repeatable Work-task preparation, execution, testing,
  deliverables, review, integration, cleanup, maintenance, and recovery; and
- `AGENTS.md`: agent permissions, restrictions, collaboration rules, and this
  documentation policy.

`RUNBOOK.md` is planned for future consolidation into `WORKFLOW.md`; do not
perform that consolidation or delete documents without explicit authorization.

- Every implementation task must assess its impact on all four authoritative
  documents. Required documentation updates belong in the same reviewable
  change; a task is incomplete while they are missing or inconsistent. If none
  are required, say why in its implementation report.
- Update `SETUP.md` when installation steps, host configuration, dependencies,
  permissions, PostgreSQL setup, firewall rules, or security controls change.
  Update `WORKFLOW.md` when operational task procedures change. Update
  `README.md` when architecture, design decisions, or accepted risks change.
  Update `AGENTS.md` when agent permissions, security restrictions, or
  collaboration rules change.
- Document actual implemented behavior, not intentions presented as fact. Draft
  documentation during implementation if useful, but verify it against the
  tested implementation before completion. Clearly distinguish verified
  procedures from untested steps and from verification requiring a human
  administrator or a reboot.
- Avoid duplicating operational procedures across documents; link to the
  authoritative document instead. Do not silently overwrite, restore, rename,
  or delete documentation to meet this policy. Report missing or conflicting
  documentation and request authorization for structural changes.
- These requirements preserve existing security boundaries. They do not
  authorize privileged operations, host modifications, production access, or
  firewall changes.

## Git workflow

- Inspect Git state before editing and preserve unrelated changes.
- Stage only task files.
- Do not commit unless the task calls for it.
- Never push, publish, or create a pull request without explicit authorization.
- Approval applies only to the exact reviewed commit.

## Work artifacts

For substantive investigation or planning, create the corresponding ignored
`INVESTIGATION_WORK.md` or `PLANNING_WORK.md`.

Whenever repository files change, create ignored, self-contained:

- `IMPLEMENTATION_WORK.md`: task, implementation, decisions, files, tests,
  deviations, commit status, final Git status, warnings, next step.
- `REVIEW.md`: objective, scope, constraints, starting revision/branch,
  files, intended changes, tests, risks, deferred work, non-destructive
  verification, commit status, and expected reviewer outcome. It must direct
  reviewers to inspect the actual diff.

Never commit these artifacts. If a task creates a commit, generate ignored
`WORK_CHANGES.patch` from that exact commit. If no commit is created, remove
any stale patch.
