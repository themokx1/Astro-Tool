import Foundation

public struct PreferenceMigrationResult: Equatable, Sendable {
    public var copiedKeys: [String]
    public var preservedKeys: [String]
    public var rejectedKeys: [String]
    public var alreadyCompleted: Bool

    public init(
        copiedKeys: [String] = [],
        preservedKeys: [String] = [],
        rejectedKeys: [String] = [],
        alreadyCompleted: Bool = false
    ) {
        self.copiedKeys = copiedKeys
        self.preservedKeys = preservedKeys
        self.rejectedKeys = rejectedKeys
        self.alreadyCompleted = alreadyCompleted
    }
}

/// Copies a deliberately narrow set of preferences from the pre-1.0 bundle
/// domain. The source is never modified, current values always win, and a
/// marker makes the operation safe to call on every launch.
public enum PreferenceMigration {
    public static func migrate(
        legacyValues: [String: Any],
        into current: UserDefaults,
        allowedKeys: Set<String>,
        markerKey: String
    ) -> PreferenceMigrationResult {
        guard !current.bool(forKey: markerKey) else {
            return PreferenceMigrationResult(alreadyCompleted: true)
        }

        var result = PreferenceMigrationResult()
        for key in allowedKeys.sorted() {
            guard let value = legacyValues[key] else { continue }
            if current.object(forKey: key) != nil {
                result.preservedKeys.append(key)
                continue
            }
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
                result.rejectedKeys.append(key)
                continue
            }
            current.set(value, forKey: key)
            result.copiedKeys.append(key)
        }
        current.set(true, forKey: markerKey)
        return result
    }

    @discardableResult
    public static func migratePersistentDomain(
        named legacyDomain: String,
        into current: UserDefaults,
        allowedKeys: Set<String>,
        markerKey: String,
        domainReader: UserDefaults = .standard
    ) -> PreferenceMigrationResult {
        migrate(
            legacyValues: domainReader.persistentDomain(forName: legacyDomain) ?? [:],
            into: current,
            allowedKeys: allowedKeys,
            markerKey: markerKey
        )
    }
}
