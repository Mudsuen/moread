import AppKit
let directory = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for (name,size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
 let s = CGFloat(size), image = NSImage(size:NSSize(width:s,height:s)); image.lockFocus()
 let context = NSGraphicsContext.current!.cgContext; context.scaleBy(x:s/1024,y:s/1024)
 NSColor(calibratedRed:0.18,green:0.28,blue:0.25,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:196,yRadius:196).fill()
 NSColor(calibratedRed:0.95,green:0.93,blue:0.85,alpha:1).setFill()
 let left = NSBezierPath(); left.move(to:NSPoint(x:248,y:294)); left.line(to:NSPoint(x:248,y:718)); left.curve(to:NSPoint(x:492,y:670),controlPoint1:NSPoint(x:344,y:740),controlPoint2:NSPoint(x:418,y:700)); left.line(to:NSPoint(x:492,y:248)); left.curve(to:NSPoint(x:248,y:294),controlPoint1:NSPoint(x:410,y:295),controlPoint2:NSPoint(x:334,y:319)); left.fill()
 let right = NSBezierPath(); right.move(to:NSPoint(x:532,y:248)); right.line(to:NSPoint(x:532,y:670)); right.curve(to:NSPoint(x:776,y:718),controlPoint1:NSPoint(x:606,y:700),controlPoint2:NSPoint(x:680,y:740)); right.line(to:NSPoint(x:776,y:294)); right.curve(to:NSPoint(x:532,y:248),controlPoint1:NSPoint(x:690,y:319),controlPoint2:NSPoint(x:614,y:295)); right.fill()
 NSColor(calibratedRed:0.72,green:0.60,blue:0.38,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:671,y:542,width:32,height:203),xRadius:8,yRadius:8).fill()
 image.unlockFocus(); let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!; try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
}
