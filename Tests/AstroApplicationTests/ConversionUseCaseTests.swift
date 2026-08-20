@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct ConversionUseCaseTests {
    @Test("Converter is scoped to exactly one session and defaults logical")
    func oneSessionLogicalPreview() async throws {
        let plan = try await ConversionUseCase.fixture().plan(sessionID: .ic1396)

        #expect(plan.scope.sessionCount == 1)
        #expect(plan.mode == .logical)
        #expect(plan.moves.isEmpty)
        #expect(plan.proposedSeries.map(\.exposureSeconds).sorted() == [5, 30, 120, 300])
    }

    @Test("Physical conversion is never implicitly authorized")
    func physicalNeedsExplicitAuthorization() async throws {
        let useCase = ConversionUseCase.fixture()
        let plan = try await useCase.plan(sessionID: .ic1396, mode: .physical)

        #expect(!plan.canApply)
        #expect(plan.authorizationMessage != nil)
    }

    @Test("Production converter discovers sessions and exposure groups from the external index")
    func productionIndexPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL, filter TEXT);
        INSERT INTO files VALUES(1,'sessions/IC_1396/2026-08-08/lights/a.fit','sessions','IC_1396','2026-08-08','light',0);
        INSERT INTO files VALUES(2,'sessions/IC_1396/2026-08-08/lights/b.fit','sessions','IC_1396','2026-08-08','light',0);
        INSERT INTO files VALUES(3,'sessions/IC_1396/2026-08-08/flats/f.fit','sessions','IC_1396','2026-08-08','flat',0);
        INSERT INTO fits_meta VALUES(1,120,'SV220');
        INSERT INTO fits_meta VALUES(2,300,'SV220');
        """)

        let useCase = ConversionUseCase(indexDatabaseForTesting: index)
        let sessions = try await useCase.availableSessions()
        let preview = try await useCase.plan(sessionID: sessions[0])

        #expect(sessions == [.init(target: "IC_1396", date: "2026-08-08")])
        #expect(preview.proposedSeries.map(\.exposureSeconds) == [120, 300])
        #expect(preview.proposedSeries.map(\.frameCount) == [1, 1])
        #expect(preview.proposedSeries.allSatisfy { $0.title.contains("SV220") })
        #expect(preview.moves.isEmpty)
    }
}
