import Foundation
import Carbon.HIToolbox.Events
import CoreGraphics

struct KeyCombination {
    let virtualKey: CGKeyCode
    let modifiers: CGEventFlags
    let fallbackUnicode: String?
}

enum KeyParser {
    static func parse(_ spec: String) -> KeyCombination? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = tokens.last else { return nil }
        let modifierTokens = tokens.dropLast()
        var flags: CGEventFlags = []
        for m in modifierTokens {
            guard let flag = modifierFlag(m) else { return nil }
            flags.insert(flag)
        }
        if let (vk, extraFlag) = virtualKey(forName: last) {
            return KeyCombination(
                virtualKey: vk, modifiers: flags.union(extraFlag), fallbackUnicode: nil)
        }
        if last.count == 1 {
            let ch = last
            if let (vk, extraFlag) = virtualKey(forChar: ch) {
                return KeyCombination(
                    virtualKey: vk, modifiers: flags.union(extraFlag), fallbackUnicode: nil)
            }
            return KeyCombination(virtualKey: 0, modifiers: flags, fallbackUnicode: ch)
        }
        return nil
    }

    private static func modifierFlag(_ name: String) -> CGEventFlags? {
        switch name.lowercased() {
        case "shift", "shift_l", "shift_r": return .maskShift
        case "ctrl", "control", "control_l", "control_r": return .maskControl
        case "alt", "option", "opt", "alt_l", "alt_r": return .maskAlternate
        case "cmd", "command", "super", "super_l", "super_r", "meta", "meta_l", "meta_r":
            return .maskCommand
        case "fn", "function": return .maskSecondaryFn
        default: return nil
        }
    }

    private static func virtualKey(forName name: String) -> (CGKeyCode, CGEventFlags)? {
        switch name {
        case "Return", "Enter", "KP_Enter": return (CGKeyCode(kVK_Return), [])
        case "Tab", "KP_Tab": return (CGKeyCode(kVK_Tab), [])
        case "Space", "KP_Space": return (CGKeyCode(kVK_Space), [])
        case "BackSpace", "Backspace": return (CGKeyCode(kVK_Delete), [])
        case "Delete": return (CGKeyCode(kVK_ForwardDelete), [])
        case "Escape", "Esc": return (CGKeyCode(kVK_Escape), [])
        case "Left", "KP_Left": return (CGKeyCode(kVK_LeftArrow), [])
        case "Right", "KP_Right": return (CGKeyCode(kVK_RightArrow), [])
        case "Up", "KP_Up": return (CGKeyCode(kVK_UpArrow), [])
        case "Down", "KP_Down": return (CGKeyCode(kVK_DownArrow), [])
        case "Home", "KP_Home": return (CGKeyCode(kVK_Home), [])
        case "End", "KP_End": return (CGKeyCode(kVK_End), [])
        case "Page_Up", "PageUp", "KP_Page_Up", "KP_Prior", "Prior":
            return (CGKeyCode(kVK_PageUp), [])
        case "Page_Down", "PageDown", "KP_Page_Down", "KP_Next", "Next":
            return (CGKeyCode(kVK_PageDown), [])
        case "Insert", "KP_Insert": return (CGKeyCode(kVK_Help), [])
        case "F1": return (CGKeyCode(kVK_F1), [])
        case "F2": return (CGKeyCode(kVK_F2), [])
        case "F3": return (CGKeyCode(kVK_F3), [])
        case "F4": return (CGKeyCode(kVK_F4), [])
        case "F5": return (CGKeyCode(kVK_F5), [])
        case "F6": return (CGKeyCode(kVK_F6), [])
        case "F7": return (CGKeyCode(kVK_F7), [])
        case "F8": return (CGKeyCode(kVK_F8), [])
        case "F9": return (CGKeyCode(kVK_F9), [])
        case "F10": return (CGKeyCode(kVK_F10), [])
        case "F11": return (CGKeyCode(kVK_F11), [])
        case "F12": return (CGKeyCode(kVK_F12), [])
        case "F13": return (CGKeyCode(kVK_F13), [])
        case "F14": return (CGKeyCode(kVK_F14), [])
        case "F15": return (CGKeyCode(kVK_F15), [])
        case "F16": return (CGKeyCode(kVK_F16), [])
        case "F17": return (CGKeyCode(kVK_F17), [])
        case "F18": return (CGKeyCode(kVK_F18), [])
        case "F19": return (CGKeyCode(kVK_F19), [])
        case "F20": return (CGKeyCode(kVK_F20), [])
        case "KP_0": return (CGKeyCode(kVK_ANSI_Keypad0), [])
        case "KP_1": return (CGKeyCode(kVK_ANSI_Keypad1), [])
        case "KP_2": return (CGKeyCode(kVK_ANSI_Keypad2), [])
        case "KP_3": return (CGKeyCode(kVK_ANSI_Keypad3), [])
        case "KP_4": return (CGKeyCode(kVK_ANSI_Keypad4), [])
        case "KP_5": return (CGKeyCode(kVK_ANSI_Keypad5), [])
        case "KP_6": return (CGKeyCode(kVK_ANSI_Keypad6), [])
        case "KP_7": return (CGKeyCode(kVK_ANSI_Keypad7), [])
        case "KP_8": return (CGKeyCode(kVK_ANSI_Keypad8), [])
        case "KP_9": return (CGKeyCode(kVK_ANSI_Keypad9), [])
        case "KP_Add", "plus": return (CGKeyCode(kVK_ANSI_KeypadPlus), [])
        case "KP_Subtract", "minus": return (CGKeyCode(kVK_ANSI_KeypadMinus), [])
        case "KP_Multiply", "asterisk": return (CGKeyCode(kVK_ANSI_KeypadMultiply), [])
        case "KP_Divide", "slash": return (CGKeyCode(kVK_ANSI_KeypadDivide), [])
        case "KP_Decimal", "period": return (CGKeyCode(kVK_ANSI_KeypadDecimal), [])
        case "KP_Equal", "equal": return (CGKeyCode(kVK_ANSI_KeypadEquals), [])
        case "Caps_Lock": return (CGKeyCode(kVK_CapsLock), [])
        case "Help": return (CGKeyCode(kVK_Help), [])
        default: return nil
        }
    }

    private static func virtualKey(forChar char: String) -> (CGKeyCode, CGEventFlags)? {
        guard let scalar = char.unicodeScalars.first else { return nil }
        let lower = Character(String(scalar).lowercased())
        let needsShift =
            Character(String(scalar)) != lower && String(scalar).uppercased() == String(scalar)
        let flag: CGEventFlags = needsShift ? .maskShift : []
        switch lower {
        case "a": return (CGKeyCode(kVK_ANSI_A), flag)
        case "b": return (CGKeyCode(kVK_ANSI_B), flag)
        case "c": return (CGKeyCode(kVK_ANSI_C), flag)
        case "d": return (CGKeyCode(kVK_ANSI_D), flag)
        case "e": return (CGKeyCode(kVK_ANSI_E), flag)
        case "f": return (CGKeyCode(kVK_ANSI_F), flag)
        case "g": return (CGKeyCode(kVK_ANSI_G), flag)
        case "h": return (CGKeyCode(kVK_ANSI_H), flag)
        case "i": return (CGKeyCode(kVK_ANSI_I), flag)
        case "j": return (CGKeyCode(kVK_ANSI_J), flag)
        case "k": return (CGKeyCode(kVK_ANSI_K), flag)
        case "l": return (CGKeyCode(kVK_ANSI_L), flag)
        case "m": return (CGKeyCode(kVK_ANSI_M), flag)
        case "n": return (CGKeyCode(kVK_ANSI_N), flag)
        case "o": return (CGKeyCode(kVK_ANSI_O), flag)
        case "p": return (CGKeyCode(kVK_ANSI_P), flag)
        case "q": return (CGKeyCode(kVK_ANSI_Q), flag)
        case "r": return (CGKeyCode(kVK_ANSI_R), flag)
        case "s": return (CGKeyCode(kVK_ANSI_S), flag)
        case "t": return (CGKeyCode(kVK_ANSI_T), flag)
        case "u": return (CGKeyCode(kVK_ANSI_U), flag)
        case "v": return (CGKeyCode(kVK_ANSI_V), flag)
        case "w": return (CGKeyCode(kVK_ANSI_W), flag)
        case "x": return (CGKeyCode(kVK_ANSI_X), flag)
        case "y": return (CGKeyCode(kVK_ANSI_Y), flag)
        case "z": return (CGKeyCode(kVK_ANSI_Z), flag)
        case "0": return (CGKeyCode(kVK_ANSI_0), [])
        case "1": return (CGKeyCode(kVK_ANSI_1), [])
        case "2": return (CGKeyCode(kVK_ANSI_2), [])
        case "3": return (CGKeyCode(kVK_ANSI_3), [])
        case "4": return (CGKeyCode(kVK_ANSI_4), [])
        case "5": return (CGKeyCode(kVK_ANSI_5), [])
        case "6": return (CGKeyCode(kVK_ANSI_6), [])
        case "7": return (CGKeyCode(kVK_ANSI_7), [])
        case "8": return (CGKeyCode(kVK_ANSI_8), [])
        case "9": return (CGKeyCode(kVK_ANSI_9), [])
        case " ": return (CGKeyCode(kVK_Space), [])
        default: return nil
        }
    }
}
