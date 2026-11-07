import Foundation

/// UserDefaults supports concurrent reads. The settings window owns writes on the main actor.
public struct RegisteredEntitySettings: @unchecked Sendable {
    private static let key = "registeredEntityNames"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var names: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    @MainActor
    @discardableResult
    public func save(_ input: String, replacing original: String? = nil) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = name.hasSuffix("+") ? name.dropLast() : name[...]
        guard !stem.isEmpty, stem.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw EditError.invalidName
        }

        var updated = names
        if name != original, RegisteredEntityReading.builtInNames.contains(name) || updated.contains(name) {
            throw EditError.duplicateName
        }
        if let original {
            guard let index = updated.firstIndex(of: original) else { throw EditError.missingName }
            updated[index] = name
        } else {
            updated.append(name)
        }
        defaults.set(updated, forKey: Self.key)
        return name
    }

    @MainActor
    public func remove(_ name: String) throws {
        var updated = names
        guard let index = updated.firstIndex(of: name) else { throw EditError.missingName }
        updated.remove(at: index)
        defaults.set(updated, forKey: Self.key)
    }

    private enum EditError: LocalizedError {
        case invalidName, duplicateName, missingName

        var errorDescription: String? {
            switch self {
            case .invalidName: "영문 이름을 입력해 주세요. +는 끝에 한 번 붙일 수 있습니다."
            case .duplicateName: "이미 등록된 이름입니다."
            case .missingName: "이 이름은 이미 변경되었거나 삭제되었습니다."
            }
        }
    }
}
