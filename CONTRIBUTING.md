# Contributing

This repo is a grab-bag of small, self-contained operational scripts for the
Twingate Solutions Engineering team. A few conventions keep it navigable as it
grows.

## Adding a new script

1. **Give it its own top-level folder** with its own `README.md`. Don't add
   loose scripts to an unrelated existing folder.
2. **Add a row to the root [`README.md`](README.md) index table** — folder,
   one-line purpose, platform, language.
3. **Never commit secrets.** Twingate API tokens, service keys, etc. are
   passed at runtime (arguments, environment variables, or a gitignored local
   file) — never hardcoded or committed.

## Two tiers of README

- **Substantial projects** (e.g. `powershell-scripts/autopilot-scripting/`,
  `twingate-headless-client-gateway/`) get a full README: parameter tables,
  a testing/validation section, and a troubleshooting section.
- **Small, single-file utilities** stay concise: purpose, prerequisites,
  usage, one worked example. Don't pad these out with sections they don't
  need.

## README template

Copy this for a new small-to-medium script folder and expand as needed:

````markdown
# Script Title

One-line purpose statement.

## Prerequisites

What needs to be installed/available before running this (runtime, packages,
API tokens/permissions).

## Usage

```
command --with-args <placeholders>
```

## Example

```
command --with-args a-real-looking-value
```

## Notes

Anything else worth knowing — caveats, what it doesn't do, platform limits.
````

## License

Apache 2.0 — see root [`LICENSE`](LICENSE).
