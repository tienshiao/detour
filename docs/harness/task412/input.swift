import CoreGraphics
import Foundation
// input key <code> <flags: c o t s f or -> | type <text>  (US layout key codes)
let map: [Character: (UInt16, Bool)] = [
 "a":(0,false),"s":(1,false),"d":(2,false),"f":(3,false),"h":(4,false),"g":(5,false),"z":(6,false),"x":(7,false),"c":(8,false),"v":(9,false),"b":(11,false),"q":(12,false),"w":(13,false),"e":(14,false),"r":(15,false),"y":(16,false),"t":(17,false),"1":(18,false),"2":(19,false),"3":(20,false),"4":(21,false),"6":(22,false),"5":(23,false),"9":(25,false),"7":(26,false),"8":(28,false),"0":(29,false),"o":(31,false),"u":(32,false),"i":(34,false),"p":(35,false),"l":(37,false),"j":(38,false),"k":(40,false),"n":(45,false),"m":(46,false),".":(47,false),"/":(44,false),":":(41,true)]
func post(_ code: UInt16, _ flags: CGEventFlags) {
  let src = CGEventSource(stateID: .hidSystemState)
  for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(15000)
  }
}
let a = CommandLine.arguments
if a[1] == "key" {
  var f: CGEventFlags = []
  for ch in a[3] { switch ch { case "c": f.insert(.maskCommand); case "o": f.insert(.maskAlternate); case "t": f.insert(.maskControl); case "s": f.insert(.maskShift); case "f": f.insert(.maskSecondaryFn); default: break } }
  post(UInt16(a[2])!, f)
} else if a[1] == "type" {
  for ch in a[2] { let (c, sh) = map[ch]!; post(c, sh ? .maskShift : []) ; usleep(20000) }
}
