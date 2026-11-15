import AppKit

extension ReaderApp {
    func refreshVisibleSettings(structureChanged: Bool = false) {
        guard let settings, settings.isVisible else { return }
        if structureChanged { rebuildSettings(); return }
        let p = state.preferences
        let values: [Int: Double] = [0:p.fontSize, 1:p.stealthFontSize, 2:p.brightness, 3:1-p.opacity, 4:p.lineHeight, 5:p.stealthLineHeight, 6:p.paragraphSpacing, 7:p.stealthParagraphSpacing, 8:p.margin, 9:1-p.textOpacity]
        for (tag, slider) in settingsSliders {
            if let value = values[tag] { slider.doubleValue = value; settingsValues[tag]?.stringValue = settingValue(tag, value) }
        }
        func update(_ view: NSView) {
            if let font = view as? FontPreviewButton { font.state = font.fontKey == (settingsTab == 1 ? p.stealthFontName : p.fontName) ? .on : .off }
            else if let button = view as? NSButton {
                switch button.action {
                case #selector(toggleFloating(_:)): button.state = p.floating ? .on : .off
                case #selector(toggleAdaptive(_:)): button.state = p.adaptiveText ? .on : .off
                case #selector(toggleReadingMode): button.image = NSImage(systemSymbolName: p.readingMode == .paged ? "book.pages" : "scroll", accessibilityDescription: nil)
                case #selector(toggleStealth): button.image = NSImage(systemSymbolName: isStealth ? "rectangle.expand.vertical" : "rectangle.compress.vertical", accessibilityDescription: nil)
                default: break
                }
            }
            for child in view.subviews { update(child) }
        }
        if let root = settings.contentView { update(root) }
    }
}
