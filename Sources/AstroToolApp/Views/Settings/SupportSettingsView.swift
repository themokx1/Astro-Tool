import AstroCore
import Foundation
import SwiftUI

struct SupportSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showsPreview = false

    var body: some View {
        Form {
            Section("Adatvédelem") {
                Label("A képek, katalógus, pontozások és jegyzetek a Macen maradnak.", systemImage: "internaldrive")
                Label(
                    appState.config.weather.enabled
                        ? "Az időjárás be van kapcsolva; csak a kiválasztott hely koordinátája kerül az Open-Meteo szolgáltatáshoz."
                        : "Az időjárás ki van kapcsolva; az AstroTool nem küld megfigyelési adatot hálózatra.",
                    systemImage: appState.config.weather.enabled ? "cloud" : "cloud.slash"
                )
                Link("Adatvédelmi tájékoztató", destination: URL(string: ProductInfo.privacyURL)!)
            }

            Section("Alkalmazás") {
                LabeledContent("Verzió", value: ProductInfo.displayVersion)
                LabeledContent("Adatbázisséma", value: appState.db == nil ? "Nincs megnyitva" : String(Database.currentSchemaVersion))
                LabeledContent("Rendszer", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Architektúra", value: SupportDiagnostics.currentArchitecture)
            }

            Section("Segítség") {
                Link("Első lépések és dokumentáció", destination: URL(string: ProductInfo.documentationURL)!)
                Link("Hibajelzés és támogatás", destination: URL(string: ProductInfo.supportURL)!)
                Link("Forráskód és kiadások", destination: URL(string: ProductInfo.sourceURL)!)
            }

            Section("Biztonságos diagnosztika") {
                Text("Csak verziót, rendszeradatot, névtelen darabszámokat és műveletkategóriákat tartalmaz. Nem kerül bele elérési út, fájlnév, célpont, koordináta, jegyzet, FITS-fejléc vagy hibaüzenet.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Másolás") { appState.copySupportDiagnostics() }
                    Button("Mentés…") { appState.saveSupportDiagnostics() }
                    Spacer()
                    Button(showsPreview ? "Előnézet elrejtése" : "Előnézet") {
                        withAnimation(.snappy) { showsPreview.toggle() }
                    }
                }

                if showsPreview {
                    ScrollView([.horizontal, .vertical]) {
                        Text(appState.supportDiagnostics.plainText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(ProductMetrics.standard)
                    }
                    .frame(minHeight: 220, maxHeight: 320)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .formStyle(.grouped)
    }
}
