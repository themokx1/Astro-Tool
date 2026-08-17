import Foundation
import Testing

// A binary-level gate for one specific, silent memory-safety hazard that no
// amount of source reading can catch.
//
// ## The hazard
//
// An `async` default argument (`provider: @escaping P = Type.production`)
// makes the compiler emit an implicit closure *and* its async function
// pointer record -- the `…Tu` symbol, whose second word is the size of the
// async context the CALLER must allocate -- with `weak private external`
// (`linkonce_odr`) linkage. That means the record is re-emitted into every
// translation unit that uses the default, and the linker keeps one
// arbitrary copy.
//
// Swift 6.3.3 emits those copies with DIFFERENT context sizes: the module
// that declares the default emits 16 bytes more than any client module
// does. The function body is a separate weak symbol, coalesced
// independently, so a link can end up pairing the large body with the small
// size record. The caller then allocates too small an async context via
// `swift_task_alloc`, the callee's resume funclet writes past the end of
// it, and the next `swift_task_dealloc` aborts the whole process with
// `freed pointer was not the last allocation`.
//
// That was observed here, not theorised: routing `NightRow.integrationSummary`
// through `AstroFormat.duration(seconds:)` shifted `NightsStore.swift.o`
// enough to flip which copy the linker kept, and
// `GlobalSearchStoreTests.searchesAcrossWorkflowObjects` began crashing the
// test binary 100% of the time on a clean build. `NightsStore.open`'s own
// machine code was byte-for-byte identical across the two builds -- only its
// address moved. Six symbols were diverging in that link at once
// (`NightsStore`, `GlobalSearchStore` x2, `HomeStore` x2,
// `SiteSettingsStore`).
//
// ## Why this has to be a binary gate
//
// The divergence exists only in the emitted object files. The source is
// legal, idiomatic, and looks completely harmless; which copy the linker
// keeps depends on object file layout, so the bug is invisible until an
// unrelated edit re-rolls the dice. A source scan cannot see any of that.
// This suite reads the built `.o` files instead and fails if one weak
// `…Tu` record carries two different context sizes.
//
// ## Fixing a failure
//
// Do not chase the symbol. Find the `async` default argument it belongs to
// and give it the shape the rest of this codebase now uses: take the
// parameter as `Optional` and resolve the production value inside the
// initializer body, which lives only in the declaring module, so no client
// TU emits a competing copy. See `NightsStore.init(metadataFactory:calendarProvider:)`.
@Suite("Async context sizes agree across translation units")
struct AsyncContextSizeGateTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every `.o` produced for this package, keyed by the LINK it belongs to.
    ///
    /// Grouping matters and getting it wrong is how this gate first went
    /// wrong (2026-08-17). It originally scanned all of `.build` flat, on the
    /// reasoning that a debug-only scan would stop gating release builds.
    /// But `.build` accumulates products from unrelated compilations:
    /// SwiftPM's debug objects live in `.build/<triple>/debug/...` while
    /// `build.sh` leaves an Xcode Release build in
    /// `.build/apple/.../Release/.../{arm64,x86_64}/...`. A Release
    /// whole-module build lays out an async context differently from a debug
    /// incremental one, and arm64 differs from x86_64 -- legitimately.
    ///
    /// Compared flat, those differences read as the ODR bug, so the gate
    /// began failing the moment anyone ran `build.sh`, naming four files
    /// whose fix was already in the source. A gate that cries wolf gets
    /// switched off, and this one guards a bug that silently corrupts the
    /// task allocator, so its false positives are expensive.
    ///
    /// Two object files are only comparable if the same linker could pair
    /// them: same configuration, same architecture. The key below is that
    /// link identity, and the comparison happens strictly within a group.
    private func objectFiles() throws -> [URL] {
        let build = repositoryRoot.appendingPathComponent(".build")
        guard let enumerator = FileManager.default.enumerator(at: build, includingPropertiesForKeys: nil) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "o" {
            // `<Target>.build/` is SwiftPM's per-target object directory;
            // checked out dependencies build into the same tree and are not
            // ours to gate.
            guard url.pathComponents.contains(where: { $0.hasSuffix(".build") }) else { continue }
            guard !url.pathComponents.contains("checkouts") else { continue }
            results.append(url)
        }
        return results
    }

    /// `symbol name -> context size` for every weakly-defined async function
    /// pointer record in one Mach-O object file.
    ///
    /// An async function pointer record is two words: a relative pointer to
    /// the function, then the `UInt32` size of the async context. We read
    /// the second word. Parsed here directly rather than shelling out to
    /// `nm`/`otool`, which would mean several hundred subprocesses per run.
    private func asyncContextSizes(in object: URL) throws -> [String: UInt32] {
        let data = try Data(contentsOf: object)
        guard data.count > 32 else { return [:] }

        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                var value: UInt32 = 0
                withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + 4)])) }
                return value
            }
        }
        func u64(_ offset: Int) -> UInt64? {
            guard offset >= 0, offset + 8 <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                var value: UInt64 = 0
                withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + 8)])) }
                return value
            }
        }

        // 64-bit little-endian Mach-O only; anything else is not something
        // this toolchain produces for our targets, so skip rather than fail.
        guard u32(0) == 0xfeed_facf else { return [:] }
        guard let commandCount = u32(16) else { return [:] }

        struct Section { let address: UInt64; let size: UInt64; let fileOffset: UInt32; let isTextConst: Bool }
        var sections: [Section] = []
        var symbolTableOffset: Int?
        var symbolCount = 0
        var stringTableOffset: Int?
        var stringTableSize = 0

        var cursor = 32
        for _ in 0..<commandCount {
            guard let command = u32(cursor), let commandSize = u32(cursor + 4), commandSize >= 8 else { break }
            switch command {
            case 0x19: // LC_SEGMENT_64
                guard let sectionCount = u32(cursor + 64) else { break }
                var sectionCursor = cursor + 72
                for _ in 0..<sectionCount {
                    let sectionName = Self.fixedWidthName(data, at: sectionCursor, length: 16)
                    let segmentName = Self.fixedWidthName(data, at: sectionCursor + 16, length: 16)
                    guard let address = u64(sectionCursor + 32),
                          let size = u64(sectionCursor + 40),
                          let fileOffset = u32(sectionCursor + 48) else { break }
                    sections.append(Section(
                        address: address, size: size, fileOffset: fileOffset,
                        isTextConst: segmentName == "__TEXT" && sectionName == "__const"
                    ))
                    sectionCursor += 80
                }
            case 0x2: // LC_SYMTAB
                symbolTableOffset = u32(cursor + 8).map(Int.init)
                symbolCount = u32(cursor + 12).map(Int.init) ?? 0
                stringTableOffset = u32(cursor + 16).map(Int.init)
                stringTableSize = u32(cursor + 20).map(Int.init) ?? 0
            default:
                break
            }
            cursor += Int(commandSize)
        }

        guard let symbolTableOffset, let stringTableOffset, symbolCount > 0 else { return [:] }

        var sizes: [String: UInt32] = [:]
        for index in 0..<symbolCount {
            let entry = symbolTableOffset + index * 16
            guard let nameOffset = u32(entry),
                  entry + 16 <= data.count,
                  let descriptor = u32(entry + 4) else { break }
            let type = UInt8(descriptor & 0xff)
            let flags = UInt16((descriptor >> 16) & 0xffff)
            // N_TYPE == N_SECT (defined in a section) and N_WEAK_DEF set.
            guard type & 0x0e == 0x0e, flags & 0x0080 != 0 else { continue }
            guard let address = u64(entry + 8) else { continue }

            let start = stringTableOffset + Int(nameOffset)
            guard start < stringTableOffset + stringTableSize, start < data.count else { continue }
            guard let terminator = data[start...].firstIndex(of: 0),
                  let name = String(data: data[start..<terminator], encoding: .utf8) else { continue }
            guard name.hasSuffix("Tu") else { continue }

            guard let section = sections.first(where: {
                $0.isTextConst && address >= $0.address && address + 8 <= $0.address + $0.size
            }) else { continue }
            let recordOffset = Int(section.fileOffset) + Int(address - section.address)
            guard let contextSize = u32(recordOffset + 4) else { continue }
            sizes[name] = contextSize
        }
        return sizes
    }

    private static func fixedWidthName(_ data: Data, at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= data.count else { return "" }
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Which link an object belongs to: same configuration, same
    /// architecture. Objects from different groups are never compared,
    /// because different compilations legitimately size async contexts
    /// differently.
    static func linkIdentity(of object: URL) -> String {
        let parts = object.pathComponents
        // Xcode/`build.sh`: .build/apple/.../<Config>/<Target>.build/Objects-normal/<arch>/x.o
        if let objectsIndex = parts.firstIndex(of: "Objects-normal"), objectsIndex + 1 < parts.count {
            let arch = parts[objectsIndex + 1]
            let config = parts.first { ["Debug", "Release"].contains($0) } ?? "xcode"
            return "xcode/\(config)/\(arch)"
        }
        // SwiftPM: .build/<triple>/<config>/<Target>.build/x.o
        if let buildIndex = parts.firstIndex(of: ".build"), buildIndex + 2 < parts.count {
            return "swiftpm/\(parts[buildIndex + 1])/\(parts[buildIndex + 2])"
        }
        return "unknown"
    }

    /// The gate. One weak async function pointer record, one context size --
    /// anywhere in the package, in any configuration that has been built.
    @Test("No weak async function pointer record is emitted with two different context sizes")
    func asyncContextSizesAgreeAcrossTranslationUnits() throws {
        let objects = try objectFiles()
        // A gate that silently passes because it found nothing to inspect is
        // worse than no gate, so an empty scan is a failure with the command
        // that populates the tree.
        try #require(!objects.isEmpty, """
            No object files under .build -- this gate inspects compiler output, \
            so it only runs meaningfully under `swift test`. Run `swift build --build-tests` first.
            """)

        // Grouped by link identity -- see `objectFiles()`'s own comment for
        // why comparing across configurations or architectures produces
        // false positives rather than findings.
        var sizesByLinkAndSymbol: [String: [String: [String: UInt32]]] = [:]
        for object in objects {
            let link = Self.linkIdentity(of: object)
            for (symbol, size) in try asyncContextSizes(in: object) {
                sizesByLinkAndSymbol[link, default: [:]][symbol, default: [:]][object.lastPathComponent] = size
            }
        }

        var offenders: [(link: String, symbol: String, sizes: [String: UInt32])] = []
        for (link, bySymbol) in sizesByLinkAndSymbol {
            for (symbol, sizes) in bySymbol where Set(sizes.values).count > 1 {
                offenders.append((link, symbol, sizes))
            }
        }
        offenders.sort { ($0.link, $0.symbol) < ($1.link, $1.symbol) }

        let report = offenders.map { link, symbol, sizes in
            let copies = sizes.sorted { $0.value > $1.value }
                .map { "\($0.value) bytes in \($0.key)" }
                .joined(separator: ", ")
            return "\n  \(symbol)\n    [\(link)] \(copies)"
        }.joined()

        guard offenders.isEmpty else {
            Issue.record(Comment(rawValue: """
                One async context size per symbol -- two sizes for the same weak record means the \
                linker can pair a large function body with a small size record, so the callee \
                writes past its async context and corrupts the task allocator. Give the `async` \
                default argument behind each symbol below the `Optional` + resolve-in-initializer \
                shape (see this file's own header comment):\(report)
                """))
            return
        }
    }
}
