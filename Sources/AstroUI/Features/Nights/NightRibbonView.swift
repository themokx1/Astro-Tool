import AstroApplication
import SwiftUI

/// Renders `NightRibbonModel` (`AstroApplication`) as a horizontal band
/// chart -- astronomical twilight, Moon-up, target-visible, and actual
/// capture/gap spans, each its own thin proportional track sharing one time
/// axis, plus a caption line summarizing the capture span and its largest
/// gap. Mounted on `NightWorkspaceView`'s Overview tab (`NightWorkspaceView.
/// reportSections`).
///
/// Every track's width is a FRACTION of the available `GeometryReader`
/// width, never a fixed pixel span -- there is no horizontal scrolling
/// surface here to accidentally overflow (a night with a very long window
/// simply draws thinner segments, not a wider view).
///
/// Colors come from `AstroTokens.Color`'s five DATA-category tokens only
/// (`dataLight`/`dataStack`/`dataProcessed`/`dataCalibration`/
/// `dataUnclassified`), one per event kind, never a status token
/// (`ok`/`attention`/`critical`) -- this is a chart of WHAT happened, not a
/// verdict on it, the exact distinction `AstroTokensTests.
/// dataColorsAreNotStatus` gates.
struct NightRibbonView: View {
    let model: NightRibbonModel

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // `DATE-OBS` (and this ribbon's derived twilight/Moon/target
        // windows, all built on it) carries no timezone -- shown as the
        // camera's own clock reading, same convention `CaptureImportView.
        // timeOfDayFormatter` already documents, rather than shifting to
        // this Mac's local timezone.
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var axisStart: Date? { model.events.first?.start }

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            if let axisStart, model.durationSeconds > 0 {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    track(title: "Twilight", kind: .astronomicalTwilight, color: AstroTokens.Color.dataCalibration, axisStart: axisStart)
                    track(title: "Moon", kind: .moon, color: AstroTokens.Color.dataStack, axisStart: axisStart)
                    track(title: "Target", kind: .targetVisibility, color: AstroTokens.Color.dataProcessed, axisStart: axisStart)
                    captureTrack(axisStart: axisStart)
                }
                captionLine
            } else {
                ReportEmptyNote(text: "No timestamped events for this night.")
            }
        }
    }

    @ViewBuilder
    private func track(title: LocalizedStringKey, kind: NightRibbonEventKind, color: Color, axisStart: Date) -> some View {
        let segments = model.events.filter { $0.kind == kind }
        if !segments.isEmpty {
            RibbonTrack(title: title, segments: segments.map { ($0.start, $0.end, color) }, axisStart: axisStart, totalSeconds: model.durationSeconds)
        }
    }

    /// Capture and gap share one track (one row reading as "what the
    /// camera was doing"), unlike the three sky tracks above which each get
    /// their own row -- captures/gaps are the ONE pair that can never
    /// overlap in time by construction (`NightRibbonBuilder.captureEvents`
    /// walks them as strict alternating segments), so stacking them in one
    /// row loses no information a separate row pair would have shown.
    @ViewBuilder
    private func captureTrack(axisStart: Date) -> some View {
        let captures = model.events.filter { $0.kind == .capture }
        let gaps = model.events.filter { $0.kind == .gap }
        if !captures.isEmpty || !gaps.isEmpty {
            let segments = captures.map { ($0.start, $0.end, AstroTokens.Color.dataLight) }
                + gaps.map { ($0.start, $0.end, AstroTokens.Color.dataUnclassified) }
            RibbonTrack(title: "Capture", segments: segments, axisStart: axisStart, totalSeconds: model.durationSeconds)
        }
    }

    /// `"Capture HH:mm–HH:mm, N-minute gap at HH:mm"` (one gap), `"...,
    /// N gaps totaling M minutes"` (several), or `"Capture HH:mm–HH:mm"`
    /// alone (none) -- built as a real `Text` interpolation (not a
    /// verbatim string) so the surrounding words translate via hu.lproj
    /// while the times/counts stay untranslated data, same convention
    /// `CaptureImportView.timeSpanText` already establishes. `nil`
    /// capture window (no usable light had a parseable `DATE-OBS`) shows
    /// the honest fallback instead of a blank line.
    private var captionLine: Text {
        let captures = model.events.filter { $0.kind == .capture }
        let gaps = model.events.filter { $0.kind == .gap }
        guard let first = captures.first, let last = captures.last else {
            return Text("Frame timestamps unavailable.")
        }
        let start = Self.timeFormatter.string(from: first.start)
        let end = Self.timeFormatter.string(from: last.end)
        if gaps.isEmpty {
            return Text("Capture \(start)–\(end)")
        }
        if gaps.count == 1, let gap = gaps.first {
            // `String(...)`-wrapped (rather than a bare `Int` interpolation)
            // so `LocalizedStringKey`'s own format-specifier choice is
            // unambiguously `%@` -- matching exactly what `scripts/
            // extract-localizable-strings.swift`'s heuristic (which cannot
            // see the real compile-time type of a bare local) also infers
            // for it, so the extracted key and the real runtime lookup key
            // can never silently diverge (`%lld` vs `%@`).
            let minutes = String(Int((gap.end.timeIntervalSince(gap.start) / 60).rounded()))
            let gapStart = Self.timeFormatter.string(from: gap.start)
            return Text("Capture \(start)–\(end), \(minutes)-minute gap at \(gapStart)")
        }
        // Named to avoid `scripts/extract-localizable-strings.swift`'s
        // `knownIntegerIdentifiers`/`hasSuffix("Count")` heuristic (see
        // `minutes`'s own comment above) -- `gapTally` doesn't trip it, so
        // the extracted key and the real `%@` runtime key (this is a
        // `String`, not an `Int`, by the time it's interpolated) agree.
        let gapTally = String(gaps.count)
        let totalGapMinutes = String(Int((gaps.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 60).rounded()))
        return Text("Capture \(start)–\(end), \(gapTally) gaps totaling \(totalGapMinutes) minutes")
    }
}

/// One proportional band row: a neutral background track (`AstroTokens.
/// Color.edge`, the same "nothing here" filler `ArchiveTargetRowView`'s own
/// proportional strip already paints for an unclassified segment -- never
/// `.recess`/`.surface`/`.surfaceRaised`, which `V2PolishSurfaceTests.
/// surfaceTokensAreOnlyPaintedByTheSharedTreatment` reserves for
/// `astroRaisedSurface()`/`astroRecessedSurface()` alone) with each
/// `(start, end, color)` segment positioned as a fraction of `[axisStart,
/// axisStart + totalSeconds]` -- never a fixed pixel offset, so the row can
/// never demand more width than its own `GeometryReader` gives it. Plain
/// `Rectangle()`, no rounded corners: a literal `cornerRadius` here would
/// trip `V2PolishSurfaceTests.noCornerRadiusLiteralsOutsideTheTokenFamily`
/// (only `AstroTokens.CornerRadius.panel`, via the two shared-surface
/// modifiers, or `ConcentricRectangle()` are allowed), and a two-corner-
/// radius asset this small reads the same either way.
private struct RibbonTrack: View {
    let title: LocalizedStringKey
    let segments: [(start: Date, end: Date, color: Color)]
    let axisStart: Date
    let totalSeconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(AstroTokens.Color.edge)
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let startFraction = segment.start.timeIntervalSince(axisStart) / totalSeconds
                        let widthFraction = segment.end.timeIntervalSince(segment.start) / totalSeconds
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, proxy.size.width * widthFraction))
                            .offset(x: proxy.size.width * startFraction)
                    }
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
