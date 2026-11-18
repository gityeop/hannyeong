import AppKit
import Carbon
import HannyeongInputRuntime

private final class SavePanelView: CoordinatorView {
    override func bundleIdentifier() -> String { "com.apple.appkit.xpc.openAndSavePanelService" }
}

@main struct CoordinatorQA {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard !IsSecureEventInputEnabled() else {
            fputs("ERROR secure input is active during coordinator QA\n", stderr)
            exit(2)
        }
        UserDefaults.standard.register(defaults: [CompositionPreviewSettings.liveEnabledKey: true])
        let first = CoordinatorView(frame: .zero)
        let second = CoordinatorView(frame: .zero)
        let firstOutput = NativeNotionOutput(client: first, clientOwner: .openAI)
        let secondOutput = NativeNotionOutput(client: second, clientOwner: .openAI)
        let engine = NativeInputEngine()
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: 0, context: nil, characters: "d",
                                   charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
        engine.prepare()
        engine.refreshConfiguration(savePanel: NativeSheetReplacement(client: first))
        guard engine.handleNative(event, output: firstOutput), first.string == "ㅇ" else {
            fail("initial client A key was not consumed")
        }
        let panel = SavePanelView(frame: .zero)
        guard NativeSheetReplacement(client: first) == nil,
              let savePanel = NativeSheetReplacement(client: panel) else {
            fail("only the save panel may register a filename replacement target")
        }
        let resets = TypingEngine.latest.resetCount
        engine.refreshConfiguration(savePanel: savePanel)
        engine.refreshConfiguration(savePanel: NativeSheetReplacement(client: second))
        guard engine.handleNative(event, output: firstOutput), first.string == "ㅇㅇ", second.string.isEmpty else {
            fail("client B metadata activation made client A's next key pass through")
        }
        guard TypingEngine.latest.resetCount == resets else {
            fail("client B metadata activation reset client A's live composition")
        }
        guard engine.handleNative(event, output: secondOutput), second.string == "ㅇ" else {
            fail("actual client B key did not acquire output ownership")
        }
        let secondResets = TypingEngine.latest.resetCount
        engine.deactivateNativeOutput(firstOutput)
        guard engine.handleNative(event, output: secondOutput), second.string == "ㅇㅇ",
              first.string == "ㅇㅇ", TypingEngine.latest.resetCount == secondResets else {
            fail("late client A deactivation disturbed client B")
        }
        engine.close()
        print("PASS real NativeInputEngine preserves A through B metadata activation, transfers on B key, and ignores late A deactivation")
    }

    static func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
