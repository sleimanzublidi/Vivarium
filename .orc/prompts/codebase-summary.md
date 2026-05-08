Produce a concise codebase summary for downstream agents.

Work exclusively in the git worktree at `{{worktree_path}}`. Start by changing into that directory, and run all repository commands from there.

1. Read README.md and any repository guidance files that exist, such as AGENTS.md, CLAUDE.md, .github/copilot-instructions.md, CONTRIBUTING.md, and design/spec docs referenced by those files.
2. Identify and list the project's modules/packages/targets with a one-line purpose each.
3. Summarize the main features and commands currently available.
4. Build and test the project using the documented commands from the repository guidance — report pass/fail and any warnings.
5. Run `git log main..HEAD --oneline` — list recent branch changes.
6. List any known gaps, TODOs, or incomplete features you notice.

Output a single markdown document (do NOT save to disk).
