import Foundation

public enum TerminalControlKeyStoreLoadResult: Equatable {
    case uninitialized
    case controls([TerminalControlKey])
    case malformed
}

/// A narrow persistence boundary for the global, user-configured Control Keys.
public struct TerminalControlKeyStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> TerminalControlKeyStoreLoadResult {
        guard defaults.object(forKey: key) != nil else { return .uninitialized }
        guard let data = defaults.data(forKey: key),
              let controls = try? JSONDecoder().decode([TerminalControlKey].self, from: data) else {
            return .malformed
        }
        return .controls(controls)
    }

    public func save(_ controls: [TerminalControlKey]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(controls) else { return }
        defaults.set(data, forKey: key)
    }
}
