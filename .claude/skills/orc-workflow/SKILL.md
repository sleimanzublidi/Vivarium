---
name: orc-workflow
description: Use when creating, generating, scaffolding, modifying, reviewing, or executing Orc workflow YAML files, or when the user asks to build or run an automation workflow for Orc
allowed_tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
---

# Orc Workflow

Create, modify, and review Orc workflow YAML files.

## Commands

This skill supports four commands. Parse the first argument after `/orc-workflow`:

| Command | Usage | Description |
|---------|-------|-------------|
| `create` | `/orc-workflow create` | Create a new workflow |
| `update` | `/orc-workflow update [name]` | Modify an existing workflow |
| `review` | `/orc-workflow review [name]` | Lint, review, and summarize a workflow |
| `execute` | `/orc-workflow execute [name]` | Start, monitor, diagnose, and report on a workflow run |

If the command is missing or unrecognized, ask the user which command they want.

### Workflow Selection (for `update`, `review`, and `execute`)

If a workflow name is provided, find it in `.orc/workflows/`. If not provided:

1. List all `.yaml` files in `.orc/workflows/`.
2. Present a numbered list and ask the user to select one.

## File Access Restriction

When creating or modifying workflows, **ONLY** read files from:
1. This skill's directory (e.g., `schema.md`)
2. The `.orc/` folder at the root of the repository

Do **NOT** read any other files in the codebase. All information needed to generate valid workflows is contained in the schema reference and existing workflow files in `.orc/`.

## Schema Reference

**ALWAYS** read `schema.md` from this skill's directory before generating or modifying any workflow. It contains the complete YAML schema — all fields, types, defaults, validation rules, template syntax, expression syntax, and providers.

## Command: `create`

When the user asks to create a new workflow:

1. **Parse the request** to identify: nodes (steps), agents (`claude-code`, `shell`, or custom), dependencies between nodes, inputs/outputs, and any advanced features (loops, conditionals, retries, interactive prompts).

2. **If the request is clear**, generate the full YAML directly. Do not ask unnecessary questions. Most workflows are straightforward — a few nodes with obvious ordering.

3. **If the request is ambiguous**, ask targeted clarifying questions — one at a time, multiple choice preferred. Common ambiguities:
   - Which agent to use for a step (shell vs claude-code)
   - Dependency ordering when steps could run in parallel or sequentially
   - Whether an input should be required or optional
   - Whether a loop/retry is needed

4. **Write the file** to `.orc/workflows/<name>.yaml`. Use kebab-case for the filename (e.g., `review-pr.yaml`).

5. **Add a comment header** at the top of the file matching this template:
   ```yaml
   # <Short description of what the workflow does>.
   #
   # Usage:
   #   orc start <name>
   #   orc start <name> --input <key>="<value>"
   #   orc start <name> "<positional input value>"
   ```
   Include all meaningful input variations. Match the style of the examples below.

6. **Validate** by running `orc validate .orc/workflows/<name>.yaml`. If validation fails, fix the issue and re-validate until it passes.

## Command: `update`

When the user asks to modify an existing workflow:

1. **Select the workflow** (see Workflow Selection above).
2. **Read the existing workflow file** in full.
3. **Apply the requested change** — add/remove/modify nodes, change dependencies, add/remove inputs, update prompts, adjust loop/retry/when config, etc.
4. **Preserve the comment header** — update usage examples if inputs changed.
5. **Write the updated file**.
6. **Validate** by running `orc validate <path>`. Fix and re-validate on failure.

## Command: `review`

Review a workflow for correctness, consistency, and quality.

1. **Select the workflow** (see Workflow Selection above).

2. **Read the workflow file** in full. Identify any nested workflows (nodes with `workflow:` field) and read those too. The review applies to the entire workflow tree.

3. **Lint** — run `orc validate <path>` on the selected workflow and every nested workflow. If validation fails, report the errors and propose fixes. Do not continue to the review phase until all workflows pass validation.

4. **Review for inconsistencies** — check each workflow in the tree for:
   - **Path consistency**: are file read/write paths using the same base (`{{orc_root}}`, `{{workspace}}`, etc.) throughout? Mixing bases for the same data is a bug.
   - **Template variable resolution**: do all `{{variables}}` in prompts resolve to declared inputs, upstream node outputs, or builtins? Watch for typos and stale references.
   - **Dependency correctness**: does `depends_on` match actual data flow? A node using `{{foo}}` must depend on the node that produces `foo`.
   - **Output mapping**: does the top-level `output:` map reference variables that actually exist?
   - **Nested workflow interface**: do `inputs:` passed to nested workflows match what the child actually uses? Are any pass-throughs redundant (e.g., passing builtins that are already available)?
   - **Prompt quality**: are agent prompts clear about what to do, what files to read, and what format to output? Are there contradictory instructions?
   - **When guards**: do conditional expressions reference valid statuses/outputs? Could a guard prevent a node from ever running?

   If issues are found, report each one with its location and propose a fix. Ask the user if they want to apply the fixes.

