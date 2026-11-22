import AppKit
import Carbon.HIToolbox
import WebKit

/// Native mouse and keyboard events sent straight to a web view, so pages get
/// trusted events (`isTrusted`) exactly as from the user's own mouse and keys.
/// The events go to the view rather than through `NSWindow.sendEvent`, which
/// would activate and reorder windows.
@MainActor
enum WebViewInput {
    enum MouseButton: String {
        case left, right, middle
    }

    /// `point` is in the web view's own coordinates (top-left origin, points).
    static func click(_ webView: WKWebView, at point: CGPoint, button: MouseButton, clickCount: Int) throws {
        let location = try windowLocation(of: point, in: webView)
        let (downType, upType): (NSEvent.EventType, NSEvent.EventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        case .middle: (.otherMouseDown, .otherMouseUp)
        }
        move(webView, to: location)
        for count in 1...clickCount {
            let down = try mouseEvent(downType, at: location, in: webView, clickCount: count, button: button)
            let up = try mouseEvent(upType, at: location, in: webView, clickCount: count, button: button)
            switch button {
            case .left:
                webView.mouseDown(with: down)
                webView.mouseUp(with: up)
            case .right:
                webView.rightMouseDown(with: down)
                webView.rightMouseUp(with: up)
            case .middle:
                webView.otherMouseDown(with: down)
                webView.otherMouseUp(with: up)
            }
        }
    }

    static func hover(_ webView: WKWebView, at point: CGPoint) throws {
        move(webView, to: try windowLocation(of: point, in: webView))
    }

    struct Key {
        var keyCode: UInt16
        var characters: String
        var charactersIgnoringModifiers: String
        /// Typed with Shift on a US keyboard ("A", "!").
        var needsShift = false
    }

    enum KeyError: LocalizedError {
        case unknownKey(String)
        var errorDescription: String? {
            switch self {
            case .unknownKey(let name): "Unknown key \"\(name)\". Use a single character or a key name such as Enter, Tab, Escape, Backspace, ArrowDown or F5."
            }
        }
    }

    /// Presses and releases a key. Command chords never go through key
    /// equivalents: ones the page ignores would reach Bamboo's menus, so an
    /// agent's Command-Q would quit the browser. The page gets them as key
    /// events instead, and the standard editing chords run their command.
    static func press(_ name: String, modifiers: NSEvent.ModifierFlags, in webView: WKWebView) throws {
        let key = try key(named: name, shift: modifiers.contains(.shift))
        var flags = modifiers
        if key.needsShift {
            flags.insert(.shift)
        }
        let down = try keyEvent(.keyDown, key, flags, in: webView)
        let up = try keyEvent(.keyUp, key, flags, in: webView)
        if flags.contains(.command), let command = editingCommands[key.charactersIgnoringModifiers.lowercased()] {
            webView.tryToPerform(command, with: nil)
        } else {
            webView.keyDown(with: down)
        }
        webView.keyUp(with: up)
    }

    static func modifierFlags(_ names: [String]) throws -> NSEvent.ModifierFlags {
        try names.reduce(into: []) { flags, name in
            switch name {
            case "Shift": flags.insert(.shift)
            case "Control": flags.insert(.control)
            case "Alt": flags.insert(.option)
            case "Meta": flags.insert(.command)
            default: throw KeyError.unknownKey(name)
            }
        }
    }

    // MARK: - Private

    private static let editingCommands: [String: Selector] = [
        "a": #selector(NSText.selectAll(_:)),
        "c": #selector(NSText.copy(_:)),
        "x": #selector(NSText.cut(_:)),
        "v": #selector(NSText.paste(_:)),
    ]

    /// The character AppKit uses for a function key (arrows, F1, …).
    private static func function(_ code: Int) -> String {
        String(utf16CodeUnits: [UInt16(code)], count: 1)
    }

    private static let namedKeys: [String: Key] = {
        func key(_ code: Int, _ characters: String) -> Key {
            Key(keyCode: UInt16(code), characters: characters, charactersIgnoringModifiers: characters)
        }
        var keys: [String: Key] = [
            "Enter": key(kVK_Return, "\r"),
            "Return": key(kVK_Return, "\r"),
            "Tab": key(kVK_Tab, "\t"),
            "Escape": key(kVK_Escape, "\u{1B}"),
            "Backspace": key(kVK_Delete, "\u{7F}"),
            "Delete": key(kVK_ForwardDelete, function(NSDeleteFunctionKey)),
            "Space": key(kVK_Space, " "),
            " ": key(kVK_Space, " "),
            "ArrowLeft": key(kVK_LeftArrow, function(NSLeftArrowFunctionKey)),
            "ArrowRight": key(kVK_RightArrow, function(NSRightArrowFunctionKey)),
            "ArrowUp": key(kVK_UpArrow, function(NSUpArrowFunctionKey)),
            "ArrowDown": key(kVK_DownArrow, function(NSDownArrowFunctionKey)),
            "Home": key(kVK_Home, function(NSHomeFunctionKey)),
            "End": key(kVK_End, function(NSEndFunctionKey)),
            "PageUp": key(kVK_PageUp, function(NSPageUpFunctionKey)),
            "PageDown": key(kVK_PageDown, function(NSPageDownFunctionKey)),
        ]
        let functionKeyCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeyCodes.enumerated() {
            keys["F\(index + 1)"] = key(code, function(NSF1FunctionKey + index))
        }
        return keys
    }()

