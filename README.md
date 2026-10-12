# moread

A local-first native macOS EPUB reader, built with Swift and AppKit. Requires macOS 14 or later. The packaged build targets Apple Silicon.

## Build and verify

```sh
swift test
./scripts/package.sh
.build/debug/MudsReader --verify-book /path/to/unpacked.epub
```

The package script creates `build/moread.app`, signed with an existing Apple Development certificate. Set `CODE_SIGN_IDENTITY` to select a certificate explicitly. Ad-hoc signing is rejected because it binds the screen-capture grant to a changing code hash. The bundle identifier `com.muds.reader` and existing data directory remain unchanged across the rename. Open `Package.swift` in Xcode to develop. No third-party runtime dependencies or network services are used. Optional automatic text contrast uses Apple ScreenCaptureKit and requires macOS screen-recording permission.

## Reading

- Import zipped EPUBs or Apple Books' unpacked EPUB directories through File > Import EPUB or File > Import from Apple Books.
- The native sidebar provides a book selector and searchable chapter list in EPUB spine order. EPUB 2 NCX and EPUB 3 navigation labels are supported.
- Command-Shift-M switches between the normal reader and a borderless, resizable, text-only window. Drag the text to move the small window; drag an edge to resize it.
- Left/Up/Page Up go to the previous page; Right/Down/Page Down/Space go to the next page. Shift-Space also goes back. At a chapter boundary, page commands move into the adjacent chapter.
- Paged reading is the default, including migration from earlier versions. Pages use contiguous TextKit source ranges: no repeated lines, missing characters, or backfilling on short final pages. Arrow keys and wheel gestures turn pages. The scrolling mode keeps continuous mouse/trackpad scrolling within each chapter; Command-Shift-P or the toolbar icon switches modes.
- Command-[ and Command-] change chapters. Command-F searches chapter titles.
- Command-plus (or Command-equals) increases the active mode's font size by 1 point; Command-minus decreases it. Normal reading supports 14–32 points, stealth reading 8–20 points. The current text anchor is retained.
- Command-comma opens typography settings. Each reading mode has independent font size, typeface, line height and paragraph spacing. Normal mode additionally offers page margins. Light, dark and system themes cover the main UI.
- Appearance (system/light/dark) is independent from app-local brightness. Brightness dims the app content without changing macOS display settings or implicitly switching theme. Command-Option-Up/Down changes brightness in 5% steps.
- Background and text transparency are independent. Background transparency reaches 100% while text remains visible; Command-Option-Right increases background transparency by 5%, and Command-Option-Left decreases it. Those transparency shortcuts apply to the small window.
- Double-click the small reading window to visually hide its content; double-click again to restore it. This is temporary and does not change opacity settings or the reading position. Sampling and page-turn commands pause while visually hidden. The Dock/menu-bar reveal action also restores it.
- The small window supports always-on-top. Hover reveals three borderless, transparent circular buttons immediately outside the upper-left corner: contents, typography, and pinning. Each button diameter is 1.5 times the reading font size; the visible symbols sit about 2 points above the first visible text line, using the transparent top margin instead of adding its padding to the gap, and hides on pointer exit with a short gap-crossing grace period. The contents button (or Command-F) opens a searchable chapter panel without leaving stealth mode. A dedicated hit surface covers text, paragraph gaps, margins and the empty end of a page. Resize zones are 9 points along edges and 16 points at corners, with directional system frame-resize cursors on macOS 15+. Resizing keeps the exact current first source character; pagination splits at that anchor so preceding text is never pulled into the current page. The opposite edge stays fixed and minimum dimensions are enforced. At full transparency, the window uses a near-invisible hit surface only while hovered; it is fully clear at rest.
- The compact settings panel uses icon shortcuts for appearance, pagination and window mode, plus short Typography / Appearance / Small Window tabs, a neutral grayscale palette and a translucent pin glyph without a backplate. Font choices include rendered Chinese previews for Songti, system, Kaiti and monospaced faces. The main reader has a centered header and a collapsible library sidebar.
- Escape or Command-W hides the reader. A left click on the menu bar book icon or a Dock reopen brings the reader forward and briefly outlines it for location feedback; right click on the menu bar icon opens its menu. Holding Left and Right together toggles reader visibility through current key-state polling. Release both before triggering again. The reader briefly defers a single arrow to recognize the chord without turning a page. Native automation cannot synthesize this two-nonmodifier-key chord; physical keyboard verification remains outstanding. Command-Shift-M is an application shortcut, not a global shortcut.

## Storage and privacy

