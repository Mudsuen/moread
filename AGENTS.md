# moread

- Own the native macOS EPUB reader in this independent repository.
- Display name: `moread`. Preserve the `MudsReader` package/executable,
  `com.muds.reader` bundle identifier and existing application-support data.
- `ReaderCore` owns book parsing and reading state; `Sources/MudsReader` owns
  native windows, controls and rendering. Read the relevant tests before changing
  behavior. Use synthetic text and books for verification.
- Verify changes with `swift test`; package with `./scripts/package.sh`.
  Reuse the installed application's Apple signing identity and verify the
  candidate before installation. Keep one working recovery bundle.
- Source delivery follows the parent Code workspace rules. Public releases and
  distribution require an explicit request.
