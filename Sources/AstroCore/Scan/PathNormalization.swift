import Foundation

/// Unicode-normalization helpers for a file's relative-path DB identity.
///
/// A library that has moved between filesystems (old HFS+ -> APFS, or over
/// SMB) can end up with the SAME accented file name stored in two different
/// Unicode normalization forms: NFD (HFS+'s own on-disk decomposed form,
/// e.g. `"o" + combining diaeresis`) vs NFC (APFS/SMB's precomposed form,
/// e.g. a single `"ő"` code point). Swift's own `String`/`Set<String>`
/// compare by Unicode CANONICAL equivalence, so NFD and NFC spellings of the
/// same name compare EQUAL there -- but SQLite's `TEXT` comparison (`WHERE
/// path = ?`, a `PRIMARY KEY`/`UNIQUE` index) is byte-wise, so the two
/// normalization forms are two different rows to the database. Without a
/// single canonical form chosen at the point a path enters the DB, and a
/// byte-wise (not Swift-canonical) staleness check when retiring rows no
/// longer seen, a library that changes normalization form silently
/// double-counts every accented path: a fresh NFC row gets inserted (SQLite
/// couldn't find the existing NFD row to update) while the stale NFD row
/// never gets marked missing (Swift's `Set.contains` treats it as "still
/// present" even though its bytes never actually matched).
public enum PathNormalization {
    /// The single canonical (NFC, precomposed) form every filesystem-derived
    /// relative path should be converted to before it becomes part of a
    /// file's DB identity -- inserted into `files.path`, looked up via
    /// `Database.file(path:)`, or added to a scan's `seen` set. Idempotent:
    /// a path that's already NFC (the overwhelmingly common case on a
    /// modern APFS/SMB library) round-trips unchanged.
    public static func canonical(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// A byte-wise membership set built from already-canonicalized paths,
    /// for checking whether a path read back from the DB (which may still
    /// be in a STALE, pre-normalization-fix form) has a byte-exact match
    /// among paths seen in the current scan. Deliberately NOT a
    /// `Set<String>`: Swift's own set/string equality is Unicode-canonical,
    /// which would treat a stale NFD row as "the same" as today's NFC path
    /// even though their bytes differ -- exactly the false-positive
    /// membership that let a stale row survive `markMissing` uncaught.
    public static func byteSet(_ paths: some Sequence<String>) -> Set<Data> {
        Set(paths.map { Data($0.utf8) })
    }

    /// Byte-wise (not Unicode-canonical) membership check of `path` against
    /// a set built by `byteSet(_:)`.
    public static func containsByteWise(_ path: String, in byteSet: Set<Data>) -> Bool {
        byteSet.contains(Data(path.utf8))
    }
}
