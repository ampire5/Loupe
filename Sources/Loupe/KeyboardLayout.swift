import AppKit
import Carbon.HIToolbox

/// Makes key bindings independent of the input language: with a non-Latin layout (Russian, Greek…)
/// a key is read through the ASCII-capable layout (ABC/US), as macOS does for menu shortcuts.
enum KeyboardLayout {
    /// The characters to bind `event` by, with Shift applied and other modifiers ignored.
    static func characters(for event: NSEvent) -> String? {
        let typed = event.charactersIgnoringModifiers
        guard !currentIsASCIICapable,
              let latin = translate(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)) else { return typed }
        return latin
    }

    private static var currentIsASCIICapable: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return true }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }

    static func translate(keyCode: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) & 0xFF : 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
