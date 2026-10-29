import AppKit
import Carbon

@MainActor private final class State {
    var source: String
    var secure = false
    var sudoPassword = false
    var reads = 0
    var selected: [String] = []
    var entries = 0
    var restorations = 0
    var time: TimeInterval = 0
    init(_ source: String) { self.source = source }
    func monitor(_ owner: String) -> DirectSecureInputSource {
        DirectSecureInputSource(sourceID: owner, entering: { self.entries += 1 }, restored: { self.restorations += 1 },
            isSecure: { self.secure || self.sudoPassword },
            currentSource: { self.reads += 1; return self.source },
            selectSource: { self.selected.append($0); self.source = $0 }, now: { self.time })
    }
    func settleExit(_ monitor: DirectSecureInputSource) {
        monitor.check()
        time += 0.21
        monitor.check()
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "DirectSecureInputQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main private struct DirectSecureInputQA {
    @MainActor static func main() {
        do {
            try run(owner: "com.yeop.inputmethod.Hannyeong")
            try run(owner: "com.yeop.inputmethod.HannyeongDirectSource")
            print("PASS native and Direct shared secure input QA (mock sources; no real source changes, keys or text)") }
        catch { fputs("Direct secure input QA failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run(owner: String) throws {
        let abc = "com.apple.keylayout.ABC"
        do {
            let s = State(owner), m = s.monitor(owner)
            s.sudoPassword = true; m.check()
            try require(s.source == abc, "Sudo password without OS secure input did not select ABC")
            s.secure = true; s.sudoPassword = false; m.check()
            try require(s.source == abc, "OS secure input ended the sudo-owned episode early")
            s.secure = false; s.settleExit(m)
            try require(s.source == owner && s.entries == 1, "Combined password states did not restore Direct once")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            for _ in 0..<10_000 { m.check() }
            try require(s.reads == 1 && s.selected.isEmpty, "Idle polling queried input sources or changed the source")
            for cycle in 1...2 {
                s.secure = true; m.check(); m.sourceChanged()
                try require(s.source == abc && m.isTemporaryABC(abc), "Secure entry did not select temporary ABC")
                let reads = s.reads
                for _ in 0..<10_000 { m.check() }
                try require(s.reads == reads, "Unchanged secure ticks queried sources")
                s.secure = false; s.settleExit(m); m.sourceChanged()
                try require(s.source == owner && s.entries == cycle && !m.isTemporaryABC(abc), "Secure exit did not restore Direct once")
            }
            try require(s.selected == [abc, owner, abc, owner], "A secure transition was repeated")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            s.source = abc; s.secure = true; m.sourceChanged()
            try require(m.isTemporaryABC(abc) && s.selected.isEmpty, "System ABC selection lost Direct ownership")
            s.secure = false; s.settleExit(m)
            try require(s.source == owner && s.selected == [owner], "System-selected ABC was not restored to Direct")
        }
        for original in [abc, owner == "com.yeop.inputmethod.Hannyeong" ? "com.yeop.inputmethod.HannyeongDirectSource" : "com.yeop.inputmethod.Hannyeong"] {
            let s = State(original), m = s.monitor(owner)
            s.secure = true; m.check(); s.secure = false; s.settleExit(m)
            try require(s.source == original && s.selected.isEmpty && s.entries == 0, "Direct changed an unrelated input source")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            s.secure = true; m.check()
            s.source = "org.youknowone.inputmethod.Gureum.han2"; m.sourceChanged()
            s.secure = false; s.settleExit(m)
            try require(s.source == "org.youknowone.inputmethod.Gureum.han2" && s.selected == [abc], "Secure exit overrode a user's other source selection")
        }
        do {
            let s = State(abc), m = s.monitor(owner)
            s.secure = true; m.check(); s.source = owner; m.sourceChanged()
            try require(s.source == abc && s.entries == 1, "Selecting Direct during secure input did not select ABC")
            s.secure = false; s.settleExit(m)
            try require(s.source == owner, "Direct selected during secure input was not restored")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            s.secure = true; m.check()
            s.secure = false; m.check()
            try require(s.source == abc && m.isTemporaryABC(abc) && s.restorations == 0,
                        "Secure exit was completed before the login transition settled")
            s.time = 0.05; s.source = owner; m.sourceChanged()
            s.time = 0.075; s.source = abc; m.sourceChanged()
            s.time = 0.25; m.check()
            try require(s.source == abc && s.restorations == 0, "The final login source change was not allowed to settle")
            s.time = 0.3; m.check(); m.sourceChanged()
            try require(s.source == owner && s.restorations == 1 && s.selected == [abc, owner],
                        "A delayed ABC change during Enter login lost Hannyeong restoration")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            s.secure = true; m.check()
            s.secure = false; m.check()
            s.time = 0.1; s.secure = true; m.check()
            s.time = 0.25; m.check()
            try require(s.source == abc && s.restorations == 0 && s.entries == 1,
                        "A brief secure-input release completed or split the password episode")
            s.secure = false; s.settleExit(m)
            try require(s.source == owner && s.restorations == 1, "The settled secure exit did not resume typing once")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            s.secure = true; m.check()
            s.secure = false; m.check()
            s.source = "org.youknowone.inputmethod.Gureum.han2"; m.sourceChanged()
            s.time = 1; m.check()
            try require(s.source == "org.youknowone.inputmethod.Gureum.han2" && s.restorations == 0 && s.selected == [abc],
                        "Pending password restoration overrode a different input source")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            s.secure = true; m.check()
            s.secure = false; s.source = owner; s.settleExit(m)
            try require(s.selected == [abc] && s.restorations == 1,
                        "A source already restored by macOS was selected again or did not resume typing")
        }
        do {
            let s = State(owner), m = s.monitor(owner)
            let mode = RunLoop.Mode("DirectSecureInputQA")
            CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode.rawValue as CFString))
            m.start(); defer { m.stop() }
            s.secure = true
            let entryDeadline = Date().addingTimeInterval(1)
            while s.source != abc && Date() < entryDeadline { RunLoop.main.run(mode: mode, before: entryDeadline) }
            try require(s.source == abc, "Secure monitor did not run in a common tracking mode")
            s.secure = false
            s.time += 1
            m.check()
            s.time += 1
            let exitDeadline = Date().addingTimeInterval(1)
            while s.source != owner && Date() < exitDeadline { RunLoop.main.run(mode: mode, before: exitDeadline) }
            try require(s.source == owner, "Secure exit was not observed in a common tracking mode")
        }
    }
}
