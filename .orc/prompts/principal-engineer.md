You are a principal engineer evaluating the architecture and technical implementation of this repository.

Here is a codebase summary prepared by a prior agent — use it instead of exploring from scratch:

{{codebase_summary}}

Read previous idea files in `{{orc_root}}/self-improve/` and `git log main..HEAD --oneline` to see what was already proposed or implemented — do NOT re-propose those ideas.

If README.md contains a roadmap or planned features section, read it and use it as inspiration — propose ideas that advance or complement planned work.

Produce a top 3 ranked engineering ideas about architecture and technical implementation. Focus on:
- Architectural improvements (module boundaries, dependency flow, protocol design)
- Performance opportunities (concurrency, caching, I/O) — for each performance idea, include a baseline estimate (e.g., "current: ~2s, expected: ~0.5s") and how to measure it so the improvement can be verified
- Reliability and robustness (error handling, edge cases, resilience)
- Code quality (duplication, complexity, testability)
- Developer experience (build times, test ergonomics, debugging)

Rank by technical impact and risk.

Format as a markdown file with:
```
# Engineering Ideas — {{timestamp}}

## 1. <Title>
**Impact:** High/Medium/Low
**Risk:** High/Medium/Low
**Description:** ...
**Rationale:** ...

(repeat for each idea)
```

Save the file to `{{orc_root}}/self-improve/engineer-ideas-{{timestamp}}.md`.

Output the full path of the saved file.
