import Testing
@testable import AstroCore

@Test func filterOnlyOffersVolumesUnderSlashVolumes() {
    let candidates = [
        ImportSourceVolume(name: "Macintosh HD", path: "/"),
        ImportSourceVolume(name: "Data", path: "/System/Volumes/Data"),
        ImportSourceVolume(name: "ASIAIR", path: "/Volumes/ASIAIR"),
        ImportSourceVolume(name: "EOS_R8", path: "/Volumes/EOS_R8"),
    ]
    let result = ImportSourceVolumeLister.filter(candidates: candidates, libraryVolumePath: "/")

    #expect(result.map(\.name) == ["ASIAIR", "EOS_R8"])
}

@Test func filterExcludesTheLibrarysOwnVolume() {
    let candidates = [
        ImportSourceVolume(name: "AstroLibraryDrive", path: "/Volumes/AstroLibraryDrive"),
        ImportSourceVolume(name: "ASIAIR", path: "/Volumes/ASIAIR"),
    ]
    let result = ImportSourceVolumeLister.filter(candidates: candidates, libraryVolumePath: "/Volumes/AstroLibraryDrive")

    #expect(result.map(\.name) == ["ASIAIR"])
}

@Test func filterDeduplicatesAndSortsByName() {
    let candidates = [
        ImportSourceVolume(name: "Zulu", path: "/Volumes/Zulu"),
        ImportSourceVolume(name: "Alpha", path: "/Volumes/Alpha"),
        ImportSourceVolume(name: "Alpha (dup path)", path: "/Volumes/Alpha"),
    ]
    let result = ImportSourceVolumeLister.filter(candidates: candidates, libraryVolumePath: "/")

    #expect(result.map(\.path) == ["/Volumes/Alpha", "/Volumes/Zulu"])
    #expect(result.count == 2)
}
