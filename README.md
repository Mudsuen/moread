# MudsReader / 闲读

A local-first native macOS EPUB reader, built with Swift and AppKit. Requires macOS 14 or later. The packaged build targets Apple Silicon.

## Build and verify

```sh
swift test
./scripts/package.sh
.build/debug/MudsReader --verify-book /path/to/unpacked.epub
```

The package script creates an ad-hoc signed `build/MudsReader.app`. Open `Package.swift` in Xcode to develop. No third-party runtime dependencies or network services are used.

## Reading

- Import zipped EPUBs or Apple Books' unpacked EPUB directories through File > Import EPUB or File > Import from Apple Books.
- The native sidebar provides a book selector and searchable chapter list in EPUB spine order. EPUB 2 NCX and EPUB 3 navigation labels are supported.
- Command-Shift-M switches between the normal reader and a borderless, resizable, text-only window. Drag the text to move the small window; drag an edge to resize it.
- Left/Up/Page Up go to the previous page; Right/Down/Page Down/Space go to the next page. Shift-Space also goes back. At a chapter boundary, page commands move into the adjacent chapter.
- Mouse and trackpad scrolling remain continuous within each chapter.
- Command-[ and Command-] change chapters. Command-F searches chapter titles.
- Command-plus (or Command-equals) increases the active mode's font size by 1 point; Command-minus decreases it. Normal reading supports 14–32 points, stealth reading 8–20 points. The current text anchor is retained.
- Command-comma opens typography settings. Each reading mode has independent font size, typeface, line height and paragraph spacing. Normal mode additionally offers page margins. Light, dark and system themes cover the main UI.
- The small window additionally offers brightness, transparency, always-on-top, and a black-background/white-text preset. Settings live outside the text window, in the menu bar, context menu or separate settings panel.
- Escape hides the reader. Use the menu bar book icon or reopen the app to restore it. Command-Shift-M is an application shortcut, not a global shortcut.

## Storage and privacy

Imported books are copied to `~/Library/Application Support/MudsReader/Books/`. Original files and the Apple Books database are never edited. `library.json` stores the library, per-book chapter and UTF-16 text offset, and appearance preferences. Writes are atomic and scrolling saves after a short debounce. Window geometry and the selected mode use app preferences.

The reader renders text, not the original EPUB page design. Illustrations, publisher styles, PDF, annotations, DRM-protected books, and cloud sync are outside the current scope. No copyrighted test book is included in the source or application bundle.

## Verification

Nine automated tests cover spine/TOC order, Chinese text extraction, malformed XHTML recovery, zip/directory imports, path traversal and symlink rejection, failed-import cleanup, preference migration, atomic state round trips, native page movement, reflow, margins and the text-only view structure.

The owner's local Apple Books copy of 剑来 was used for full-book parsing: 1,248 spine entries, 1,247 nonempty text sections, and 13,042,720 Swift characters. Native UI checks cover chapter selection, normal/stealth switching, arrow paging, scrolling, small font settings, brightness, opacity and black/white settings. Reading progress is represented by chapter and source text position, with line-level rounding on reflow; the displayed whole-book percentage is chapter-weighted.

## Design direction

The main window retains native window controls, sidebar navigation and keyboard access. The small window intentionally removes all visible controls while keeping recovery through the menu bar and a separate settings panel. Native window guidance: https://developer.apple.com/design/human-interface-guidelines/windows
