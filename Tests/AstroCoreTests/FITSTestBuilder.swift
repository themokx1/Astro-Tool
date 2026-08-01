import Foundation

/// Shared FITS header byte-builder used by `FITSReaderTests` and
/// `ScannerTests` (and anywhere else that needs a hand-built FITS file):
/// turns a list of 80-char card lines into the raw bytes of one FITS
/// header, padded out to the next 2880-byte block boundary exactly like a
/// real FITS file on disk.

/// Pads a single FITS card line to exactly 80 characters. Callers pass the
/// full card text (keyword + `= ` + value + optional `/ comment`); this only
/// adds the trailing spaces every real FITS card is padded with.
func card(_ s: String) -> String {
    precondition(s.count <= 80, "card text too long (\(s.count) chars): \(s)")
    return s + String(repeating: " ", count: 80 - s.count)
}

/// Builds the raw bytes of one FITS header (or header + fake data, if the
/// caller appends extra `Data` afterwards) from an explicit list of 80-char
/// card lines, padded out to the next 2880-byte block boundary with ASCII
/// spaces — exactly what a real FITS header looks like on disk. Callers are
/// responsible for including `END` in `cards` when they want a well-formed
/// header (some tests deliberately omit it).
func buildHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(card).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}
