// TASK-335 spike 2: UCKeyTranslate on installed layouts (no input source switched): the characters of the 1, =, /, C and 0 keys with no modifier, Shift, ⌘, ⇧⌘, ⌃ and ⇧⌃.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o layouts layout-characters.swift; run with the sandbox off. Result (2026-11-14) in TASK-335's notes and wiki/features/keyboard-shortcuts.md.
import AppKit
import Carbon.HIToolbox
func translate(_ source: TISInputSource, _ code: Int, _ carbon: Int) -> String {
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "<no data>" }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { raw -> String in
        let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0; var chars = [UniChar](repeating: 0, count: 4); var length = 0
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), UInt32(carbon >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : "<err>"
    }
}
for id in ["com.apple.keylayout.French", "com.apple.keylayout.French-PC", "com.apple.keylayout.German", "com.apple.keylayout.Russian", "com.apple.keylayout.US"] {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let src = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first else { print(id, "n/a"); continue }
    var line = id + ":"
    for code in [kVK_ANSI_1, kVK_ANSI_Equal, kVK_ANSI_Slash, kVK_ANSI_C, kVK_ANSI_0] {
        line += " \(code)[" + [0, shiftKey, cmdKey, cmdKey | shiftKey, controlKey, controlKey | shiftKey].map { translate(src, code, $0).debugDescription }.joined(separator: ",") + "]"
    }
    print(line)
}
