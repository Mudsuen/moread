import Foundation

public enum ContrastMath {
    public static func linear(_ channel: Double) -> Double { channel <= 0.04045 ? channel/12.92 : pow((channel+0.055)/1.055,2.4) }
    public static func exposure(_ brightness: Double) -> Double { 0.25+0.75*min(1,max(0,brightness)) }
    public static func textWhite(_ base:Double, brightness:Double) -> Double {
        let factor = exposure(brightness)
        return 0.5+(base-0.5)*factor
    }
    public static func prefersWhite(backgroundLuminance: Double, brightness: Double, textOpacity: Double, previous: Bool? = nil) -> Bool {
        let bg = min(1,max(0,backgroundLuminance))
        func contrast(_ value: Double) -> Double {
            let text = linear(textWhite(value,brightness:brightness))*textOpacity+bg*(1-textOpacity)
            return (max(bg,text)+0.05)/(min(bg,text)+0.05)
        }
        let light = contrast(0.98), dark = contrast(0.06)
        // Hold the current polarity only near the crossover; clear black/white changes
        // must switch immediately, even at low text opacity or app brightness.
        if let previous, bg > linear(textWhite(0.06,brightness:brightness)), bg < linear(textWhite(0.98,brightness:brightness)), max(light,dark) < min(light,dark)*1.12 { return previous }
        return light >= dark
    }
}
