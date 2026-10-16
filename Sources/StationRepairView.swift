import SwiftUI

struct StationRepairView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = StationRepairModel()
    @State private var saveError: String?
    let station: Station
    let onSaved: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Senderadresse reparieren").font(.headline)
            Text(station.name).font(.title3).textSelection(.enabled)
            Text("Die gespeicherte Radio-Browser-ID bestimmt den Katalogeintrag. Ähnliche Namen werden nicht zugeordnet.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.state {
                    case .idle, .loading:
                        ProgressView("Katalogadresse wird abgerufen …")
                    case .noOrigin:
                        Text("Keine Katalogherkunft gespeichert. Die Adresse kann manuell im Editor geändert werden.")
                    case .missing:
                        Text("Dieser Katalogeintrag ist nicht mehr vorhanden. Die bisherige Adresse bleibt erhalten.")
                    case .unchanged:
                        Text("Der Katalog nennt bereits die gespeicherte Adresse. Es ist keine Reparatur nötig.")
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                    case .proposal(let proposal):
                        Text("Katalogname").font(.subheadline.bold())
                        Text(proposal.catalogName).textSelection(.enabled)
                        address("Bisherige URL", proposal.oldURL, identifier: "repair-old-url")
                        address("Vorgeschlagene URL", proposal.newURL, identifier: "repair-new-url")
                        if proposal.newURL.hasPrefix("http:") {
                            Label("Die vorgeschlagene Adresse verwendet unverschlüsseltes HTTP.", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let saveError { Text(saveError).foregroundStyle(.red).accessibilityIdentifier("repair-save-error") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 100, maxHeight: 310)
            Text("Nur die URL wird gespeichert. Name, Gruppen und Favoriten bleiben erhalten. Laufende Wiedergabe bleibt unverändert; die neue Adresse gilt beim nächsten manuellen Start.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("repair-cancel")
                Spacer()
                Button("Erneut prüfen") { saveError = nil; model.load(station) }
                    .disabled(model.state == .loading)
                    .accessibilityIdentifier("repair-retry")
                Button("URL speichern") { save() }
                    .disabled(proposal == nil)
                    .accessibilityIdentifier("repair-save")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.load(station) }
        .onDisappear { model.cancel() }
    }

    private var proposal: StationURLRepairProposal? {
        if case .proposal(let value) = model.state { return value }
        return nil
    }

    private func address(_ title: LocalizedStringKey, _ value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(value).font(.system(.callout, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
    }

    private func save() {
        guard let proposal else { return }
        do {
            try store.applyURLRepair(proposal)
            onSaved(proposal.newURL)
            dismiss()
        } catch StationSaveError.stationChanged {
            saveError = String(localized: "Der Sender wurde inzwischen geändert. Bitte die Vorschau schließen und erneut prüfen.")
        } catch StationSaveError.stationNotFound {
            saveError = String(localized: "Der Sender ist nicht mehr vorhanden. Bitte den Editor erneut öffnen.")
        } catch {
            saveError = String(localized: "Die Senderliste konnte nicht gespeichert werden. Bitte den Speicherzugriff prüfen und erneut versuchen.")
        }
    }
}
