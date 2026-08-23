import Foundation
import Testing
@testable import AstroApplication

@Test func v4BriefingChecklistWithoutCompletionKeyDecodesAsIncomplete() throws {
    let json = #"""
    {
      "id":"00000000-0000-0000-0000-000000000001",
      "revision":4,
      "savedAt":"2026-08-23T00:00:00Z",
      "nightDate":null,
      "arrival":null,
      "departure":null,
      "site":null,
      "setup":null,
      "powerRuntimeHours":null,
      "weather":{"missing":{"reason":"No weather data"}},
      "targets":[],
      "checklist":[{"id":"setup","title":"Setup","items":[{"id":"mount","title":"Mount","explanation":null,"isVisible":true,"isBuiltIn":true}]}],
      "notes":"",
      "language":"hu"
    }
"""#

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let draft = try decoder.decode(NightBriefingDraft.self, from: Data(json.utf8))

    #expect(draft.checklist[0].items[0].isCompleted == false)
}

@Test func briefingChecklistCompletionRoundTripsWhenPresent() throws {
    let item = BriefingChecklistItem(id: "mount", title: "Mount", isCompleted: true)
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(BriefingChecklistItem.self, from: data)
    #expect(decoded.isCompleted)
}
