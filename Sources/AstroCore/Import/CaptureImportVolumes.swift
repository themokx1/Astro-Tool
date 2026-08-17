import Foundation

/// One mounted volume the card-import wizard's Source step can offer --
/// e.g. an ASI Air's storage, a Canon SD card, any other external/network
/// mount. Never the library's own volume, and never a boot-volume system
/// area (see `ImportSourceVolumeLister.filter`).
public struct ImportSourceVolume: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Lists mounted volumes for the wizard's Source step, excluding the
/// library's own volume and every boot-volume system area (`/System/
/// Volumes/...`, the synthetic `/` firmlink root, ...) -- only genuinely
/// separate mounts (external drives, SD card readers, network shares) ever
/// show up under `/Volumes/`, which is what this filters down to.
public enum ImportSourceVolumeLister {
    /// The pure, decidable half: given a raw list of candidate `(name,
    /// path)` mount points (as `FileManager.mountedVolumeURLs` would report
    /// them) and the library's own volume path, returns exactly the ones
    /// the Source step should offer. Split out from `listMountedVolumes`
    /// below so this can be unit-tested without a real, live set of mounted
    /// volumes.
    ///
    /// - Only paths under `/Volumes/` are ever offered -- excludes the boot
    ///   volume's own synthetic mounts (`/`, `/System/Volumes/Data`, `/
    ///   System/Volumes/VM`, ...), none of which name a genuinely separate
    ///   external/network volume a user could "plug in".
    /// - The library's own volume (`libraryVolumePath`) is excluded --
    ///   re-offering the volume the library already lives on as an import
    ///   SOURCE is never useful and, if the library sits on an external
    ///   drive, would otherwise show up as a confusing extra entry.
    /// - Deduplicated and sorted by display name.
    public static func filter(
        candidates: [ImportSourceVolume],
        libraryVolumePath: String
    ) -> [ImportSourceVolume] {
        let normalizedLibraryPath = standardized(libraryVolumePath)
        var seen = Set<String>()
        var results: [ImportSourceVolume] = []
        for candidate in candidates {
            let standardizedPath = standardized(candidate.path)
            guard standardizedPath.hasPrefix("/Volumes/") else { continue }
            guard standardizedPath != normalizedLibraryPath else { continue }
            guard seen.insert(standardizedPath).inserted else { continue }
            results.append(ImportSourceVolume(name: candidate.name, path: standardizedPath))
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The live half: asks `FileManager` for every currently mounted volume,
    /// then applies `filter(candidates:libraryVolumePath:)` against the
    /// volume `libraryRootURL` itself lives on.
    public static func listMountedVolumes(libraryRootURL: URL) -> [ImportSourceVolume] {
        let fm = FileManager.default
        let mounted = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        let candidates = mounted.map { url -> ImportSourceVolume in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            return ImportSourceVolume(name: name, path: url.standardizedFileURL.path)
        }
        let libraryVolumePath = (try? libraryRootURL.resourceValues(forKeys: [.volumeURLKey]))?
            .volume?.standardizedFileURL.path ?? "/"
        return filter(candidates: candidates, libraryVolumePath: libraryVolumePath)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
