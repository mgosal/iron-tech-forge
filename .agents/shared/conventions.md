# Project Conventions

> **All agents must follow these conventions.** They apply to every file touched by the pipeline.

## Code Style

1. **Indentation:** Detect from existing files. Default to 2 spaces for JS/TS/YAML, 4 spaces for Python.
2. **Line length:** Max 100 characters where practical. Match the project's existing pattern.
3. **Trailing whitespace:** Never.
4. **Final newline:** Always end files with a single newline.
5. **Semicolons (JS/TS):** Match the project's existing convention.
6. **Quotes (JS/TS):** Match the project's existing convention (single vs double).

## Naming

1. **Variables/functions:** `camelCase` for JS/TS, `snake_case` for Python/Ruby/Rust.
2. **Classes/types:** `PascalCase` in all languages.
3. **Constants:** `UPPER_SNAKE_CASE`.
4. **Files:** Match existing naming pattern (kebab-case, camelCase, etc.).
5. **Test files:** Match existing pattern (`*.test.ts`, `*_test.go`, `test_*.py`, etc.).

## Error Handling

1. **Never swallow errors silently.** Always log or propagate.
2. **Use specific error types** when the language supports them.
3. **User-facing errors** must be helpful and not leak internals.
4. **Console.log for debugging** is never acceptable in production code.

## Imports

1. **Order:** stdlib → third-party → local. Match existing convention.
2. **No unused imports.**
3. **Prefer named imports** over default imports when both are available.

## Git

1. **Commit messages:** `type: description (#issue)` — conventional commits format.
2. **Types:** `fix`, `feat`, `test`, `docs`, `refactor`, `chore`.
3. **One logical change per commit.**

## Documentation

1. **Docstrings:** Required for public functions/methods in the project's standard format.
2. **Inline comments:** Only for non-obvious logic. Not for restating the code.
3. **README:** Do not modify unless the change requires it.
