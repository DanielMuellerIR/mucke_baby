import SwiftUI

// Importiert nur Sender, deren Stream-URL noch nicht in der Liste steht.
struct GenreListsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var lists: [GenreList] = []
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kuratierte Genre-Listen").font(.headline)
            Text("Fertige Sender-Sammlungen. Import fügt nur neue Sender hinzu — Dubletten (gleiche URL) werden übersprungen.")
                .font(.caption).foregroundStyle(.secondary)

            List(lists) { list in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(list.name)
                        Text("\(list.count ?? 0) Sender")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Importieren") {
                        do {
                            let added = try store.importGenreList(list)
                            message = added > 0
                                ? String(localized: "\(added) neue Sender aus „\(list.name)“ hinzugefügt.")
                                : String(localized: "„\(list.name)“: alle Sender bereits vorhanden.")
                        } catch {
                            message = store.persistenceMessage
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(Color.accentColor)
            }

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480, height: 440)
        .onAppear { lists = store.availableGenreLists() }
    }
}
