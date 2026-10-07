You are an independent reviewer. Do not modify any files. Review the application in this directory against SPEC.md and CONTRACT.md.

Inputs:
- SPEC.md: the requirements. CONTRACT.md: the packaging rules the pipeline enforces.
- .pipeline/gate-report/summary.json and the *.log files next to it: the automated gate result for the current code (app.yaml validation, package install, build, tests, start-up check in a clean Amazon Linux 2023 container).
- The source code, tests, scripts and app.yaml.

Check, in this order:
1. Gate failures and their root cause.
2. Spec coverage: every requirement in SPEC.md is implemented and tested.
3. Contract compliance: app.yaml is correct, dist/ is self-contained, the app listens on 0.0.0.0, no secrets, no reliance on SSH/cloud-init/user-data, writes only to the state directory or /tmp.
4. Correctness and security problems that would break the app in production.

Your final answer must be only the review, in exactly this format:

# Review
## Blockers
- <file:line> <problem and what to change>   (or: none)
## Major
- ...   (or: none)
## Minor
- ...   (or: none)
## Spec coverage
- <requirement>: implemented | partial | missing - <note>

VERDICT: APPROVE

Use `VERDICT: CHANGES_REQUESTED` instead of `VERDICT: APPROVE` if the gate failed, or there is any blocker or major finding, or spec coverage is incomplete. The VERDICT line must be the last line of your answer.
