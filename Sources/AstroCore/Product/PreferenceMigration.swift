import Foundation

public struct PreferenceMigrationResult: Equatable, Sendable {
    public var copiedKeys: [String]
    public var preservedKeys: [String]
    public var rejectedKeys: [String]
    public var alreadyCompleted: Bool
    public var targetDomainWasNotEmpty: Bool

    public init(
        copiedKeys: [String] = [],
        preservedKeys: [String] = [],
        rejectedKeys: [String] = [],
        alreadyCompleted: Bool = false,
        targetDomainWasNotEmpty: Bool = false
    ) {
        self.copiedKeys = copiedKeys
        self.preservedKeys = preservedKeys
        self.rejectedKeys = rejectedKeys
        self.alreadyCompleted = alreadyCompleted
        self.targetDomainWasNotEmpty = targetDomainWasNotEmpty
    }
}

/// Copies a deliberately narrow set of preferences from the pre-1.0 bundle
/// domain. The source is never modified, current values always win, and a
/// marker makes the operation safe to call on every launch.
public enum PreferenceMigration {
    /// Decides whether the user should be offered the one-time legacy import.
    /// A populated 1.0 domain is never overwritten, and unrelated legacy
    /// defaults are not enough to surface the choice.
    public static func shouldOffer(
        currentDomain: [String: Any],
        legacyDomain: [String: Any],
        allowedKeys: Set<String>,
        alreadyCompleted: Bool
    ) -> Bool {
        guard !alreadyCompleted, currentDomain.isEmpty else { return false }
        return !allowedKeys.isDisjoint(with: legacyDomain.keys)
    }

    public static func migrate(
        legacyValues: [String: Any],
        into current: UserDefaults,
        allowedKeys: Set<String>,
        markerKey: String,
        targetDomainWasEmpty: Bool
    ) -> PreferenceMigrationResult {
        guard !current.bool(forKey: markerKey) else {
            return PreferenceMigrationResult(alreadyCompleted: true)
        }
        guard targetDomainWasEmpty else {
            return PreferenceMigrationResult(targetDomainWasNotEmpty: true)
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
        domainReader: UserDefaults = .standard,
        targetDomainWasEmpty: Bool
    ) -> PreferenceMigrationResult {
        migrate(
            legacyValues: domainReader.persistentDomain(forName: legacyDomain) ?? [:],
            into: current,
            allowedKeys: allowedKeys,
            markerKey: markerKey,
            targetDomainWasEmpty: targetDomainWasEmpty
        )
    }
}
