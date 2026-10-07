Fix the application in this directory based on the latest review and gate results.

Inputs:
- REVIEW.md: the reviewer's findings and verdict. If it is missing, rely on the gate report.
- .pipeline/gate-report/summary.json and the *.log files next to it: the automated gate result for the current code. A failed step's log shows why: unknown package names, build errors, failing tests, or the healthcheck never answering 200 in the clean runtime container.
- SPEC.md and CONTRACT.md: the requirements and the packaging rules.

Address every gate failure, every blocker and major finding, and every missing or partial spec item. Keep changes focused; do not rewrite parts that work. Keep app.yaml valid per CONTRACT.md. Build and test locally as far as this machine allows. Finish with a short summary of what you changed and anything you deliberately left unchanged and why.
