import SwiftUI

/// Help ▸ Glossary -- a plain, always-available reference for the
/// vocabulary this app's numbers and labels assume the reader already
/// knows. Entries are ported from V1's `GlossarySheet` (kept static, no
/// live data, 1-2 sentences each, ordered roughly pipeline-first: capture,
/// then processing, then library housekeeping), translated to English
/// rather than transliterated -- the V2 UI is English throughout.
///
/// Searchable via the native `.searchable(text:)` modifier (case/diacritic
/// insensitive, matches term name or definition), and supports an optional
/// `anchor` -- the exact term name to scroll straight to on open, used by
/// `MetricInfoButton`'s per-metric "In the Glossary" links. `nil` opens at
/// the top, the same as the plain Help-menu entry point.
public struct GlossaryView: View {
    public let anchor: String?
    public let dismiss: () -> Void

    @State private var searchText = ""

    public struct Term: Identifiable {
        public let name: String
        public let definition: String
        public var id: String { name }
    }

    public static let terms: [Term] = [
        Term(name: "FWHM", definition: "\"Full Width at Half Maximum\" -- the half-maximum width of a star's light profile. The standard measure of focus sharpness: a smaller FWHM means a sharper image. Measured in pixels, or in arcseconds once pixel size and focal length are known."),
        Term(name: "Roundness", definition: "How far a star's shape deviates from a perfect circle (0 = perfect circle). A high value can indicate coma, star trailing (poor polar alignment or a guiding error), or a mirror/lens defect."),
        Term(name: "z-score", definition: "How many standard deviations a measurement sits from the mean. Rating uses this to flag \"outlier\" frames -- the `rating.outlierZScore` setting (Settings ▸ Rating & Exposure) sets the threshold."),
        Term(name: "Manual verdict", definition: "Your own accept/reject decision on a frame (Review workspace, or a frame row's own context menu). This takes PRIORITY over the score when stacking: a rejected frame is left out of the stack list even if it scores best."),
        Term(name: "e⁻/s/″²", definition: "Electrons per second per square arcsecond -- the sky background's true brightness, in a unit independent of sensor and setup. Only computable with a measured sensor profile (Sensor Profiles page); without one you only see raw ADU, which is not comparable across setups."),
        Term(name: "Airmass", definition: "The optical thickness of the atmosphere the light passes through to reach the target, relative to the horizon (1 at the zenith, much larger low over the horizon). Image quality degrades at low altitude because of atmospheric scattering and extinction."),
        Term(name: "Duty cycle", definition: "A session's actual integration time (the summed exposure time of its light frames) against the full window between the start and end of capture, as a percentage -- a Nights page column. A low value can indicate a lot of downtime (cloud, meridian flip, dithering, hardware fault)."),
        Term(name: "Cloud forecast (Open-Meteo)", definition: "Opt-in cloud-cover forecast from the open Open-Meteo service (Settings ▸ Location). Shown on the \"Tonight\" tile and the Calendar's \"Cloud\" column: how cloudy the sky is expected to be from dusk to dawn -- only for the next 7 days, and only your configured coordinate is sent, nothing from your library."),
        Term(name: "Field of view (FOV) / framing fit", definition: "The area of sky your sensor and optics cover, in degrees. Discover also shows a target's fill ratio against the sensor's short edge and factors it into ranking order: anything that would only fit as a tiny dot ranks lower; a good fill is favored; a target too large signals a mosaic is needed."),
        Term(name: "Quarantine", definition: "The Audit page's \"cleanable\" script's destination folder: candidate excess/duplicate files are MOVED here (never deleted). You empty the quarantine folder yourself, by your own decision."),
        Term(name: "Hardlink", definition: "Two file names pointing at the same data stored once on disk (not a copy) -- taking up the same space as one copy, not two. This app uses this for calibration linking and stack export: it links the shared calibration_library file into the session folder instead of copying it."),
        Term(name: "Bias", definition: "A calibration frame that records the sensor's readout noise and offset level: a 0-second (or minimal) exposure with the optics covered. One input to dark and flat calibration."),
        Term(name: "Dark", definition: "A calibration frame that records the sensor's thermal (dark current) noise: the same exposure time and temperature as the light frames, with the optics covered. Used to subtract pixel-level thermal noise."),
        Term(name: "Flat", definition: "A calibration frame that records the sensor/optics' uneven illumination sensitivity (vignetting, dust): an image of an evenly lit surface, taken with the same setup as the light frames."),
        Term(name: "Bortle scale", definition: "A 1-9 scale for sky background light pollution: 1 is a perfectly dark rural sky, 9 is an inner-city sky where only the brightest stars are visible. A night note's \"Bortle\" field expects this number -- lower is darker (better)."),
        Term(name: "SQM", definition: "\"Sky Quality Meter\" -- sky background brightness in magnitudes per square arcsecond, measured with a handheld instrument. Typical range is roughly 17 (bright urban sky) to 22 (excellent, dark rural sky); a larger number means a darker (better) sky."),
        Term(name: "Seeing", definition: "The atmosphere's momentary steadiness/turbulence -- this sets how sharp a point stars can be focused to, independent of equipment quality. Night notes often record it on a 1-5 scale (1 = unsteady/poor, 5 = crystal-clear/excellent), though plain-language labels (\"excellent/good/fair/poor\") are common too."),
        Term(name: "Transparency", definition: "The sky's light-transmitting ability -- haze, smoke, or high cloud degrade it even when the night still looks starry. Independent of seeing: a night can be steady (good seeing) yet hazy (poor transparency), or the reverse. Also commonly recorded on a 1-5 scale."),
        Term(name: "Plate-solve", definition: "Automatically matching a frame's star pattern against catalogs so the app can determine the exact RA/Dec of the frame's center, even with no header data. This app calls Siril's command-line tool to do this -- it does not work without Siril."),
        Term(name: "Master (calibration)", definition: "Many individual calibration frames (e.g. 50 darks) combined into a single, noise-reduced average/median image (\"master dark\", \"master flat\", \"master bias\"). Actual calibration (cleaning light frames) is done by this combined master, not the individual raw frames."),
        Term(name: "Gain/Offset", definition: "The gain and offset (baseline shift) set on the camera's controller -- these can differ per setup/session even for the same camera. The sensor profile, calibration matching, and background e⁻/s/″² calculation all require an exact (camera, gain, offset) match, never an approximate guess."),
        Term(name: "ADU", definition: "\"Analog-to-Digital Unit\" -- the sensor's raw, uncalibrated output unit (a pixel's \"brightness\" at the header/measurement level, before conversion to e⁻ or true brightness). Background measured in ADU is not comparable across setups -- that needs the measured sensor profile's e⁻/s/″² conversion."),
        Term(name: "EGAIN", definition: "The sensor's e⁻/ADU conversion factor at a given gain setting (how many electrons one ADU corresponds to) -- from the FITS header's `EGAIN` key, or from a measured sensor profile. This is what lets a raw ADU background reading convert to a true, setup-independent e⁻/s/″² value."),
        Term(name: "Culmination", definition: "The moment of a target's greatest altitude during the night -- when it crosses the meridian. Around culmination the light path through the atmosphere is shortest, so image quality is typically best then (provided a meridian flip doesn't interrupt the capture)."),
        Term(name: "Sub(-exposure)", definition: "The exposure length of a single raw light frame (e.g. \"300s subs\") -- the final stack is built from many of these. Sub length is a trade-off: a longer sub accumulates less read noise, but each individual frame risks more from a satellite trail, cloud, or tracking error."),
        Term(name: "Integration (gross vs. real)", definition: "Gross integration is the raw sum of every session light frame's exposure time; real (usable) integration only counts the session's non-duplicate, non-rejected, non-excluded frames -- this is what actually goes into the final stack. This app always headlines the real number everywhere, showing the gross figure only as a comparison."),
        Term(name: "Dither", definition: "Deliberately, slightly (a few pixels) shifting the imaging system between subs -- this randomizes which pixel a given sky point lands on, so stacking can average out fixed-pattern noise (hot pixels, sensor defects) instead of it staying in the same place in every frame."),
        Term(name: "Filter (NB vs. BB)", definition: "NB (\"narrowband\", e.g. Ha, OIII, SII) passes only a narrow wavelength range -- less sensitive to moonlight/light pollution, so usable under moonlit or city skies. BB (\"broadband\", e.g. L, R, G, B, or unfiltered OSC) passes most of the visible spectrum -- gives true color/brightness under a dark, moonless sky."),
        Term(name: "Setup fingerprint", definition: "A session's camera+optics+reducer/Barlow combination \"fingerprint\", automatically recognized from FITS headers (focal length, pixel size, camera name). This is what distinguishes whether two sessions used the same equipment -- without it, field-of-view matching and trends would not be comparable."),
        Term(name: "Wind", definition: "The wind speed measured or estimated during a session (typically km/h or m/s) -- strong wind can shake the tube/mount, causing star trailing or blur even under excellent seeing."),
        Term(name: "Dew", definition: "Dew or frost forming on the optics or sensor during a session -- causes stars to gradually blur, then disappear, in later frames. A night note's field records whether this happened (e.g. \"none\", \"mild\", \"heavy -- a dew heater would have helped\")."),
    ]

    public init(anchor: String? = nil, dismiss: @escaping () -> Void) {
        self.anchor = anchor
        self.dismiss = dismiss
    }

    private var filteredTerms: [Term] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.terms }
        return Self.terms.filter {
            $0.name.localizedStandardContains(query) || $0.definition.localizedStandardContains(query)
        }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if filteredTerms.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollViewReader { proxy in
                        List(filteredTerms) { term in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(term.name).font(.subheadline.bold())
                                Text(term.definition).font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .id(term.name)
                        }
                        .onAppear {
                            guard let anchor else { return }
                            // A fresh `List`'s content needs a beat to lay
                            // out before `scrollTo` has anything to scroll
                            // to -- same "next runloop tick" workaround V1's
                            // `GlossarySheet` used for the identical reason.
                            DispatchQueue.main.async {
                                proxy.scrollTo(anchor, anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Glossary")
            .searchable(text: $searchText, prompt: "Search the glossary…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 480, height: 560)
        .accessibilityIdentifier("v2.help.glossary")
    }
}
