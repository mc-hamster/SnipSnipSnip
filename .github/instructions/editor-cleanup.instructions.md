---
description: "Use when refactoring editor, renderer, annotation, canvas, or selection code in SnipSnipSnip/Editor. Covers behavior-preserving cleanup, renderer deduplication, and command-safe editor changes."
applyTo: "SnipSnipSnip/Editor/**/*.swift"
---

# Editor Cleanup Instructions

- Preserve the non-destructive annotation model. Do not flatten annotations into the base image outside copy/export paths.
- Keep interaction, model, controller, and renderer logic separate. If one file starts mixing those roles, extract a helper or collaborator.
- Prefer helper extraction over repeating large `switch` statements across annotation operations such as translate, scale, resize, text updates, or rendering.
- Avoid maintaining separate display and export implementations when shared geometry, style, or path helpers can express the same behavior.
- Keep undoable mutations routed through command types rather than ad hoc canvas or view state mutation.
- When touching selection, grouping, alignment, or crop logic, add or update targeted editor tests before broad refactors.