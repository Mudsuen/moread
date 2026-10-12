import AppKit
import XCTest
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
        XCTAssertLessThanOrEqual(abs(view.visibleCharacter()-beforeResize),40)
        XCTAssertEqual(view.subviews.count,1); XCTAssertFalse(view.scroll.hasVerticalScroller)
        XCTAssertFalse(view.text.isEditable); XCTAssertFalse(view.text.isSelectable)
        XCTAssertEqual(view.layer?.backgroundColor,NSColor(white:0,alpha:1).cgColor)
        view.goToEnd(); XCTAssertTrue(view.page(1))
    }
    func testNormalMarginAndParagraphStyling() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame:NSRect(x:0,y:0,width:680,height:400))
        view.display("标题\n\n正文第一段\n\n正文第二段",fontSize:20,brightness:1,stealth:false,character:0,dark:true,fontName:"serif",lineHeight:1.5,paragraphSpacing:12,margin:60)
        XCTAssertEqual(view.text.textContainerInset.width,60)
        XCTAssertTrue(view.scroll.hasVerticalScroller); XCTAssertTrue(view.text.isSelectable)
        let paragraph = view.text.textStorage!.attribute(.paragraphStyle,at:4,effectiveRange:nil) as! NSParagraphStyle
        XCTAssertEqual(paragraph.lineHeightMultiple,1.5); XCTAssertEqual(paragraph.paragraphSpacing,12)
    }
}
