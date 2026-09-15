# Releases.md Maintenance Rule

## Mandatory Workflow Requirement
Whenever changes are made to the codebase (features, enhancements, bug fixes, UI adjustments, performance optimizations, or build system changes) and a Pull Request is prepared:
1. **Always maintain and update `Releases.md`**:
   - Record every notable user-facing change, bugfix, or performance optimization under the active / upcoming release header (e.g. `# 0.1.x`).
   - Group entries into standard categories (`Features & Enhancements`, `Bug Fixes & Improvements`, `Performance & Build System`).
   - Reference the affected module / page path in parentheses (e.g. `(`setup/esc_motors/esc_tools`)`).
   - Ensure the description is concise, accurate, and highlights the technical impact and issue/PR references where applicable.
2. **Include `Releases.md` in the PR**:
   - The updated `Releases.md` must be committed as part of the PR so release documentation stays in sync with master at all times.
