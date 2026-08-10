import Foundation

/// A deliberately narrow, privacy-safe support snapshot.
///
/// This type cannot carry paths, file names, target names, coordinates,
/// notes, FITS headers, bookmarks, or free-form error messages. Support
/// exports therefore stay safe by construction instead of trying to redact
/// an arbitrary database dump after the fact.
public struct SupportDiagnostics: Equatable, Sendable {
    public struct RecentOperation: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case scan
            case audit
            case quality
            case planning
            case export
            case configuration
            case analysis
            case other

            fileprivate var displayName: String {
                switch self {
                case .scan: "Beolvasás"
                case .audit: "Audit"
                case .quality: "Minőségmérés"
                case .planning: "Tervezés"
                case .export: "Exportálás"
                case .configuration: "Beállítás"
                case .analysis: "Elemzés"
                case .other: "Egyéb művelet"
                }
            }
        }

        public var date: Date
        public var kind: Kind
        public var succeeded: Bool

        public init(date: Date, kind: Kind, succeeded: Bool) {
            self.date = date
            self.kind = kind
            self.succeeded = succeeded
        }
    }

    public var generatedAt: Date
    public var productVersion: String
    public var build: String
    public var operatingSystem: String
    public var architecture: String
    public var databaseSchemaVersion: Int?
    public var libraryConnected: Bool
    public var targetCount: Int
    public var sessionCount: Int
    public var filterProfileCount: Int
    public var sensorProfileCount: Int
    public var weatherEnabled: Bool
    public var recentOperations: [RecentOperation]

    public init(
        generatedAt: Date = Date(),
        productVersion: String = ProductInfo.version,
        build: String = ProductInfo.build,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: String = SupportDiagnostics.currentArchitecture,
        databaseSchemaVersion: Int?,
        libraryConnected: Bool,
        targetCount: Int,
        sessionCount: Int,
        filterProfileCount: Int,
        sensorProfileCount: Int,
        weatherEnabled: Bool,
        recentOperations: [RecentOperation]
    ) {
        self.generatedAt = generatedAt
        self.productVersion = productVersion
        self.build = build
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.databaseSchemaVersion = databaseSchemaVersion
        self.libraryConnected = libraryConnected
        self.targetCount = max(0, targetCount)
        self.sessionCount = max(0, sessionCount)
        self.filterProfileCount = max(0, filterProfileCount)
        self.sensorProfileCount = max(0, sensorProfileCount)
        self.weatherEnabled = weatherEnabled
        self.recentOperations = Array(recentOperations.prefix(10))
    }

    public var plainText: String {
        var lines = [
            "AstroTool támogatási diagnosztika",
            "Készült: \(Self.timestamp(generatedAt))",
            "AstroTool \(productVersion) (\(build))",
            "Rendszer: \(operatingSystem)",
            "Architektúra: \(architecture)",
            "Adatbázisséma: \(databaseSchemaVersion.map(String.init) ?? "nincs megnyitva")",
            "Képkönyvtár kapcsolódik: \(libraryConnected ? "igen" : "nem")",
            "Célpontok: \(targetCount)",
            "Sessionök: \(sessionCount)",
            "Szűrőprofilok: \(filterProfileCount)",
            "Szenzorprofilok: \(sensorProfileCount)",
            "Időjárás: \(weatherEnabled ? "engedélyezve" : "kikapcsolva")",
            "",
            "Legutóbbi műveletek (legfeljebb 10, tartalom nélkül):",
        ]

        if recentOperations.isEmpty {
            lines.append("— nincs ebben az alkalmazásindításban")
        } else {
            lines.append(contentsOf: recentOperations.map { operation in
                let status = operation.succeeded ? "sikeres" : "sikertelen"
                return "\(Self.timestamp(operation.date)) — \(operation.kind.displayName) — \(status)"
            })
        }

        lines += [
            "",
            "Adatvédelmi megjegyzés: ez a fájl nem tartalmaz könyvtárútvonalat, fájlnevet, célpontot, koordinátát, jegyzetet, FITS-fejlécet vagy hibaüzenetet.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    public var suggestedFilename: String {
        "AstroTool-diagnostics-\(Self.filenameDate(generatedAt)).txt"
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "ismeretlen"
        #endif
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func filenameDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
