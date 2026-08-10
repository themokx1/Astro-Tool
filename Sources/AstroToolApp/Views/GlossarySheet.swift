import SwiftUI

/// R9-T6/B16(b): `Súgó ▸ Fogalomtár` -- a plain, always-available reference
/// for the vocabulary this app's numbers/labels assume the reader already
/// knows. Kept static (no live data), 1-2 sentences each, ordered
/// roughly pipeline-first (capture -> processing -> library housekeeping).
///
/// R11-T12/F11(a): grew a search field (title+text, case/diacritic
/// insensitive) and an optional `anchor` -- the term name to scroll straight
/// to on open, used by `MetricInfoButton`'s per-column links and
/// `SessionNoteSheet`'s per-field ⓘ popovers (both post `.showGlossary` with
/// the anchor as the notification's `object`, read by `RootView`).
struct GlossarySheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The term name to scroll to on open, `nil` for "just open at the top"
    /// (every existing caller before this task).
    var anchor: String?

    @State private var searchText = ""

    private struct Term {
        let name: String
        let definition: String
    }

    private static let terms: [Term] = [
        Term(name: "FWHM", definition: "\"Full Width at Half Maximum\" -- egy csillag fényprofiljának félértékszélessége. A fókusz élességének standard mérőszáma: kisebb FWHM = élesebb kép. Pixelben vagy (pixelméret+fókusz ismeretében) ívmásodpercben mérhető."),
        Term(name: "Kerekség", definition: "Egy csillag alakjának köralakúságtól való eltérése (0 = tökéletes kör). Magas érték kómát, csillag-nyúlást (rossz polárbeállás, autoguiding-hiba) vagy tükör/lencse-hibát jelezhet."),
        Term(name: "z-score", definition: "Egy mérés hány szórásnyira van az átlagtól. A pontozás ezzel jelöli ki a \"kiugró\" (outlier) kereteket -- a `rating.outlierZScore` beállítás (Beállítások ▸ Pontozás & expozíció) szabja meg a küszöböt."),
        Term(name: "Saját döntés", definition: "A felhasználó saját elfogadás/elvetés döntése egy keretről (Átnézés ablak, vagy a keret sorának helyi menüje). Stackelésnél ELSŐBBSÉGET kap a pontszámmal szemben: egy elvetett keret a legjobb pontszám mellett is kimarad a stacklistből."),
        Term(name: "e⁻/s/″²", definition: "Elektron/másodperc/ívmásodperc² -- az égi háttér valódi fényessége, szenzor- és setup-független mértékegységben. Csak mért szenzor-profillal (Szenzor-profilok oldal) számolható; anélkül csak nyers ADU-t látsz, ami setupok között nem összehasonlítható."),
        Term(name: "Airmass", definition: "A légkör optikai vastagsága, amin a fény a célponthoz keresztülhalad, a horizonthoz viszonyítva (zenitben = 1, alacsonyan a horizont felett jóval nagyobb). Alacsony magasságnál a légköri szórás és extinkció miatt romlik a képminőség."),
        Term(name: "Hatékonyság (duty cycle)", definition: "A session tényleges integrációs ideje (a light-keretek összes expozíciós ideje) a felvétel kezdete és vége közti teljes ablakhoz mérve, százalékban -- az Éjszakák oldal oszlopa. Alacsony érték sok állásidőt (felhő, meridián-átfordulás, dithering, hardver-hiba) jelezhet."),
        Term(name: "Felhőzet-előrejelzés (Open-Meteo)", definition: "Opt-in felhőzet-előrejelzés a nyílt Open-Meteo szolgáltatásból (Beállítások ▸ Helyszín). A \"Ma este\" tile és a Naptár \"Felhő\" oszlopa mutatja, alkonytól hajnalig hány százalékban felhős az égbolt -- csak a következő 7 napra, és csak a beállított koordinátát küldi el, semmit a könyvtárból."),
        Term(name: "Látómező (FOV) / kompozíciós illeszkedés", definition: "A szenzor+optika által lefedett égterület mérete fokban. A Felfedezés a célpont rövid képoldalhoz viszonyított kitöltési arányát is mutatja és beleszámítja az ajánlási sorrendbe: ami csak apró pontként fér be, hátrébb kerül; a jó kitöltés előnyt kap; a túl nagy célpont mozaikot jelez."),
        Term(name: "Karantén", definition: "Az Audit oldal \"Takarítható\"-script célmappája: a talált felesleges/duplikált fájlokat ide MOZGATJA (`mv`), soha nem törli. A karantént a felhasználó üríti ki kézzel, saját döntése alapján."),
        Term(name: "Hardlink", definition: "Két fájlnév, ami ugyanarra a lemezen tárolt adatra mutat (nem másolat) -- ugyanannyi helyet foglal egyszer, mint kétszer. Ezt használja ez az app a kalibráció-linkeléshez és a stack-export-hoz: a session mappájába \"link\"-eli a megosztott calibration_library fájlt, anélkül hogy másolná."),
        Term(name: "Bias", definition: "A szenzor kiolvasási zaját és alapszintjét (offset) rögzítő kalibrációs keret: 0 másodperces (vagy minimális) expozíció, fedett optikával. A dark- és flat-kalibráció egyik bemenete."),
        Term(name: "Dark", definition: "A szenzor hőzaját (dark current) rögzítő kalibrációs keret: ugyanolyan expozíciós idő és hőmérséklet, mint a light kereteknél, fedett optikával. A pixel-szintű hőzaj kivonásához használt."),
        Term(name: "Flat", definition: "A szenzor/optika egyenetlen megvilágítás-érzékenységét (vinjettálás, por) rögzítő kalibrációs keret: egyenletesen megvilágított felület felvétele ugyanazzal a setuppal, mint a light kereteknél."),

        // R11-T12/F11(a): ~15 new entries -- the beginner's-own vocabulary
        // this app's session-note template and planner numbers assume
        // already known, per the R11 persona review's own finding (spec
        // F11 item 4: "a Fogalomtárból pont azok a fogalmak hiányoznak,
        // amiket az app maga kérdez").
        Term(name: "Bortle-skála", definition: "1-9-es skála az égi háttér fényszennyezettségére: 1 = tökéletesen sötét vidéki ég, 9 = belvárosi ég, ahol csak a legfényesebb csillagok látszanak. A SessionNoteSheet \"Bortle\" mezője ezt a számot várja -- minél alacsonyabb, annál sötétebb (jobb) az ég."),
        Term(name: "SQM", definition: "\"Sky Quality Meter\" -- az égi háttér fényessége mag/ívmásodperc² egységben, egy kézi műszerrel mérve. Jellemző tartomány kb. 17 (városi, világos ég) és 22 (kiváló, sötét vidéki ég) között; nagyobb szám = sötétebb (jobb) ég."),
        Term(name: "Seeing", definition: "A légkör pillanatnyi nyugalma/turbulenciája -- ez szabja meg, mennyire éles pontra tudnak fókuszálni a csillagok, függetlenül a felszerelés minőségétől. A SessionNoteSheet-ben gyakran 1-5-ös skálán (1 = nyugtalan/rossz, 5 = kristálytiszta/kiváló) jegyzik fel, de a szöveges \"kiváló/jó/közepes/rossz\" jelölés is elterjedt."),
        Term(name: "Átlátszóság", definition: "Az égbolt fényáteresztő képessége -- pára, füst vagy magas felhő rontja, még ha az ég éjszaka csillagosnak is látszik. A seeing-től független: lehet nyugodt (jó seeing), de párás (rossz átlátszóság) éjszaka is. Szintén gyakran 1-5-ös skálán rögzített érték."),
        Term(name: "Plate-solve", definition: "Egy felvétel csillagmintázatának automatikus összevetése katalógusokkal, hogy az app pontosan meghatározza a kép közepének RA/Dec koordinátáját fejléc-adat nélkül is. Ehhez ez az app a Siril parancssori eszközét hívja -- Siril nélkül nem működik."),
        Term(name: "Master (kalibráció)", definition: "Sok egyedi kalibrációs keret (pl. 50 dark) egyetlen, zajcsökkentett átlag/medián-képpé kombinálva (\"master dark\", \"master flat\", \"master bias\"). A tényleges kalibrációt (light-keretek tisztítását) ez a kombinált master végzi, nem az egyedi nyers keretek."),
        Term(name: "Gain/Offset", definition: "A szenzor kamera-vezérlőjében beállított erősítés (gain) és alapszint-eltolás (offset) -- ugyanahhoz a kamerához setuponként/session-önként eltérő is lehet. A szenzor-profil, a kalibráció-illesztés és a háttér e⁻/s/″² számítás mind pontos (kamera, gain, offset) hármas egyezést vár, sosem közelítő találgatást."),
        Term(name: "ADU", definition: "\"Analog-to-Digital Unit\" -- a szenzor nyers, kalibrálatlan kimeneti egysége (a pixel \"fényessége\" a fejléc/mérés szintjén, még e⁻-be/valós fényességbe át nem váltva). A háttér ADU-ban mért értéke setupok között nem összehasonlítható -- ehhez kell a mért szenzor-profil e⁻/s/″²-es átváltása."),
        Term(name: "EGAIN", definition: "A szenzor e⁻/ADU átváltási tényezője az adott gain-beállításnál (hány elektronnak felel meg egyetlen ADU) -- a FITS-fejléc `EGAIN` kulcsa, vagy a mért szenzor-profil adja. Ez teszi lehetővé az ADU-ban mért nyers háttér átváltását valódi, setup-független e⁻/s/″² értékre."),
        Term(name: "Kulmináció", definition: "A célpont legnagyobb magasságának pillanata az éjszaka során -- ekkor halad át a délkörön (meridiánon). Kulmináció körül a legrövidebb a fényútja a légkörben, tehát jellemzően ekkor a legjobb a képminőség (feltéve, hogy a meridián-átfordulás nem szakítja meg a felvételt)."),
        Term(name: "Sub(-expozíció)", definition: "Egyetlen nyers light-keret expozíciós ideje (pl. \"300s-es sub-ok\") -- a végső stack ezek sokaságából áll össze. A sub hossza kompromisszum: hosszabb sub kevesebb leolvasási zajt halmoz, de nagyobb a műholdnyom/felhő/vezetési hiba kockázata egy-egy keretben."),
        Term(name: "Integráció (bruttó vs valós)", definition: "A bruttó integráció minden session light-keret expozíciós idejének nyers összege; a valós (usable) integráció csak a duplikátum-mentesített, el nem utasított, ki nem zárt session kereteket számolja -- ez utóbbi az, ami ténylegesen belekerül a végső stackbe. Ez az app mindenhol a valós számot emeli ki fejlécként, a bruttót csak összevetésként mutatja."),
        Term(name: "Dither", definition: "A felvevőrendszer szándékos, apró (néhány pixeles) elmozdítása két sub között -- ez véletlenszerűvé teszi, hogy egy adott égi pont melyik pixelre esik, így a stackelés a fix mintázatú zajt (hot pixel, szenzor-hiba) ki tudja átlagolni ahelyett, hogy minden keretben ugyanott maradna."),
        Term(name: "Szűrő (NB vs BB)", definition: "NB (\"narrowband\", keskenysáv, pl. Ha, OIII, SII) csak egy szűk hullámhossz-tartományt enged át -- kevésbé érzékeny a holdfényre/fényszennyezésre, ezért holdas vagy városi égen is használható. BB (\"broadband\", szélessáv, pl. L, R, G, B, vagy szűretlen OSC) a látható fény nagy részét átengedi -- sötét, holdmentes égen ad valós színt/fényességet."),
        Term(name: "Setup-fingerprint", definition: "Egy session kamera+optika+redukátor/Barlow kombinációjának \"ujjlenyomata\", a FITS-fejlécekből (fókusztávolság, pixelméret, kamera neve) automatikusan felismerve. Ez különbözteti meg, hogy két session ugyanazzal a felszereléssel készült-e -- enélkül a látómező-illesztés és a trendek nem lennének összehasonlíthatók."),
        Term(name: "Szél", definition: "A session közben mért/becsült szélsebesség (jellemzően km/h vagy m/s) -- erős szél rezgést vihet a csőre/állványra, ami csillag-nyúlást vagy elmosódást okozhat, még kiváló seeing mellett is."),
        Term(name: "Páralecsapódás", definition: "Harmat/dér lecsapódása az optikán vagy a szenzoron a session alatt -- fokozatosan elmosódó, majd teljesen eltűnő csillagokat okoz a felvételeken. A SessionNoteSheet mezője azt rögzíti, hogy volt-e ilyen probléma aznap éjjel (pl. \"nem\", \"enyhe\", \"erős -- páramentesítő kellett volna\")."),
    ]

    private var filteredTerms: [Term] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.terms }
        return Self.terms.filter {
            $0.name.localizedStandardContains(query) || $0.definition.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Fogalomtár").font(.headline)
                Spacer()
                Button("Bezárás") { dismiss() }
            }
            .padding(16)
            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Keresés a fogalomtárban…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 12)

            if filteredTerms.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(filteredTerms, id: \.name) { term in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(term.name).font(.subheadline).bold()
                                    Text(term.definition).font(.callout).foregroundStyle(.secondary)
                                }
                                .id(term.name)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear {
                        guard let anchor else { return }
                        // R11-T12/F11(a): a fresh sheet's `ScrollView` needs a
                        // beat to lay out its content before `scrollTo` has
                        // anything to scroll to -- same "next runloop tick"
                        // workaround this app's other `ScrollViewReader`
                        // call sites use for the identical reason.
                        DispatchQueue.main.async {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 560)
    }
}