Imported books are copied to `~/Library/Application Support/MudsReader/Books/`. Original files and the Apple Books database are never edited. `library.json` stores the library, per-book chapter and UTF-16 text offset, and appearance preferences. Writes are atomic and scrolling saves after a short debounce. Window geometry and the selected mode use app preferences. Borderless-window restoration uses the forced-frame API so custom-resizable windows restore their saved dimensions as well as position.

The reader renders text, not the original EPUB page design. Illustrations, publisher styles, PDF, annotations, DRM-protected books, and cloud sync are outside the current scope. No copyrighted test book is included in the source or application bundle.

## Adaptive text contrast

When enabled and the translucent small window is visible, ScreenCaptureKit samples the region underneath it at up to five snapshots per second. The capture filter excludes this app, preventing feedback from the reader's own text. Only the window region on its current display is requested; pixels stay in memory and are neither saved nor uploaded. Audio is never requested. Sampling stops when the reader is hidden or visually hidden, normal mode is active, the background is opaque, or adaptive text is disabled.

Each visible glyph uses the median luminance of its background neighborhood, combined with background opacity, app brightness and text opacity. This prevents blank margins or isolated bright pixels from changing the entire page, and supports separate dark/light text over mixed backgrounds. A small contrast hysteresis reduces flicker near the crossover without delaying clear white/black changes. Capture continues in common run-loop modes during interaction; results from old window positions are discarded and resampled immediately. Invalid transparent images are rejected. Transient capture failures retain the last valid colors instead of resetting to the theme; missing permission or stopping adaptation restores theme colors. Failures remain visible in settings. The permission button invokes macOS's normal screen-access flow; it does not bypass TCC.

The appearance migration resets the legacy background-gray slider to full brightness because the control now represents app exposure. Existing theme, font choices, book positions and background opacity remain intact. Text opacity defaults to fully visible.

## Verification

Automated tests cover spine/TOC order, Chinese text extraction, malformed XHTML recovery, zip/directory imports, path traversal and symlink rejection, failed-import cleanup, preference migration, atomic state round trips, native page movement, reflow, margins the text-only view structure, disjoint/lossless pagination, short final pages, height reflow, appearance migration, independent transparency, pixel luminance, contrast choice, full-window hit testing, body-click versus drag discrimination, external toolbar geometry, hover exit timing, and toolbar action routing.

The owner's local Apple Books copy of 剑来 was used for full-book parsing: 1,248 spine entries, 1,247 nonempty text sections, and 13,042,720 Swift characters. Thirty-two automated tests pass. Native UI checks cover chapter selection, normal/stealth switching, arrow paging, scrolling, typography, independent brightness and transparency, compact settings, installed-app launch, and pin toggling, brief reveal feedback, and a live edge resize that preserved the first source character and saved position. After restart, the selected book, chapter, UTF-16 source offset and all preferences matched exactly. A separate native white/black fixture confirmed real ScreenCaptureKit-driven switching to dark/light text after the user granted permission. Reading progress is represented by chapter and source text position, with line-level rounding on reflow; the displayed whole-book percentage is chapter-weighted.

## Design direction

The main window retains native window controls, sidebar navigation and keyboard access. The small window intentionally removes all visible controls while keeping recovery through the menu bar and a separate settings panel. The layout was compared directly with the local Apple Books reading window and Customize Theme panel. Native window guidance: https://developer.apple.com/design/human-interface-guidelines/windows

Capture filtering: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:)

## Signing regression

The 1.1 packages used ad-hoc signing. Their designated requirement contained a cdhash, so subsequent builds no longer matched the existing TCC screen-recording grant even when System Settings still showed the toggle enabled. Version 1.2 uses certificate-based identity. Two signed packages with different code-directory hashes are checked to have the same designated requirement. The one-time migration requires refreshing the existing screen-capture grant through System Settings; no TCC database changes or permission bypasses are used.

The certificate migration was verified on the installed app: after replacing the stale entry through System Settings, white/black fixture backgrounds produced dark/light text. Updating from bundle build 4 to build 5 (different CDHashes, identical certificate-based designated requirement) retained capture permission without another grant. The selected book, reading positions, preferences and 213 x 79 window size matched after the update. Native double-click verification hid all reading content and pin visuals, then restored the same text and pin state on the second double-click.

Version 1.3.1 also verifies top/bottom capture coordinates, local glyph contrast across page turns, transparent-image rejection, brightness/opacity crossover behavior, and preservation of valid contrast after a temporary capture failure. The installed build was checked against native white, black and left/right split fixtures.
