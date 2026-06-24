# Tools

Developer-only utilities that are not part of the SnipSnipSnip app target.

## Clean Sweep

`clean-sweep-snipsnipsnip.sh` resets local SnipSnipSnip state for permission
onboarding tests. It deletes app-owned preferences/support/cache/container
files and resets macOS privacy decisions with `tccutil`.

Dry-run first:

```sh
Tools/clean-sweep-snipsnipsnip.sh
```

The dry run ends with a safety summary and the exact `--apply` command to run.
It reports `SAFE app-scoped cleanup` unless the selected options include a
known broad system reset such as `--reset-background-items`.

Apply the cleanup:

```sh
Tools/clean-sweep-snipsnipsnip.sh --apply
```

Optional cleanup for a fuller local reset:

```sh
Tools/clean-sweep-snipsnipsnip.sh --apply --remove-apps --derived-data
```

`--reset-background-items` is intentionally opt-in because macOS only exposes a
broad `sfltool resetbtm` reset for background/login item state.
