# Mac Screenshot Tool – Codex Phase-by-Phase Implementation Spec

## Document Purpose
This document is written for Codex implementation. It is not a product brief. It is a build spec organized so Codex can execute one phase at a time without drifting into later-phase scope.

Use this document to:
- implement in strict phase order
- keep Phase 2 limited to the MVP
- know what files, interfaces, and tests belong in each phase
- avoid premature work on OCR, scrolling capture, plugins, or cloud features
- leave the codebase clean and shippable after every phase

---

# 1. Global Build Rules for Codex

## 1.1 Non-Negotiable Rules
- Implement phases in order.
- Do not pull later-phase features into earlier phases unless a specific interface is explicitly required.
- Keep the app compiling and runnable at the end of each phase.
- Prefer simple implementations that preserve future extension points over speculative abstractions.
- Keep capture, editor, rendering, persistence, workflow, and platform integrations separated.
- Do not flatten annotation layers into the screenshot bitmap internally.
- Treat exported files and editable documents as different outputs.
- Keep files and types focused. Extract helpers or small value types before a coordinator, renderer, or model becomes the default dumping ground.
- Avoid duplicated parallel implementations for the same behavior, especially in display/export rendering and repeated annotation shape transforms.
- Favor shared test utilities and targeted coverage before large behavior-preserving refactors.

## 1.2 Per-Phase Output Contract
For every phase, Codex should produce:
- working code
- file/module structure for that phase
- minimal UI needed for that phase
- tests appropriate to that phase
- comments or TODO markers naming deferred next-phase work
- no partial implementation of unrelated future features

## 1.3 Stop Conditions
At the end of each phase, Codex should stop after:
- acceptance criteria are met
- tests for that phase pass or are scaffolded appropriately
- build remains clean
- deferred items are documented

---

# 2. Product Definition

## 2.1 Goal
Build a free macOS screenshot tool with:
- fast capture
- true non-destructive layered annotation
- clipboard-first workflow
- strong macOS-native behavior
- architecture that can later support OCR and scrolling capture without major refactors

## 2.2 Product Principles
- Layer-based editing by default
- Fast path: capture → annotate → copy/export
- Minimal UI friction
- Native macOS feel
- Production-grade behavior on multi-monitor setups

## 2.3 MVP Definition
The MVP is complete in Phase 2 and must support:
- region, window, and fullscreen capture
- editor opened from capture preview
- layered rectangle, arrow, text, and one redaction tool
- move/resize/select/delete annotations
- undo/redo
- auto-copy and PNG export

---

# 3. Final Feature Inventory
(Full scope; not build order)

## 3.1 Capture
- Region, window, fullscreen capture
- Multi-display support
- Retina correctness
- Window shadow handling
- Pixel loupe
- Adjustable selection
- Repeat region
- Timed capture
- Aspect ratio presets

## 3.2 Annotation
- Shapes, arrows, lines, freehand
- Text
- Highlight, spotlight
- Blur, pixelation, redaction
- Step numbering, callouts
- Measurement, grid, guides

## 3.3 Editing
- Select, multi-select, move, resize
- Rotate, group, reorder
- Crop, resize canvas
- Undo/redo, snapping

## 3.4 Workflow
- Clipboard-first
- PNG/JPEG/PDF export
- Auto-save rules
- Sharing

## 3.5 Persistence
- Editable document format
- History + recovery

## 3.6 Advanced
- OCR
- Scrolling capture
- Plugins / cloud (future)

---

# 4. Core Architecture (Stable Across Phases)

- SwiftUI shell + AppKit canvas
- Scene graph (layer-based document)
- Command-based editing (undo/redo)
- Vector-first rendering
- Separate editable format vs export

---

# 5. Phase Execution Order

1. Phase 1 – Capture Core
2. Phase 2 – MVP Editor
3. Phase 3 – Editing Maturity
4. Phase 4 – Persistence + History
5. Phase 5 – Hardening + Power Features
6. Phase 6 – Advanced Features

---

# 6. Phase 1 – Foundations and Capture Core

## Build
- App shell
- Permissions (Screen Recording + Accessibility)
- Capture (region/window/fullscreen)
- Multi-display correctness
- Selection UX (drag, loupe, adjust)
- Preview overlay

## Acceptance
- User captures screenshot reliably
- Works across multiple monitors

---

# 7. Phase 2 – MVP (Ship)

## Build
- Editor window + canvas
- Scene graph (in-memory)
- Tools: rectangle, arrow, text, blur
- Select/move/resize/delete
- Undo/redo
- Clipboard + PNG export
- Basic crop

## Acceptance
- Capture → annotate → export works end-to-end
- Feels fast and stable

---

# 8. Phase 3 – Editing Maturity

## Build
- Multi-select, grouping
- Alignment + snapping
- More tools (ellipse, line, freehand, highlight, callouts)
- Style system
- Full redaction system

## Acceptance
- Competitive annotation capability

---

# 9. Phase 4 – Persistence + History

## Build
- Native .sshot format
- Save/reopen
- Autosave + crash recovery
- History panel
- Filename rules + export improvements

## Acceptance
- No data loss
- Reopen and edit past screenshots

---

# 10. Phase 5 – Hardening + Power Features

## Build
- Multi-monitor edge cases
- Performance optimizations (tile rendering, memory)
- Keyboard shortcuts
- Repeat capture
- Accessibility polish
- Distribution readiness

## Acceptance
- Production-ready reliability

---

# 11. Phase 6 – Advanced Features

## Build
- OCR (Vision)
- Searchable screenshots
- Scrolling capture
- Extensibility prep
- Sharing integrations

## Acceptance
- Clear differentiation vs competitors

---

# 12. Codex Prompt Pattern

Use per phase:

- Implement Phase N only
- Do not include later features
- Keep app runnable
- Add tests for this phase
- Output file structure
- End with next-phase dependencies

---

# 13. Success Criteria

## MVP
- Fast capture
- Layered annotation
- Immediate export

## Final Product
- Daily-use reliability
- Strong performance
- Differentiation via layers + speed

---

End of document.
