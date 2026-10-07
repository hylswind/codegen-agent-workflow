# Agent interface

The workflow and `pipeline/run-pipeline.sh` never call an agent CLI directly. They call two
scripts under `agents/<name>/`. To add an agent, add a directory with these two scripts and
select it with the `agent` workflow input. Nothing else changes.

## `install.sh`

Installs the latest version of the agent CLI on the runner (Ubuntu, non-root user with sudo).
Idempotent. Makes the CLI available on `PATH` for later steps (append to `$GITHUB_PATH` when that
variable is set). Prints one line: `name=<agent> version=<version>`.

## `run.sh <prompt-file> <workdir> <out-dir> <edit|readonly>`

Runs one task to completion, unattended: no questions, no interactive permission prompts.

- The prompt is the content of `<prompt-file>`. Prompts are short and refer to files inside
  `<workdir>` (`SPEC.md`, `CONTRACT.md`, `REVIEW.md`, `.pipeline/gate-report/`).
- The agent's working directory is `<workdir>`. In `edit` mode it may create, change and delete
  files there and run shell commands. In `readonly` mode it must not change files; the pipeline
  uses this for the review stage and takes the review text from `result.txt`.
- Environment:
  - `AGENT_AUTH_TOKEN` (required): the credential from the repo secret.
  - `AGENT_MODEL`, `AGENT_MAX_TURNS`, `AGENT_MAX_BUDGET_USD` (optional).
  - `AGENT_SYSTEM_PROMPT_FILE` (optional): extra system-prompt text every stage should see.
- Writes into `<out-dir>`:
  - `result.json`: `{"agent","version","model","ok","turns","cost_usd","duration_s","exit_code"}`
  - `result.txt`: the agent's final message.
  - `transcript.json` or any other raw log the agent produces.
- Exit code 0 iff `ok` is true.

## Current agents

- `claude-code`: Claude Code via `claude -p`. `AGENT_AUTH_TOKEN` is the long-lived OAuth token
  printed by `claude setup-token` (Pro/Max/Team/Enterprise). An Anthropic API key also works.
