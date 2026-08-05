import Foundation

/// Hungarian common names for well-known Messier/NGC/IC/Sharpless deep-sky
/// objects, keyed by the exact normalized designation string
/// `TargetNameResolver` produces (`"M 42"`, `"NGC 7000"`, `"IC 1805"`,
/// `"Sh2-129"`) -- plus one combined key, `"IC1805-1848"` (no space, no en
/// dash), for the Heart+Soul (IC 1805/1848) pairing amateur session folders
/// almost always name together as a single target.
///
/// Deliberately NOT exhaustive: only designations with an actual, commonly
/// used Hungarian common name are present here. Anything else (most
/// Messier globular clusters, most bare NGC galaxies, ...) simply has no
/// entry, and `TargetNameResolver` falls back to showing the designation
/// alone -- that's a correct, expected outcome, not a missing-data bug.
enum CatalogNames {
    static let hungarian: [String: String] = [
        // MARK: - Messier

        "M 1": "Rák-köd",
        "M 6": "Lepke-halmaz",
        "M 7": "Ptolemaiosz-halmaz",
        "M 8": "Lagúna-köd",
        "M 11": "Vadkacsa-halmaz",
        "M 13": "Herkules-gömbhalmaz",
        "M 16": "Sas-köd",
        "M 17": "Omega-köd",
        "M 20": "Trifid-köd",
        "M 24": "Kis Sagittarius-csillagfelhő",
        "M 27": "Súlyzó-köd",
        "M 31": "Androméda-galaxis",
        "M 33": "Triangulum-galaxis",
        "M 42": "Orion-köd",
        "M 44": "Méhkas-halmaz",
        "M 45": "Fiastyúk",
        "M 51": "Örvény-galaxis",
        "M 57": "Gyűrűs-köd",
        "M 63": "Napraforgó-galaxis",
        "M 64": "Fekete Szem",
        "M 76": "Kis Súlyzó-köd",
        "M 81": "Bode-galaxis",
        "M 82": "Szivar-galaxis",
        "M 83": "Déli Szélkerék-galaxis",
        "M 97": "Bagoly-köd",
        "M 101": "Szélkerék-galaxis",
        "M 104": "Sombrero-galaxis",

        // MARK: - NGC

        "NGC 253": "Sculptor-galaxis",
        "NGC 281": "Pacman-köd",
        "NGC 869": "Ikerhalmaz",
        "NGC 884": "Ikerhalmaz",
        "NGC 1499": "Kalifornia-köd",
        "NGC 2237": "Rozetta-köd",
        "NGC 2244": "Rozetta-köd",
        "NGC 2264": "Karácsonyfa-halmaz",
        "NGC 4565": "Tű-galaxis",
        "NGC 6543": "Macskaszem-köd",
        "NGC 6888": "Sarló-köd",
        "NGC 6946": "Tűzijáték-galaxis",
        "NGC 6960": "Fátyol-köd",
        "NGC 6992": "Fátyol-köd",
        "NGC 7000": "Észak-Amerika-köd",
        "NGC 7293": "Csiga-köd",
        "NGC 7635": "Buborék-köd",

        // MARK: - IC

        "IC 434": "Lófej-köd térsége",
        "IC 1396": "Elefántormány-köd",
        "IC 1805": "Szív-köd",
        "IC 1848": "Lélek-köd",
        "IC 4604": "Rho Ophiuchi köd-komplexum",
        "IC 5070": "Pelikán-köd",
        "IC 5146": "Gubó-köd",
        // Combined Heart+Soul pairing -- see `TargetNameResolver`'s IC-range
        // parsing, which looks this exact key up before falling back to the
        // single `"IC 1805"` entry above.
        "IC1805-1848": "Szív- és Lélek-köd",

        // MARK: - Sharpless

        "Sh2-101": "Tulipán-köd",
        "Sh2-129": "Repülő Denevér",
        "Sh2-155": "Barlang-köd",
    ]
}
