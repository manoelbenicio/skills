---
name: skill-catalog
description: Browse all available skills. Generates a browsable catalog FILE (artifact) instead of dumping into chat. Zero context window impact.
---

# Skill Catalog

## Purpose

Generate a **browsable catalog file** of all available skills. The catalog is saved as a markdown artifact that the user can open and scroll through — it does NOT go into the chat context window.

## Instructions

### For full catalog (default)

1. Call skills-consolidator/list_skills to get all skills.
2. **Create an artifact file** (NOT chat output) at the conversation artifact directory named skill_catalog.md.
3. Format the artifact with:
   - Summary header (total count, breakdown by source)
   - Skills grouped by detected category (common prefixes: git-*, po-*, python-*, etc.)
   - Table format: Skill Name | Description
4. **In the chat**, reply ONLY with: "Catalog generated with X skills. Open the artifact to browse." — nothing more.

### For filtered search

1. If the user provides a keyword, call skills-consolidator/search_skills with that keyword.
2. Since filtered results are small (max 50), display them directly in chat as a compact table.
3. Do NOT create an artifact for filtered results.

## Critical Rules

- **NEVER** dump the full skill list into chat. Always use an artifact file.
- **NEVER** read or display the full SKILL.md content of skills during catalog generation.
- Keep chat response under 3 lines for full catalog generation.
- Filtered searches (under 50 results) can go directly in chat.

## Example Invocations

- "use skill-catalog" -> generates artifact file, minimal chat output
- "skill-catalog python" -> shows python-related skills in chat (small result set)
- "skill-catalog bpo" -> shows BPO skills in chat (small result set)
