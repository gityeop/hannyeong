import AppKit

/// Run against a controlled search field after typing the expected suffix through the installed IME.
@main
struct InputTargetQA {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 4, "usage: InputTargetQA <bundle ID> <expected suffix> <panel|active>")
        let host = try CommittedTextSelection.hostApplication(arguments[1])
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        precondition((activePID != host.processIdentifier) == (arguments[3] == "panel"),
                     "The fixture does not have the requested activation state")
        let owner = "input-target-qa"
        try CommittedInputEvents.shared.pause(owner: owner, hostBundleID: arguments[1])
        CommittedInputEvents.shared.cancel(owner: owner)
        let caret = try await CommittedTextSelection.confirmedCaret(expectedSuffix: arguments[2], hostBundleID: arguments[1])
        print("PASS input target: \(arguments[1]), mode=\(arguments[3]), caret=\(caret)")
    }
}