5. **Summary** — when no issues remain (or after fixes are applied), report:

   ```
   ## <Workflow Name>

   **Description:** <what the workflow does in 1-2 sentences>

   **DAG:**
   <ASCII diagram showing node execution order, parallelism, and conditionals>

   **Inputs:**
   - `<name>` (<type>, required/optional) — <purpose>
   (or "None" if no inputs)

   **Outputs:**
   - `<key>` — <what it contains>
   (or "None" if no output mapping)

   **Nested Workflows:**
   - `<node-id>` → `<workflow file>` — <what it does>
   (or "None")
   ```

   Repeat the summary block for each nested workflow in the tree.

6. **Optimizations** — after the summary, propose improvements if any are warranted. Categories:
   - **Parallelism**: nodes that could run concurrently but are unnecessarily serialized
   - **Prompt efficiency**: prompts that are too verbose, duplicate information already in context, or could benefit from passing upstream output directly
   - **Missing guards**: nodes that should have `when:` or `on_failure:` to handle edge cases
   - **Missing outputs**: useful node results that aren't surfaced in the output mapping

   If nothing to propose, say "No optimizations suggested." Do not invent improvements for the sake of it.

## Command: `execute`

Start a workflow, monitor it continuously, diagnose problems, and report results.

### Execution Phases

#### Phase 1: Start

1. Run `orc start <name>` (include any `--input key=value` args the user provided).
2. If it fails with "already running", ask the user whether to cancel the existing run and retry.
3. Capture the run ID from `orc list --status running` (most recent entry).

#### Phase 2: Monitor

Poll `orc status <run-id>` every **60 seconds**. After each check, report a single line:

```
**[Check N]** <node-name> is <doing-what> — <brief context if available>.
```

To determine what a node is doing:
- If a node just transitioned to `running`, note what it is (e.g., "ideation agent started", "building/testing").
- If a node has been running for multiple checks, verify the agent process is alive: `ps aux | grep "claude -p" | grep -v grep`. Report CPU time progression to confirm it's not stuck.
- If new nodes appeared since last check, report the transition (e.g., "`review` completed, `implement` now running").
- Check `git status --short` and `git log --oneline -3` periodically to observe implementation progress (new/modified files, new commits).

#### Phase 3: Diagnose

A node is **potentially stuck** if:
- It has been `running` for more than 15 minutes AND
- Its agent process CPU time has not increased between two consecutive checks AND
- No new file changes appear in `git status`

If stuck:
1. Report the finding to the user with evidence (CPU time, duration, file state).
2. Ask whether to: (a) wait longer, (b) cancel and restart the workflow, or (c) cancel and abort.

A workflow has **failed** if:
- `orc status` shows status `failed` or any node shows `failed` status.

If failed:
1. Run `orc logs <run-id> --node <failed-node>` to get error details.
2. Report the error with context.
3. Ask the user whether to: (a) fix the issue and `orc resume <run-id>`, (b) cancel and restart, or (c) abort.

#### Phase 4: Report

When `orc status` shows the run as `completed`:

1. Run `orc status <run-id>` one final time to capture the full output.
2. Present a structured summary:

```
## Workflow Run Summary (<run-id>)

**Workflow:** <name>
**Duration:** <start-to-end time>
**Status:** Completed

### Node Timeline
| Node | Duration | Status |
|------|----------|--------|
| <id> | <Xm Ys>  | completed |

### What Was Accomplished
<Parse the run output and summarize what happened at each stage>

### Artifacts
<List any files created/modified — from git status or run output>

### Caveats
<Any warnings, skipped steps, or issues noted during execution>
```

3. If the workflow produced uncommitted changes, note them and ask if the user wants to build/test/commit.

### Error Recovery

If `orc start` fails for any reason other than "already running":
1. Read the error message.
2. Check if it's a fixable issue (e.g., missing `.orc/` directory — run `orc init`; missing workflow file — list available workflows).
3. If fixable, fix it and retry. If not, report the error and stop.

## Generation Guidelines

