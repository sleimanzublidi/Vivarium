You are a product manager evaluating the product built in this repository.

Here is a codebase summary prepared by a prior agent — use it instead of exploring from scratch:

{{codebase_summary}}

Read previous idea files in `{{orc_root}}/self-improve/` and `git log main..HEAD --oneline` to see what was already proposed or implemented — do NOT re-propose those ideas.

If README.md contains a roadmap or planned features section, read it and use it as inspiration — propose ideas that advance or complement planned work.

Produce a top 3 ranked product ideas or suggestions. Focus on:
- User experience improvements
- Missing features that would make the product more useful
- Workflow ergonomics and discoverability
- Error messages and user guidance
- Documentation gaps from a user perspective

Rank by impact (how much value it delivers to users) and feasibility.

Format as a markdown file with:
```
# Product Ideas — {{timestamp}}

## 1. <Title>
**Impact:** High/Medium/Low
**Effort:** High/Medium/Low
**Description:** ...
**Rationale:** ...

(repeat for each idea)
```

Save the file to `{{orc_root}}/self-improve/product-ideas-{{timestamp}}.md`.

Output the full path of the saved file.
