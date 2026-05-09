Produce a concise codebase summary for downstream agents.

Work exclusively in the git worktree at `{{worktree_path}}`. Start by changing into that directory, and run all repository commands from there.

1. Read README.md and any repository guidance files that exist, such as AGENTS.md, CLAUDE.md, .github/copilot-instructions.md, CONTRIBUTING.md, and design/spec docs referenced by those files.
2. Identify and list the project's modules/packages/targets with a one-line purpose each.
3. Summarize the main features and commands currently available.
4. Build and test the project using the documented commands from the repository guidance — report pass/fail and any warnings.
5. Run `git log main..HEAD --oneline` — list recent branch changes.
6. Enumerate previously shipped self-improve work. These are independent branches that are NOT merged into `main`, so the code they introduced is *invisible in this worktree* even though those tasks have been completed.
   - Run: `git for-each-ref --sort=-committerdate refs/heads/self-improve --format='%(refname:short) %(committerdate:short) %(subject)' --count=30`
   - List the output verbatim under a section titled "Previously shipped on self-improve branches (not merged into main)".
   - Add a one-line note immediately after the list: downstream agents must treat each subject line as an already-completed task. Do NOT re-propose the same task. If a gap looks "missing" in this worktree but matches a subject above, it has already been addressed on its own branch — leave it alone for this run unless you can articulate, with a concrete and specific reason in the proposal, how this run would strictly improve on the prior approach.
7. List any known gaps, TODOs, or incomplete features you notice.

Output a single markdown document (do NOT save to disk).
