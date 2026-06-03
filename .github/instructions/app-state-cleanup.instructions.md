---
description: "Use when refactoring AppModel, capture orchestration, autosave, recovery, or document state code. Covers state grouping, narrow task ownership, and avoiding monolithic observable models."
applyTo: "SnipSnipSnip/App/**/*.swift, SnipSnipSnip/Capture/**/*.swift, SnipSnipSnip/Document/**/*.swift"
---

# App State Cleanup Instructions

- Keep app-level observable state cohesive. Group related preferences, persistence state, recovery state, and background tasks instead of growing one broad model.
- Prefer narrow helpers or coordinators for capture orchestration, document save/load, and autosave/autocopy flows when AppModel begins owning too many responsibilities.
- Preserve existing UI behavior while refactoring. Cleanup work should reorganize responsibilities, not change capture, recovery, or save semantics.
- Keep capture, document, and recovery boundaries explicit. Avoid pushing file I/O, screen-capture details, and UI presentation logic into the same method when a helper can own one concern.
- Add or update focused tests around state transitions and error paths before or alongside cross-cutting refactors.