- Use `output` aliases on nodes to create clean variable names (e.g., `output: summary` instead of referencing `{{summarize.output}}`).
- Use `| default:` for optional inputs so workflows work without arguments.
- Prefer `claude-code` for tasks requiring reasoning, analysis, or code generation. Use `shell` for deterministic commands (echo, file operations, scripts).
- Set `depends_on` only when a node actually needs another node's output or must run after it. Nodes without dependencies run in parallel automatically.
- Use `when:` guards for conditional branching — not for sequencing (that's what `depends_on` is for).
- Use `on_failure: continue` when downstream nodes should still run despite a failure. Use `on_failure: skip` when the node is optional.
- Keep prompts focused. For `claude-code` nodes, be explicit about what files to read/not read.
- Use `parameters:` on `claude-code` nodes to pass provider-specific config. Use `permission_mode: dontAsk` when the agent needs to run shell commands autonomously. Use `bare: "true"` for minimal mode (requires `ANTHROPIC_API_KEY` in `.orc/.env`). Avoid `bypassPermissions` unless the workflow is fully trusted.

## Examples

### Simple Single-Node

```yaml
# Greet using shell.
#
# Usage:
#   orc start greet
#   orc start greet --input name="Alice"
name: greet
description: Prints a personalized greeting.

input:
  - name: name
    type: string
    required: false

nodes:
  - id: greet
    agent: shell
    prompt: "echo 'Hello, {{name | default: World}}!'"
    output: message

output:
  greeting: "{{message}}"
```

### Multi-Node with Dependencies

```yaml
# Analyze a file: summarize, then suggest improvements.
#
# Usage:
#   orc start analyze --input file="src/main.swift"
name: analyze
description: Summarizes a file and suggests improvements.

input:
  - name: file
    type: file
    required: true

nodes:
  - id: summarize
    agent: claude-code
    prompt: "Read {{file}} and provide a brief summary."
    output: summary

  - id: improve
    agent: claude-code
    prompt: "Given this summary of {{file}}:\n\n{{summary}}\n\nSuggest concrete improvements."
    depends_on: summarize
    output: suggestions

output:
  summary: "{{summary}}"
  suggestions: "{{suggestions}}"
```

### Parameterized Nested Workflow

A parent workflow that calls a child workflow, overriding some inputs while letting others fall back to defaults. Config fields like `timeout_seconds` use template strings so the caller can control them.

**Child workflow** (`.orc/workflows/run-tests.yaml`):

```yaml
# Run tests with configurable timeout and retry.
#
# Usage:
#   orc start run-tests
#   orc start run-tests --input directory="Tests/Engine"
#   orc start run-tests --input timeout="600" --input retries="3"
name: run-tests
description: Runs tests in a directory with configurable timeout and retries.

input:
  - name: directory
    type: string
    default: "Tests/"
  - name: timeout
    type: string
    default: "300"
  - name: retries
    type: string
    default: "1"

nodes:
  - id: test
    agent: shell
    prompt: "cd {{repo_root}} && swift test --filter {{directory}}"
    timeout_seconds: "{{timeout}}"
    retry:
      max_attempts: "{{retries}}"
      delay_seconds: "5"
    output: test_result

output:
  result: "{{test_result}}"
```

**Parent workflow** calling the child with overrides:

```yaml
# Build and test with custom settings.
#
# Usage:
#   orc start build-and-test
name: build-and-test
description: Builds the project then runs tests with extended timeout.

input:
  - name: test_timeout
    type: string
    default: "600"

nodes:
  - id: build
    agent: shell
    prompt: "cd {{repo_root}} && swift build"
    output: build_result

  - id: test
    workflow: .orc/workflows/run-tests.yaml
    depends_on: build
    inputs:
      timeout: "{{test_timeout}}"
      retries: "3"
    # 'directory' not provided — child uses its default ("Tests/")
```

Key points:
- The child workflow defines `default` on all inputs, so the parent can omit `inputs:` entirely or provide only the overrides it cares about.
- Config fields like `timeout_seconds` and `retry.max_attempts` use `{{template}}` strings that resolve from the child's own inputs.
- The engine validates that all required inputs without defaults are provided by the caller.

### Advanced — Loop with Conditional

```yaml
# Iterative code review loop.
#
# Usage:
#   orc start review-loop --input file="src/module.swift"
name: review-loop
description: Reviews a file iteratively until all issues are resolved.

input:
  - name: file
    type: file
    required: true

nodes:
  - id: review
    agent: claude-code
    prompt: "Review {{file}} for bugs and style issues. List each issue on its own line. If no issues remain, say APPROVED."
    output: review_result
    loop:
      until: approved
      max_iterations: 5

  - id: fix
    agent: claude-code
    prompt: "Fix the issues found in {{file}}:\n\n{{review_result}}"
    depends_on: review
    when: "{{review.status}} == 'completed'"

output:
  review: "{{review_result}}"
```
