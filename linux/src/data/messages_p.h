#pragma once
#include <QLocale>
#include <QString>
#include <QHash>
namespace Mucke {
inline QString localizedDataMessage(QString message) {
    if (QLocale().language() != QLocale::German)
        return message;
    static const QHash<QString, QString> translations = {
        {"Listening history contains invalid or oversized fields.",
         "Der Hörverlauf enthält ungültige oder zu große Felder."},
        {"Listening history contains too many records.", "Der Hörverlauf enthält zu viele Einträge."},
        {"Listening history exceeds the 64 MiB limit.",
         "Der Hörverlauf überschreitet die Grenze von 64 MiB."},
        {"Visible", "Sichtbar"},
        {"Hidden", "Ausgeblendet"},
        {"Favorite", "Favorit"},
        {"Not a favorite", "Kein Favorit"},
        {"Invalid library data.", "Ungültige Bibliotheksdaten."},
        {"Unsupported library version.", "Nicht unterstützte Bibliotheksversion."},
        {"The exchange file exceeds 8 MiB.", "Die Austauschdatei überschreitet 8 MiB."},
        {"The data file is not a regular file or is too large.",
         "Die Datendatei ist keine reguläre Datei oder zu groß."},
        {"The data file could not be read.", "Die Datendatei konnte nicht gelesen werden."},
        {"The library is read-only. Check the file version, permissions and whether another instance is "
         "running.",
         "Die Bibliothek ist schreibgeschützt. Bitte Dateiversion, Zugriffsrechte und weitere laufende "
         "Instanzen prüfen."},
        {"The library is read-only.", "Die Bibliothek ist schreibgeschützt."},
        {"The library changed on disk. Reload it before saving.",
         "Die Bibliotheksdatei wurde geändert. Bitte vor dem Speichern neu laden."},
        {"The library changed on disk. Reload it before importing.",
         "Die Bibliotheksdatei wurde geändert. Bitte vor dem Import neu laden."},
        {"The library is too large.", "Die Bibliothek ist zu groß."},
        {"The library could not be saved.", "Die Bibliothek konnte nicht gespeichert werden."},
        {"Listening history is read-only.", "Der Hörverlauf ist schreibgeschützt."},
        {"Listening history changed on disk.", "Die Verlaufsdatei wurde außerhalb der App geändert."},
        {"Listening history could not be saved.", "Der Hörverlauf konnte nicht gespeichert werden."},
        {"Damaged data could not be backed up. The original file remains protected.",
         "Beschädigte Daten konnten nicht gesichert werden. Die ursprüngliche Datei bleibt geschützt."},
        {"The data directory could not be created.", "Der Datenordner konnte nicht angelegt werden."},
        {"This library uses an unsupported version and remains unchanged.",
         "Diese Bibliothek verwendet eine nicht unterstützte Version und bleibt unverändert."},
        {"Another instance is using this library. Changes are disabled.",
         "Eine andere Instanz verwendet diese Bibliothek. Änderungen sind gesperrt."},
        {"The station order is invalid.", "Die Senderreihenfolge ist ungültig."},
        {"Settings are read-only.", "Die Einstellungen sind schreibgeschützt."},
        {"Settings changed on disk.", "Die Einstellungsdatei wurde außerhalb der App geändert."},
        {"Settings could not be saved.", "Die Einstellungen konnten nicht gespeichert werden."},
        {"A setting has an invalid type.", "Eine Einstellung hat einen ungültigen Datentyp."},
        {"Exactly five quick slots are required.", "Genau fünf Schnellwahlspeicher sind erforderlich."},
        {"Invalid quick slot.", "Ungültiger Schnellwahlspeicher."},
        {"Invalid language setting.", "Ungültige Spracheinstellung."},
        {"Invalid startup setting.", "Ungültige Starteinstellung."},
        {"Exactly ten equalizer bands are required.", "Genau zehn Equalizer-Bänder sind erforderlich."},
        {"Invalid equalizer value.", "Ungültiger Equalizer-Wert."},
        {"This entry contains no song title.", "Dieser Eintrag enthält keinen Songtitel."},
        {"The import preview has expired. Open a new preview.",
         "Die Importvorschau ist abgelaufen. Bitte eine neue Vorschau öffnen."},
        {"The library changed after preview. Open a new preview.",
         "Die Bibliothek wurde seit der Vorschau geändert. Bitte eine neue Vorschau öffnen."},
        {"Invalid import choice.", "Ungültige Importauswahl."},
        {"Choose an export destination outside the application data and recording directories.",
         "Bitte ein Exportziel außerhalb der Daten- und Aufnahmeordner wählen."},
        {"The export could not be saved.", "Der Export konnte nicht gespeichert werden."},
        {"The bookmark export could not be saved.", "Der Merklistenexport konnte nicht gespeichert werden."},
        {"The station catalog could not be reached. Please try again later.",
         "Der Senderkatalog ist nicht erreichbar. Bitte später erneut versuchen."},
        {"The station catalog response exceeds 2 MiB.",
         "Die Antwort des Senderkatalogs überschreitet 2 MiB."},
        {"The station catalog returned invalid data.", "Der Senderkatalog hat ungültige Daten geliefert."},
        {"The catalog is limited to 20 pages of 50 stations.",
         "Der Katalog ist auf 20 Seiten mit je 50 Sendern begrenzt."},
        {"The search filter is too long or invalid.", "Der Suchfilter ist zu lang oder ungültig."},
        {"The bitrate filter is invalid.", "Der Bitratenfilter ist ungültig."},
        {"The catalog sort order is invalid.", "Die Katalogsortierung ist ungültig."},
        {"The station catalog ID is invalid.", "Die Senderkatalog-ID ist ungültig."},
        {"No replacement stream was found for this station.",
         "Für diesen Sender wurde kein Ersatzstream gefunden."},
    };
    if (translations.contains(message))
        return translations.value(message);
    static const QHash<QString, QString> prefixes = {
        {"The library could not be saved: ", "Die Bibliothek konnte nicht gespeichert werden: "},
        {"The library could not be loaded: ", "Die Bibliothek konnte nicht geladen werden: "},
        {"Listening history could not be loaded: ", "Der Hörverlauf konnte nicht geladen werden: "},
        {"Settings could not be loaded: ", "Die Einstellungen konnten nicht geladen werden: "},
        {"The import could not be previewed: ", "Die Importvorschau konnte nicht erstellt werden: "},
        {"The import could not be saved: ", "Der Import konnte nicht gespeichert werden: "}};
    for (auto it = prefixes.begin(); it != prefixes.end(); ++it)
        if (message.startsWith(it.key()))
            return it.value() + localizedDataMessage(message.mid(it.key().size()));
    if (message.startsWith("Damaged data was backed up as "))
        return "Beschädigte Daten wurden separat gesichert: " + message.mid(30);
    return message;
}
} // namespace Mucke