    /// ANSI key codes for the characters on a US keyboard; the second value
    /// is the character typed with Shift.
    private static let characterKeys: [Character: (code: Int, shifted: Character)] = [
        "a": (kVK_ANSI_A, "A"), "b": (kVK_ANSI_B, "B"), "c": (kVK_ANSI_C, "C"), "d": (kVK_ANSI_D, "D"),
        "e": (kVK_ANSI_E, "E"), "f": (kVK_ANSI_F, "F"), "g": (kVK_ANSI_G, "G"), "h": (kVK_ANSI_H, "H"),
        "i": (kVK_ANSI_I, "I"), "j": (kVK_ANSI_J, "J"), "k": (kVK_ANSI_K, "K"), "l": (kVK_ANSI_L, "L"),
        "m": (kVK_ANSI_M, "M"), "n": (kVK_ANSI_N, "N"), "o": (kVK_ANSI_O, "O"), "p": (kVK_ANSI_P, "P"),
        "q": (kVK_ANSI_Q, "Q"), "r": (kVK_ANSI_R, "R"), "s": (kVK_ANSI_S, "S"), "t": (kVK_ANSI_T, "T"),
        "u": (kVK_ANSI_U, "U"), "v": (kVK_ANSI_V, "V"), "w": (kVK_ANSI_W, "W"), "x": (kVK_ANSI_X, "X"),
        "y": (kVK_ANSI_Y, "Y"), "z": (kVK_ANSI_Z, "Z"),
        "1": (kVK_ANSI_1, "!"), "2": (kVK_ANSI_2, "@"), "3": (kVK_ANSI_3, "#"), "4": (kVK_ANSI_4, "$"),
        "5": (kVK_ANSI_5, "%"), "6": (kVK_ANSI_6, "^"), "7": (kVK_ANSI_7, "&"), "8": (kVK_ANSI_8, "*"),
        "9": (kVK_ANSI_9, "("), "0": (kVK_ANSI_0, ")"),
        "-": (kVK_ANSI_Minus, "_"), "=": (kVK_ANSI_Equal, "+"), "[": (kVK_ANSI_LeftBracket, "{"),
        "]": (kVK_ANSI_RightBracket, "}"), "\\": (kVK_ANSI_Backslash, "|"), ";": (kVK_ANSI_Semicolon, ":"),
        "'": (kVK_ANSI_Quote, "\""), ",": (kVK_ANSI_Comma, "<"), ".": (kVK_ANSI_Period, ">"),
        "/": (kVK_ANSI_Slash, "?"), "`": (kVK_ANSI_Grave, "~"),
    ]

    private static func key(named name: String, shift: Bool) throws -> Key {
        if let key = namedKeys[name] { return key }
        guard name.count == 1, let character = name.first else { throw KeyError.unknownKey(name) }
        let base = Character(character.lowercased())
        if let (code, shifted) = characterKeys[base] {
            let typed = character.isUppercase || shift ? shifted : base
            return Key(keyCode: UInt16(code), characters: String(typed), charactersIgnoringModifiers: String(base),
                       needsShift: character.isUppercase)
        }
        if let (code, base) = characterKeys.first(where: { $0.value.shifted == character }).map({ ($0.value.code, $0.key) }) {
            return Key(keyCode: UInt16(code), characters: String(character), charactersIgnoringModifiers: String(base), needsShift: true)
        }
        // Characters outside the US layout have no key code; the text still arrives.
        return Key(keyCode: 0, characters: name, charactersIgnoringModifiers: name)
    }

    private static func windowLocation(of point: CGPoint, in webView: WKWebView) throws -> NSPoint {
        guard webView.window != nil else { throw InputError.notInWindow }
        let viewPoint = webView.isFlipped ? point : CGPoint(x: point.x, y: webView.bounds.height - point.y)
        return webView.convert(viewPoint, to: nil)
    }

    private static func move(_ webView: WKWebView, to location: NSPoint) {
        guard let window = webView.window,
              let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return }
        webView.mouseMoved(with: event)
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType, at location: NSPoint, in webView: WKWebView, clickCount: Int, button: MouseButton
    ) throws -> NSEvent {
        guard let window = webView.window else { throw InputError.notInWindow }
        let isDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: isDown ? 1 : 0)
        else { throw InputError.eventCreationFailed }
        guard button == .middle else { return event }
        // The factory gives "other" buttons number 0; WebKit needs 2 for the middle button.
        guard let cgEvent = event.cgEvent else { throw InputError.eventCreationFailed }
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        guard let middle = NSEvent(cgEvent: cgEvent) else { throw InputError.eventCreationFailed }
        return middle
    }

    private static func keyEvent(
        _ type: NSEvent.EventType, _ key: Key, _ flags: NSEvent.ModifierFlags, in webView: WKWebView
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: webView.window?.windowNumber ?? 0, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false, keyCode: key.keyCode)
        else { throw InputError.eventCreationFailed }
        return event
    }

    enum InputError: LocalizedError {
        case notInWindow
        case eventCreationFailed
        var errorDescription: String? {
            switch self {
            case .notInWindow: "The tab's page isn't on screen or in the agent window."
            case .eventCreationFailed: "macOS could not create the input event."
            }
        }
    }
}
