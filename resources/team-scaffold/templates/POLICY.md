# Session access policy — {{TEAM_NAME}}

**Scope:** this team / session only (live layer). Not standing OAuth or app grants.

## Active constraints

{{POLICY_FLAGS}}

## Custom note

{{POLICY_NOTE}}

## For workers

When you receive a job, respect **Session access policy** in the handoff block.
If a task requires something banned, stop and ask the human / conductor.

## For conductors

Inject session policy into every job. Prefer `pong job create` over ad-hoc paste.
