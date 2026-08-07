import AppKit
import SwiftUI

/// R11-T3/F11(c): "mi az a Siril, mire használja ez az app, mi megy nélküle"
/// -- reached from three places (spec F20/F11): `QualitySegment`'s Siril-hiány
/// figyelmeztetés "Mi ez?" gombja, `RatingSettingsView`'s piros "Siril nem
/// található" státusza melletti "Mi a Siril?" link, és a Súgó menü "A
/// Sirilről…" pontja (`Commands.swift`, a `Fogalomtár` notification-mintáját
/// követve, mert a menüsornak nincs view-state-je -- ld. `AstroToolApp
/// .RootView`). Static (no live Siril probe here -- that's `RatingSettingsView
/// .sirilStatusView`'s job), kept minimal by design.
struct SirilHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let sirilURL = URL(string: "https://siril.org")!

    private struct Row {
        let capability: String
        let worksWithoutSiril: Bool
    }

    private static let rows: [Row] = [
        Row(capability: "Natív háttér-/telítettség-pontozás", worksWithoutSiril: true),
        Row(capability: "FWHM / kerekség / csillagszám metrikák", worksWithoutSiril: false),
        Row(capability: "Plate-solve (koordináta felismerése a képből)", worksWithoutSiril: false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Mi az a Siril?").font(.headline)
                Spacer()
                Button("Bezárás") { dismiss() }
            }

            Text(
                "A Siril egy ingyenes, nyílt forráskódú asztrofotó-feldolgozó program. "
                    + "Ez az app a saját, natív keret-pontozása mellett a Siril parancssori "
                    + "eszközét (siril-cli) hívja meg a háttérben két dologhoz: pontosabb "
                    + "csillag-metrikák (FWHM, kerekség, csillagszám) méréséhez, és a "
                    + "koordináta nélküli felvételek vak (blind) plate-solve-jához."
            )
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("Mi működik Siril nélkül?").font(.subheadline).bold()
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Image(systemName: row.worksWithoutSiril ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(row.worksWithoutSiril ? .green : .secondary)
                        Text(row.capability)
                        Spacer()
                        Text(row.worksWithoutSiril ? "igen" : "nem")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            Text("A Siril útvonala a Beállítások ▸ Pontozás & expozíció fülön adható meg.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Siril letöltése…") { NSWorkspace.shared.open(Self.sirilURL) }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
    }
}
