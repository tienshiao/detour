import Carbon.HIToolbox
import Foundation

/// A keyboard layout's characters, read from its Unicode layout data with
/// `UCKeyTranslate` (TASK-335): which character a key types with no
/// modifier, or with Shift.
///
/// The shortcut recorders use it to see that a recorded Shift+key is also
/// the key's shifted character: on a US layout ⇧⌘= is what fires View >
/// Zoom In (⌘+), since AppKit matches a menu item against the typed
/// character with the Shift that produced it implied (measured,
/// docs/harness/task335).
struct KeyboardLayout {
    /// The layout's 'uchr' data.
    private let data: Data

    /// Nil for an input source with no Unicode layout data.
    init?(inputSource: TISInputSource) {
        guard let pointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The keyboard layout in use, as typing reads it; nil when it has no
    /// Unicode layout data.
    static func current() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout(inputSource: source)
    }

    /// An installed layout by its input source ID ("com.apple.keylayout.US"),
    /// whether or not the user has it turned on: for tests, which must not
    /// depend on the layout in use.
    static func installed(id: String) -> KeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        return KeyboardLayout(inputSource: source)
    }

    /// The character `keyCode` types with Shift (or with no modifier), as
    /// it is typed: not lowercased. A dead key gives its own character
    /// rather than waiting for the next key. "" for a key that types no
    /// printable character (Return, an arrow, F5) or nothing on this layout.
    func character(forKeyCode keyCode: UInt16, shift: Bool) -> String {
        let modifierState = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                  characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "" }
        let typed = String(utf16CodeUnits: characters, count: length)
        // Control characters (Return, Tab, Escape, Delete, the function
        // keys' 0x10) and AppKit's private-use function-key range.
        let printable = typed.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
        return printable ? typed : ""
    }

    /// The character `keyCode` types with Shift on the layout in use ("" when
    /// there is none, or the layout has no Unicode data).
    static func currentShiftedCharacter(forKeyCode keyCode: UInt16) -> String {
        current()?.character(forKeyCode: keyCode, shift: true) ?? ""
    }
}
