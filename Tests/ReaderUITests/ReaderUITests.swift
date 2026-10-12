import AppKit
import XCTest
import ReaderCore
@testable import MudsReader

final class ReaderUITests: XCTestCase {
    func testNativePagingReflowAndStealthStructure() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:360,height:150))
        let content = (0..<100).map { "第\($0)段 测试中文连续阅读和文字换行，缩放窗口时应该保留阅读位置。" }.joined(separator:"\n\n")
        view.display(content,fontSize:11,brightness:0,stealth:true,character:0,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:0,margin:48)
        XCTAssertEqual(view.visibleCharacter(),0)
        XCTAssertFalse(view.page(1)); let afterPage = view.visibleCharacter(); XCTAssertGreaterThan(afterPage,0)
        XCTAssertFalse(view.page(-1)); XCTAssertEqual(view.visibleCharacter(),0)
        view.restore(320); let beforeResize = view.visibleCharacter()
        view.frame.size.width = 250; view.needsLayout = true; view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.visibleCharacter(),beforeResize)
        XCTAssertEqual(view.subviews.count,3); XCTAssertTrue(view.locator.isHidden); XCTAssertFalse(view.interaction.isHidden); XCTAssertFalse(view.scroll.hasVerticalScroller)
        XCTAssertFalse(view.text.isEditable); XCTAssertFalse(view.text.isSelectable)
        XCTAssertEqual(view.layer?.backgroundColor?.alpha,1)
        view.goToEnd(); XCTAssertTrue(view.page(1))
    }
    func testNormalMarginAndParagraphStyling() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:680,height:400))
        view.display("标题\n\n正文第一段\n\n正文第二段",fontSize:20,brightness:1,stealth:false,character:0,dark:true,fontName:"serif",lineHeight:1.5,paragraphSpacing:12,margin:60,mode:.scrolling)
        XCTAssertEqual(view.text.textContainerInset.width,60)
        XCTAssertTrue(view.scroll.hasVerticalScroller); XCTAssertTrue(view.text.isSelectable)
        let paragraph = view.text.textStorage!.attribute(.paragraphStyle,at:4,effectiveRange:nil) as! NSParagraphStyle
        XCTAssertEqual(paragraph.lineHeightMultiple,1.5); XCTAssertEqual(paragraph.paragraphSpacing,12)
    }
    func testPagesAreLosslessDisjointAndFitIncludingFinalPage() {
        _ = NSApplication.shared
        let content = (0..<30).map { "第\($0)段 中文阅读，标点与👨‍👩‍👧‍👦组合字符。A long English sentence with a café and é. 测试完整换行。" }.joined(separator:"\n\n") + "\n最后一行。"
        for (width,height,font,lineHeight,stealth) in [(160.0,64.0,20.0,2.0,true),(360,150,9,1.15,true),(720,480,20,1.45,false)] {
            let view = ReaderSurface(frame:NSRect(x:0,y:0,width:width,height:height))
            view.display(content,fontSize:font,brightness:0,stealth:stealth,character:0,dark:true,fontName:"system",lineHeight:lineHeight,paragraphSpacing:8,margin:48)
            XCTAssertGreaterThan(view.pageRanges.count,1)
            var end = 0, collected = ""
            for (index,range) in view.pageRanges.enumerated() {
                XCTAssertEqual(range.location,end,"No overlap or skipped source characters")
                XCTAssertGreaterThan(range.length,0)
                XCTAssertEqual(view.displayedRange,range)
                collected += view.text.string; end = NSMaxRange(range)
                var drawnBottom: CGFloat = 0
                let manager = view.text.layoutManager!
                manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { _,used,_,glyphs,_ in
                    let chars = manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
                    let line = (view.text.string as NSString).substring(with:chars)
                    if !line.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { drawnBottom = max(drawnBottom,used.maxY) }
                }
                XCTAssertLessThanOrEqual(drawnBottom,height-view.text.textContainerInset.height*2+1,"Page \(index) must fit without clipping glyphs")
                if index < view.pageRanges.count-1 { XCTAssertFalse(view.page(1)) }
            }
            XCTAssertEqual(end,(content as NSString).length); XCTAssertEqual(collected,content)
            let finalRange = view.displayedRange; XCTAssertTrue(view.page(1)); XCTAssertEqual(view.displayedRange,finalRange)
            for index in (0..<view.pageRanges.count-1).reversed() { XCTAssertFalse(view.page(-1)); XCTAssertEqual(view.displayedRange,view.pageRanges[index]) }
            XCTAssertTrue(view.page(-1))
        }
    }
    func testModeSwitchAndHeightResizePreserveReadingLocation() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:360,height:150))
        let content = String(repeating:"连续中文阅读测试，包含不同段落。\n\n",count:100)
        func show(_ mode: ReaderCore.ReadingMode,_ character:Int) {
            view.display(content,fontSize:11,brightness:0,stealth:true,character:character,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:3,margin:48,mode:mode)
        }
        show(.scrolling,500); let cursor = view.visibleCharacter()
        show(.paged,cursor); XCTAssertTrue(NSLocationInRange(cursor,view.displayedRange)); XCTAssertTrue(view.scroll.paged)
        let pageStart = view.visibleCharacter(), oldPageCount = view.pageRanges.count
        view.frame.size.height = 90; view.needsLayout = true; view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.pageRanges.count,oldPageCount); XCTAssertEqual(view.visibleCharacter(),pageStart)
        let resizedStart = view.visibleCharacter(); show(.scrolling,resizedStart)
        XCTAssertFalse(view.scroll.paged); XCTAssertLessThanOrEqual(abs(view.visibleCharacter()-resizedStart),35)
    }

    func testLocalBookPaginationWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MUDSREADER_TEST_EPUB"] else { throw XCTSkip("Set MUDSREADER_TEST_EPUB to verify a local EPUB without committing it") }
        _ = NSApplication.shared
        let book = try EPUB.load(directory:URL(fileURLWithPath:path))
        for chapter in Set([min(11,book.chapters.count-1),min(200,book.chapters.count-1),book.chapters.count-1]) {
            let content = try book.text(at:chapter)
            for (width,height,font,stealth) in [(360.0,150.0,9.0,true),(680,450,20,false)] {
                let view = ReaderSurface(frame:NSRect(x:0,y:0,width:width,height:height))
                view.display(content,fontSize:font,brightness:0,stealth:stealth,character:0,dark:true,fontName:stealth ? "system" : "serif",lineHeight:1.35,paragraphSpacing:4,margin:48)
                var result = "", end = 0
                for (index,range) in view.pageRanges.enumerated() {
                    XCTAssertEqual(range.location,end); result += view.text.string; end = NSMaxRange(range)
                    if index < view.pageRanges.count-1 { XCTAssertFalse(view.page(1)) }
                }
                XCTAssertEqual(result,content); XCTAssertTrue(view.page(1))
            }
        }
    }

    func testFullTransparencyOnlyClearsBackground() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:360,height:150))
        view.display("只显示清晰文字",fontSize:11,brightness:0,stealth:true,character:0,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:0,margin:48,backgroundOpacity:0)
        XCTAssertEqual(view.layer!.backgroundColor!.alpha,0)
        let foreground = view.text.textStorage!.attribute(.foregroundColor,at:0,effectiveRange:nil) as! NSColor
        XCTAssertEqual(foreground.alphaComponent,1)
        XCTAssertFalse(view.scroll.drawsBackground); XCTAssertFalse(view.text.drawsBackground)
        XCTAssertEqual(view.text.string,"只显示清晰文字")
    }

    func testTransparentTextAlphaAndAdaptiveContrast() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:360,height:150))
        view.display("文字透明独立于背景",fontSize:11,brightness:1,stealth:true,character:0,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:0,margin:48,backgroundOpacity:0,textOpacity:0.4,adaptiveText:true)
        view.applyAdaptiveColor(false)
        var color = view.text.textStorage!.attribute(.foregroundColor,at:0,effectiveRange:nil) as! NSColor
        XCTAssertEqual(color.alphaComponent,0.4); XCTAssertLessThan(color.usingColorSpace(.genericGray)!.whiteComponent,0.1)
        view.applyAdaptiveColor(true)
        color = view.text.textStorage!.attribute(.foregroundColor,at:0,effectiveRange:nil) as! NSColor
        XCTAssertEqual(color.alphaComponent,0.4); XCTAssertGreaterThan(color.usingColorSpace(.genericGray)!.whiteComponent,0.9)
        XCTAssertEqual(view.layer!.backgroundColor!.alpha,0)
    }
    func testSmallWindowHitCoverageAndCenterClick() {
        _ = NSApplication.shared
        let view = StealthInteraction(frame:NSRect(x:0,y:0,width:360,height:150))
        XCTAssertTrue(view.hitTest(NSPoint(x:2,y:2)) === view)
        XCTAssertTrue(view.hitTest(NSPoint(x:355,y:145)) === view)
        var toggles = 0; view.togglePinned = { toggles += 1 }
        func event(_ type:NSEvent.EventType,_ point:NSPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)! }
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:180,y:75))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:180,y:75)))
        XCTAssertEqual(toggles,1)
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:2,y:2))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:2,y:2)))
        XCTAssertEqual(toggles,1)
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:170,y:75))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:180,y:75)))
        XCTAssertEqual(toggles,1,"Movement must not toggle pin")
    }
    func testCapturePixelLuminance() {
        for (white,expected) in [(0.0,0.0),(1.0,1.0)] {
            let context = CGContext(data:nil,width:64,height:32,bitsPerComponent:8,bytesPerRow:64*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:white,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:32))
            XCTAssertEqual(BackgroundContrast.luminance(of:context.makeImage()!)!,expected,accuracy:0.01)
        }
    }

    func testDraggingEmptyMarginMovesWindowWithoutPinToggle() {
        _ = NSApplication.shared
        let window = StealthWindow(contentRect:NSRect(x:100,y:100,width:360,height:150),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = StealthInteraction(frame:NSRect(x:0,y:0,width:360,height:150)); window.contentView = view
        var toggles = 0; view.togglePinned = { toggles += 1 }
        func event(_ type:NSEvent.EventType,_ point:NSPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)! }
        let origin = window.frame.origin
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:20,y:30)))
        view.mouseDragged(with:event(.leftMouseDragged,NSPoint(x:60,y:50)))
        view.mouseUp(with:event(.leftMouseUp,NSPoint(x:20,y:30)))
        XCTAssertEqual(window.frame.size,NSSize(width:360,height:150)); XCTAssertEqual(window.frame.minX,origin.x+40); XCTAssertEqual(window.frame.minY,origin.y+20); XCTAssertEqual(toggles,0)
    }

    func testResizeKeepsExactFirstCharacterAndLosslessPages() {
        _ = NSApplication.shared
        let content = (0..<80).map { "第\($0)段 开头固定，缩放只改变本页结尾。新的页面不能重复上一页的内容。" }.joined(separator:"\n\n")
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:360,height:150))
        view.display(content,fontSize:11,brightness:1,stealth:true,character:700,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:0,margin:48)
        let start = view.visibleCharacter(), prefix = String(view.text.string.prefix(10))
        XCTAssertEqual(start,700)
        for size in [NSSize(width:320,height:100),NSSize(width:500,height:200),NSSize(width:180,height:64),NSSize(width:400,height:300)] {
            view.frame.size = size; view.needsLayout = true; view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.visibleCharacter(),start); XCTAssertTrue(view.text.string.hasPrefix(prefix))
            var end = 0
            for range in view.pageRanges { XCTAssertEqual(range.location,end); end = NSMaxRange(range) }
            XCTAssertEqual(end,(content as NSString).length)
        }
    }
    func testResizeHitZonesDirectionsAndMinimumSize() {
        _ = NSApplication.shared
        let window = StealthWindow(contentRect:NSRect(x:100,y:100,width:360,height:150),styleMask:[.borderless],backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.minSize = NSSize(width:160,height:64)
        let view = StealthInteraction(frame:NSRect(x:0,y:0,width:360,height:150)); window.contentView = view
        XCTAssertEqual(view.resizeEdges(at:NSPoint(x:8,y:75)),.left)
        XCTAssertEqual(view.resizeEdges(at:NSPoint(x:352,y:75)),.right)
        XCTAssertEqual(view.resizeEdges(at:NSPoint(x:180,y:8)),.bottom)
        XCTAssertEqual(view.resizeEdges(at:NSPoint(x:180,y:142)),.top)
        XCTAssertEqual(view.resizeEdges(at:NSPoint(x:15,y:15)),[.left,.bottom])
        XCTAssertEqual(view.resizeEdges(at:NSPoint(x:345,y:135)),[.right,.top])
        XCTAssertTrue(view.resizeEdges(at:NSPoint(x:20,y:30)).isEmpty)
        func event(_ type:NSEvent.EventType,_ point:NSPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)! }
        let top = window.frame.maxY
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:359,y:1))); view.mouseDragged(with:event(.leftMouseDragged,NSPoint(x:459,y:-19))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:459,y:-19)))
        XCTAssertEqual(window.frame.width,460); XCTAssertEqual(window.frame.height,170); XCTAssertEqual(window.frame.maxY,top)
        let right = window.frame.maxX
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:1,y:75))); view.mouseDragged(with:event(.leftMouseDragged,NSPoint(x:1000,y:75))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:1000,y:75)))
        XCTAssertEqual(window.frame.width,160); XCTAssertEqual(window.frame.maxX,right)
    }
    func testLocatorIsTemporaryAndDoesNotInterceptInput() {
        _ = NSApplication.shared
        let locator = WindowLocator(frame:NSRect(x:0,y:0,width:360,height:150))
        locator.pulse(); XCTAssertFalse(locator.isHidden); XCTAssertNil(locator.hitTest(NSPoint(x:3,y:3)))
        RunLoop.current.run(until:Date().addingTimeInterval(1.6)); XCTAssertTrue(locator.isHidden)
    }

}
