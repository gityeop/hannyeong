import AppKit
import Carbon

// Runs against the installed, running input method. No keys or password values are read.
let hannyeong = "com.yeop.inputmethod.Hannyeong"
let abc = "com.apple.keylayout.ABC"

func currentSource() -> String {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

func select(_ id: String) {
    let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)
        .takeRetainedValue() as! [TISInputSource]
    precondition(!sources.isEmpty, "Missing QA input source: \(id)")
    precondition(TISSelectInputSource(sources[0]) == noErr)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 600, height: 150),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "한녕 보안 입력 전환 검사 — 암호를 입력하지 마세요"
let field = NSTextField(frame: NSRect(x: 20, y: 60, width: 560, height: 30))
window.contentView!.addSubview(field)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
window.makeFirstResponder(field)
let original = currentSource()
var actions: [() -> Void] = []
var assertions = 0

func expect(_ id: String, _ label: String) {
    precondition(currentSource() == id, "\(label): expected \(id), got \(currentSource())")
    assertions += 1
    print("PASS", label)
    fflush(stdout)
}

actions.append { select(hannyeong) }
for cycle in 1...2 {
    actions.append { precondition(EnableSecureEventInput() == noErr) }
    actions.append {
        expect(abc, "secure entry \(cycle)")
        precondition(DisableSecureEventInput() == noErr)
    }
    actions.append { expect(hannyeong, "restore \(cycle)") }
}
actions.append { select(abc) }
actions.append { precondition(EnableSecureEventInput() == noErr) }
actions.append {
    expect(abc, "ABC initially stays ABC")
    precondition(DisableSecureEventInput() == noErr)
}
actions.append { expect(abc, "ABC initially does not restore Hannyeong") }
actions.append {
    select(original)
    print("PASS total", assertions)
    app.terminate(nil)
}

func next() {
    guard !actions.isEmpty else { return }
    actions.removeFirst()()
    // TISSelectInputSource applies asynchronously to the active AppKit input context.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
app.run()
