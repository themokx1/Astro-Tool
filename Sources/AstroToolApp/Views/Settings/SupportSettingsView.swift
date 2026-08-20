import AstroCore
import Foundation
import SwiftUI

struct SupportSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var preview: SupportDiagnostics?

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
                    Button("Előnézet készítése") { preview = appState.supportDiagnostics }
                    Button("Másolás") {
                        if let preview { appState.copySupportDiagnostics(preview) }
                    }
                    .disabled(preview == nil)
                    Button("Mentés…") {
                        if let preview { appState.saveSupportDiagnostics(preview) }
                    }
                    .disabled(preview == nil)
                    Spacer()
                    if preview != nil {
                        Button("Előnézet törlése") { withAnimation(.snappy) { preview = nil } }
                    }
                }

                if let preview {
                    ScrollView([.horizontal, .vertical]) {
                        Text(preview.plainText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(ProductMetrics.standard)
                    }
                    .frame(minHeight: 220, maxHeight: 320)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("A Másolás és Mentés pontosan a fent látható pillanatképet használja. Friss adatokhoz készíts új előnézetet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
