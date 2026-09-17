# Optional refilming reference

Normal retrieval and rendering use the archived assets and do not control the Mac. These helper sources and action plans are retained for future production work only.

`record-live.swift` records the main display's chosen logical rectangle with ScreenCaptureKit at 2× resolution, targeting 30 fps. It excludes only the filming-control software cursor windows, captures the real pointer, records no audio, and refuses to overwrite an existing take. Idle frames may arrive less frequently; the renderer normalizes the selected footage to constant 30 fps.

`film-control.swift` provides native pointer/keyboard and accessibility actions. It was used with explicit user permission. It checks approved application bundle IDs for targeted application actions and requires macOS accessibility/event-posting permission. Global clicks and keystrokes still affect the foreground screen: **do not run historical plans blindly.**

Build manually on macOS from the `filming/` directory:

```sh
mkdir -p bin
swiftc -parse-as-library record-live.swift -o bin/record-live
swiftc film-control.swift -o bin/film-control
bin/film-control status
```

Usage: `bin/record-live output.mov seconds x y width height`. Filming uses global display coordinates, not an app-relative canvas. The archived takes used a display at least 1512 × 904 logical points, with the app at (0, 34). Screenshot takes were commonly 1280 × 720; video takes 1280 × 870 or 1512 × 870.

The `plans/` files are historical production recipes, with original process IDs, exact document titles, and coordinates. They are not portable replay tests. Before reusing one, inspect the current UI, replace process IDs and titles, verify every coordinate and focus transition, prepare only fictional demo content, and save user documents. Original PID mapping: 21270 = SnipSnipSnip, 30005 = Preview, 21543 = TextEdit. Some setup steps were interactive and are not represented as a single complete unattended script. `record-final-actions.json` includes a final frame command whose generic window title did not match the resulting document; it must be updated for a fresh take.

The fictional screenshot fixture remains versioned at `../../../SnipSnipSnip v1.1.1/demo/orbit-before.png`. `Orbit Walkthrough.rtf` is the recording demo document in its final state; `prepare-final-record.json` removes the final sentence for another take. Never use the real clipboard history or unrelated user windows as demo material.

Maintain the repository's single-instance rules: inspect whether SnipSnipSnip is running, never launch a second instance, never bypass its lock, and never quit a user-owned copy without permission. Confirm the sandboxed App Store build and permission state before refilming. Review and crop new footage for privacy before adding it to this archive. The helpers do not modify app source.
