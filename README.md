# twlint

A **Tailwind v4 class linter** written in Zig. Detects duplicate classes, conflicting classes, unsorted classes, invalid class names, and auto-fixes v3→v4 migration renames.

## Features

- **Duplicate detection** — flags repeated classes (e.g. `px-4 px-4`)
- **Conflict detection** — flags mutually exclusive classes (e.g. `flex grid`)
- **Sort checking / auto-sort** — enforces a canonical class order, with optional `--fix`
- **Invalid class detection** — catches mistyped classes with Levenshtein-based typo suggestions
- **Tailwind v3→v4 rename auto-fix** — renames renamed utility classes using `--fix` (e.g. `shadow-sm` → `shadow-xs`, `gap-x-4` → `gap-x-4`)
- **Content probe optimization** — skips files that don't contain `class` or `className`
- **Incremental caching** — `.twlint_cache` stores file hashes so unchanged files are skipped on re-run
- **Built-in v4 registry** — includes the full Tailwind v4 utility set; no `tailwind.config.*` needed

## Usage

```sh
twlint [paths...]
```

Check specified files (or all supported files in the current directory) for lint violations.

```sh
twlint --fix [paths...]
```

Auto-fix violations (sorting, v3→v4 renames).

### Options

| Flag | Description |
|------|-------------|
| `--fix` | Automatically fix violations |
| `--no-cache` | Skip cache (re-check all files) |

## Build

Requires [Zig](https://ziglang.org/download/) (≥0.13.x).

```sh
zig build
```

The binary is placed at `zig-out/bin/twlint`.

### Test

```sh
zig build test
```

## Supported file types

Scans class attributes in: `.html`, `.js`, `.ts`, `.jsx`, `.tsx`, `.vue`, `.svelte`.

## How it works

1. Probes files for class-like content (`class=` / `className=`) — skips irrelevant files cheaply.
2. Parses class strings into individual tokens.
3. Resolves each token against the built-in Tailwind v4 registry (generated from the official v4 dataset).
4. Reports violations: duplicates, conflicts, unsorted order, invalid names.
5. When `--fix` is passed, rewrites sorted class strings with applied renames.
6. Maintains a content-addressable cache to skip unchanged files on subsequent runs.

## License

MIT
