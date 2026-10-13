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
    func testReadingBodySingleClickHasNoControlAction() {
        _ = NSApplication.shared
        let view = StealthInteraction(frame:NSRect(x:0,y:0,width:360,height:150))
        XCTAssertTrue(view.hitTest(NSPoint(x:2,y:2)) === view)
        XCTAssertTrue(view.hitTest(NSPoint(x:355,y:145)) === view)
        var toggles = 0; view.toggleVisualVisibility = { toggles += 1 }
        func event(_ type:NSEvent.EventType,_ point:NSPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)! }
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:180,y:75))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:180,y:75)))
        XCTAssertEqual(toggles,0)
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:2,y:2))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:2,y:2)))
        XCTAssertEqual(toggles,0)
        view.mouseDown(with:event(.leftMouseDown,NSPoint(x:170,y:75))); view.mouseUp(with:event(.leftMouseUp,NSPoint(x:180,y:75)))
        XCTAssertEqual(toggles,0,"Movement must not toggle visual visibility")
    }
    func testCapturePixelLuminance() {
        for (white,expected) in [(0.0,0.0),(1.0,1.0)] {
            let context = CGContext(data:nil,width:64,height:32,bitsPerComponent:8,bytesPerRow:64*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:white,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:32))
            XCTAssertEqual(BackgroundContrast.luminance(of:context.makeImage()!)!,expected,accuracy:0.01)
        }
    }

    func testDraggingEmptyMarginMovesWindowWithoutVisibilityToggle() {
        _ = NSApplication.shared
        let window = StealthWindow(contentRect:NSRect(x:100,y:100,width:360,height:150),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = StealthInteraction(frame:NSRect(x:0,y:0,width:360,height:150)); window.contentView = view
        var toggles = 0; view.toggleVisualVisibility = { toggles += 1 }
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

    func testDoubleClickHidesAndRestoresReadingBody() {
        _ = NSApplication.shared
        let view = StealthInteraction(frame:NSRect(x:0,y:0,width:360,height:150))
        var visibilityCount = 0
        view.toggleVisualVisibility = { view.visuallyHidden.toggle(); visibilityCount += 1 }
        func click(_ count:Int,_ point:NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:count,pressure:1)!
                if type == .leftMouseDown { view.mouseDown(with:event) } else { view.mouseUp(with:event) }
            }
        }
        click(1,NSPoint(x:180,y:75)); click(2,NSPoint(x:180,y:75))
        XCTAssertTrue(view.visuallyHidden)
        XCTAssertEqual(visibilityCount,1)
        click(1,NSPoint(x:3,y:3)); click(2,NSPoint(x:3,y:3))
        XCTAssertFalse(view.visuallyHidden); XCTAssertEqual(visibilityCount,2)
        click(3,NSPoint(x:180,y:75)); click(4,NSPoint(x:180,y:75))
        XCTAssertTrue(view.visuallyHidden); XCTAssertEqual(visibilityCount,3)
    }
    func testVisualHidePreservesPaintReadingAnchorAndInputSurface() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:360,height:150))
        let content = String(repeating:"保存当前阅读位置与外观。",count:60)
        view.display(content,fontSize:11,brightness:0.8,stealth:true,character:120,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:0,margin:48,backgroundOpacity:0.35,textOpacity:0.6)
        let paint = view.layer?.backgroundColor, range = view.displayedRange, text = view.text.string
        view.locator.pulse(); view.setVisualHidden(true)
        XCTAssertEqual(view.scroll.alphaValue,0); XCTAssertEqual(view.layer?.backgroundColor?.alpha,0); XCTAssertTrue(view.locator.isHidden)
        XCTAssertTrue(view.interaction.visuallyHidden); XCTAssertTrue(view.interaction.hitTest(NSPoint(x:40,y:40)) === view.interaction)
        XCTAssertEqual(view.displayedRange,range); XCTAssertEqual(view.text.string,text)
        view.setVisualHidden(false)
        XCTAssertEqual(view.scroll.alphaValue,1); XCTAssertEqual(view.layer?.backgroundColor,paint); XCTAssertFalse(view.interaction.visuallyHidden)
        XCTAssertEqual(view.displayedRange,range); XCTAssertEqual(view.text.string,text)
        XCTAssertEqual((view.text.textStorage!.attribute(.foregroundColor,at:0,effectiveRange:nil) as! NSColor).alphaComponent,0.6)
    }

    func testBorderlessWindowRestoresSavedDimensionsAndOrigin() {
        _ = NSApplication.shared
        let name = "moread-window-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey:"NSWindow Frame \(name)") }
        let original = StealthWindow(contentRect:NSRect(x:400,y:400,width:222,height:89),styleMask:[.borderless],backing:.buffered,defer:false)
        original.isReleasedWhenClosed = false; original.saveFrame(usingName:name)
        let reopened = StealthWindow(contentRect:NSRect(x:0,y:0,width:360,height:150),styleMask:[.borderless],backing:.buffered,defer:false)
        reopened.isReleasedWhenClosed = false
        XCTAssertTrue(reopened.restoreSavedGeometry(named:name))
        XCTAssertEqual(reopened.frame.size,original.frame.size); XCTAssertEqual(reopened.frame.origin,original.frame.origin)
    }

    func testHoverToolbarGeometryAndPointerBridge() {
        let screen = NSRect(x:0,y:0,width:800,height:600)
        for reader in [NSRect(x:100,y:100,width:213,height:79),NSRect(x:200,y:520,width:200,height:80),NSRect(x:0,y:520,width:200,height:80)] {
            let toolbar = HoverToolbarGeometry.frame(reader:reader,screen:screen)
            XCTAssertTrue(screen.contains(toolbar)); XCTAssertFalse(reader.intersects(toolbar))
            XCTAssertTrue(HoverToolbarGeometry.contains(NSPoint(x:toolbar.midX,y:toolbar.midY),reader:reader,toolbar:toolbar))
        }
        let reader = NSRect(x:100,y:100,width:213,height:79), toolbar = HoverToolbarGeometry.frame(reader:NSRect(x:100,y:100,width:213,height:79),screen:screen)
        XCTAssertTrue(HoverToolbarGeometry.contains(NSPoint(x:toolbar.midX,y:reader.maxY+0.5),reader:reader,toolbar:toolbar))
        XCTAssertFalse(HoverToolbarGeometry.contains(NSPoint(x:reader.maxX-3,y:reader.maxY+0.5),reader:reader,toolbar:toolbar))
        let textTop = reader.maxY - 12
        let tight = HoverToolbarGeometry.frame(reader:reader,screen:screen,fontSize:9,textTop:textTop)
        let symbolBottom = tight.minY + 2 + 9*1.5*(1-0.58)/2
        XCTAssertEqual(symbolBottom-textTop,2,accuracy:0.001)
        let secondary = NSRect(x:193,y:-982,width:1512,height:949)
        XCTAssertTrue(secondary.contains(HoverToolbarGeometry.frame(reader:NSRect(x:700,y:-400,width:213,height:79),screen:secondary)))
    }
    func testHoverToolbarLeaveDelayDoesNotStayVisible() {
        var state = HoverVisibility(); let now = Date()
        XCTAssertFalse(state.visible(inside:false,now:now))
        XCTAssertTrue(state.visible(inside:true,now:now))
        XCTAssertTrue(state.visible(inside:false,now:now.addingTimeInterval(0.1)))
        XCTAssertFalse(state.visible(inside:false,now:now.addingTimeInterval(0.3)))
        state.reset(); XCTAssertFalse(state.visible(inside:false,now:now))
    }
    func testHoverToolbarButtonsRouteIndependentActions() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let reader = StealthWindow(contentRect:NSRect(x:100,y:100,width:213,height:79),styleMask:[.borderless],backing:.buffered,defer:false); reader.isReleasedWhenClosed = false
            let toolbar = HoverToolbar(reader:reader); var actions: [String] = []
            toolbar.onContents = { actions.append("contents") }; toolbar.onSettings = { actions.append("settings") }; toolbar.onPin = { actions.append("pin") }
            for button in toolbar.buttons { XCTAssertTrue(button.sendAction(button.action,to:button.target)) }
            XCTAssertEqual(actions,["contents","settings","pin"])
            toolbar.update(enabled:false,pinned:false,tint:.white)
            XCTAssertEqual(toolbar.buttons[2].toolTip,"置顶"); XCTAssertFalse(toolbar.panel.isVisible); XCTAssertNil(toolbar.panel.parent)
            for fontSize: CGFloat in [8,9,20] {
                toolbar.update(enabled:false,pinned:false,tint:.white,fontSize:fontSize)
                for button in toolbar.buttons {
                    XCTAssertEqual(button.frame.width,fontSize * 1.5)
                    XCTAssertEqual(button.frame.height,fontSize * 1.5)
                    XCTAssertTrue(NSRect(origin:.zero,size:HoverToolbarGeometry.size(fontSize:fontSize)).contains(button.frame))
                }
            }
            toolbar.stop()
        }
    }

    func testCaptureMapOrientationMedianAndTransparency() {
        let width = 20, height = 20, frame = NSRect(x:150,y:-200,width:200,height:100)
        var pixels = [UInt8](repeating:255,count:width*height*4)
        // Top half white, bottom half black, using explicit top-to-bottom CGImage rows.
        for y in 10..<20 { for x in 0..<20 { for c in 0..<3 { pixels[(y*width+x)*4+c] = 0 } } }
        let provider = CGDataProvider(data:Data(pixels) as CFData)!
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let sample = BackgroundContrast.sample(of:image,windowFrame:frame,captureFrame:frame)!
        XCTAssertEqual(sample.background(under:NSRect(x:170,y:-130,width:30,height:20)),1)
        XCTAssertEqual(sample.background(under:NSRect(x:170,y:-190,width:30,height:20)),0)
        XCTAssertNil(sample.background(under:NSRect(x:0,y:0,width:20,height:20)))
        let mostlyDark = BackgroundSample(windowFrame:frame,captureFrame:frame,width:10,height:10,luminance:Array(repeating:0,count:80)+Array(repeating:1,count:20))
        XCTAssertEqual(mostlyDark.background(under:frame),0,"A small white patch must not invert the surrounding dark region")
        let transparent = CGContext(data:nil,width:10,height:10,bitsPerComponent:8,bytesPerRow:40,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        XCTAssertNil(BackgroundContrast.sample(of:transparent,windowFrame:frame,captureFrame:frame),"Missing pixels must not be treated as a black background")
    }
    func testLocalContrastFollowsGlyphPositionsAndPreservesReadingAnchor() {
        _ = NSApplication.shared
        let window = StealthWindow(contentRect:NSRect(x:100,y:100,width:240,height:130),styleMask:[.borderless],backing:.buffered,defer:false); window.isReleasedWhenClosed = false
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:240,height:130)); window.contentView = view
        let content = String(repeating:"中文测试文字颜色应该按照实际背景变化。",count:50)
        view.display(content,fontSize:12,brightness:1,stealth:true,character:0,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:0,margin:48,backgroundOpacity:0,textOpacity:0.7,adaptiveText:true)
        let anchor = view.visibleCharacter()
        let values = (0..<130).flatMap { _ in (0..<240).map { $0 < 120 ? 1.0 : 0.0 } }
        let sample = BackgroundSample(windowFrame:window.frame,captureFrame:window.frame,width:240,height:130,luminance:values)
        view.applyAdaptiveColor(true); view.applyBackgroundSample(sample)
        func white(at index:Int) -> Double { (view.text.textStorage!.attribute(.foregroundColor,at:index,effectiveRange:nil) as! NSColor).usingColorSpace(.genericGray)!.whiteComponent }
        XCTAssertLessThan(white(at:0),0.1); XCTAssertGreaterThan(white(at:14),0.9)
        XCTAssertEqual(view.visibleCharacter(),anchor)
        _ = view.page(1)
        XCTAssertLessThan(white(at:0),0.1); XCTAssertGreaterThan(white(at:14),0.9)
        let nextAnchor = view.visibleCharacter()
        let dark = BackgroundSample(windowFrame:window.frame,captureFrame:window.frame,width:1,height:1,luminance:[0])
        view.applyBackgroundSample(dark); XCTAssertGreaterThan(white(at:0),0.9)
        let light = BackgroundSample(windowFrame:window.frame,captureFrame:window.frame,width:1,height:1,luminance:[1])
        view.applyBackgroundSample(light); XCTAssertLessThan(white(at:14),0.1)
        XCTAssertEqual(view.visibleCharacter(),nextAnchor)
        let color = view.text.textStorage!.attribute(.foregroundColor,at:0,effectiveRange:nil) as! NSColor
        XCTAssertEqual(color.alphaComponent,0.7)
    }

    func testTemporaryCaptureFailureKeepsLastValidContrast() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let app = ReaderApp()
            app.mini = StealthWindow(contentRect:NSRect(x:100,y:100,width:240,height:130),styleMask:[.borderless],backing:.buffered,defer:false)
            app.mini.isReleasedWhenClosed = false; app.mini.contentView = app.miniSurface
            app.state.preferences.theme = "dark"; app.state.preferences.opacity = 0; app.state.preferences.adaptiveText = true
            app.miniSurface.display("白色背景下不能因短暂采样失败而变成白字",fontSize:12,brightness:1,stealth:true,character:0,dark:true,fontName:"system",lineHeight:1.15,paragraphSpacing:0,margin:48,backgroundOpacity:0,adaptiveText:true)
            let sample = BackgroundSample(windowFrame:app.mini.frame,captureFrame:app.mini.frame,width:1,height:1,luminance:[1])
            app.contrast.onSample?(sample)
            XCTAssertLessThan(app.miniSurface.foregroundColor.usingColorSpace(.genericGray)!.whiteComponent,0.1)
            app.contrast.onStatus?(.unavailable)
            XCTAssertNotNil(app.lastBackgroundSample)
            XCTAssertLessThan(app.miniSurface.foregroundColor.usingColorSpace(.genericGray)!.whiteComponent,0.1)
            app.contrast.onStatus?(.idle)
            XCTAssertNil(app.lastBackgroundSample)
        }
    }

    func testArrowChordRequiresBothKeysAndFullReleaseBeforeRepeat() {
        var chord = ArrowChord()
        XCTAssertFalse(chord.update(left:true,right:false))
        XCTAssertTrue(chord.update(left:true,right:true))
        XCTAssertFalse(chord.update(left:true,right:true))
        XCTAssertFalse(chord.update(left:false,right:true))
        XCTAssertFalse(chord.update(left:true,right:true))
        XCTAssertFalse(chord.update(left:false,right:false))
        XCTAssertTrue(chord.update(left:true,right:true))
    }

    func testSettingsRemainUndimmedAndFollowSystemAppearance() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let app = ReaderApp()
            app.window = NSWindow(contentRect:NSRect(x:0,y:0,width:300,height:200),styleMask:[.titled],backing:.buffered,defer:false)
            app.window.isReleasedWhenClosed = false
            app.settings = NSPanel(contentRect:NSRect(x:0,y:0,width:336,height:347),styleMask:[.titled],backing:.buffered,defer:false)
            app.settings?.isReleasedWhenClosed = false
            for theme in ["dark","light"] {
                app.state.preferences.theme = theme; app.state.preferences.brightness = 0; app.state.preferences.opacity = 0
                app.applyAppearance(); app.rebuildSettings()
                XCTAssertNil(NSApp.appearance); XCTAssertNil(app.settings?.appearance)
                XCTAssertFalse(app.settings!.contentView!.subviews.contains { $0 is DimmingOverlay })
                XCTAssertEqual(app.settings!.alphaValue,1)
            }
        }
    }

}
