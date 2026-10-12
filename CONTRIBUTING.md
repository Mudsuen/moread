# Contributing to moread

Small, focused fixes and reproducible bug reports are welcome.

## Report a problem

Include your macOS version, hardware architecture, moread version or commit,
reading mode, and steps to reproduce. For layout or contrast issues, include
font size and relevant appearance settings. Redact personal material from
screenshots. Do not upload copyrighted EPUBs; use a short original or
public-domain reproduction when possible.

## Make a change

1. Fork the repository and create a focused branch.
2. Build with `swift build` and run `swift test` on macOS.
3. Add regression coverage for parsing, state, layout, or input behavior changes.
4. For UI changes, verify the real app with both reading modes and describe the
   manual checks in the pull request. Keep the current reading anchor intact.
5. Explain the problem, the resulting behavior, and any remaining limitations.

Keep source and contributor documentation in English. Preserve existing
Chinese interface copy unless the change specifically concerns localization.
Do not include local books, library state, signing credentials, build products,
or user-specific paths. Public changes must remain compatible with the MIT
license. Packaging uses each contributor's own local signing identity; CI does
not need signing credentials and must not request them from pull requests.
