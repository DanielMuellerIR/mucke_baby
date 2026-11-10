#include "../src/data/librarystore.h"
#include "../src/data/codec_p.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QDir>
#include <QDate>
#include <unistd.h>
#include <QJsonArray>
#include <QTextStream>
#include <limits>
using namespace Mucke;
using namespace Mucke::DataCodec;
namespace {
int checks = 0;
void check(bool yes, const char *message) {
    ++checks;
    if (!yes)
        throw std::runtime_error(message);
}
void write(const QString &path, const QByteArray &data) {
    QFile f(path);
    check(f.open(QIODevice::WriteOnly), "fixture open");
    check(f.write(data) == data.size(), "fixture write");
}
QByteArray read(const QString &path) {
    QFile f(path);
    check(f.open(QIODevice::ReadOnly), "read file");
    return f.readAll();
}
Json example(int version = 1) {
    Json j = {
        {"format", "mucke-baby-library"},
        {"formatVersion", version},
        {"exportedAt", "2026-10-28T12:00:00.000Z"},
        {"stations", Json::array({{{"id", "11111111-1111-4111-8111-111111111111"},
                                   {"name", "Example Radio"},
                                   {"url", "https://radio.example:443/Stream?q=Case"}}})},
        {"groups", Json::array({{{"id", "22222222-2222-4222-8222-222222222222"},
                                 {"name", "Example"},
                                 {"stationIDs", Json::array({"11111111-1111-4111-8111-111111111111"})}}})},
        {"bookmarks", Json::array({{{"id", "33333333-3333-4333-8333-333333333333"},
                                    {"raw", "Example Artist - Song"},
                                    {"artist", "Example Artist"},
                                    {"title", "Song"},
                                    {"station", "Example Radio"},
                                    {"heardAt", "2026-10-28T12:00:00+01:00"},
                                    {"savedAt", "2026-10-28T12:00:00.000Z"}}})}};
    if (version >= 2)
        j["bookmarks"][0]["recognition"] = {{"source", "shazam"},
                                            {"recognizedAt", "2026-10-28T12:00:05.000Z"},
                                            {"stationID", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},
                                            {"originalICY", "Original Mix"},
                                            {"shazamID", "123"},
                                            {"appleMusicURL", "https://music.apple.com/us/song/example/123"}};
    if (version >= 3)
        j["bookmarks"][0]["recognition"]["listening"] = {{"outputID", "44444444-4444-4444-8444-444444444444"},
                                                         {"revision", std::numeric_limits<uint64_t>::max()},
                                                         {"position", 12.25},
                                                         {"receivedAt", "2026-10-28T11:00:00Z"}};
    return j;
}
void rejects(Json j, const char *message) {
    bool failed = false;
    try {
        decodeExchange(bytes(j));
    } catch (const std::exception &) {
        failed = true;
    }
    check(failed, message);
}
} // namespace
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        check(validStreamURL("https://radio.example/a"), "https accepted");
        check(!validStreamURL("file:///tmp/a"), "file rejected");
        check(!validStreamURL("https://@radio.example/a"), "empty credentials rejected");
        check(!validStreamURL("https://user:pass@radio.example/a"), "credentials rejected");
        check(normalizedStreamURL("HTTPS://RADIO.EXAMPLE:443/Stream?q=Case") ==
                  "https://radio.example/Stream?q=Case",
              "normalization");
        check(normalizedStreamURL("https://radio.example/Stream") !=
                  normalizedStreamURL("https://radio.example/stream"),
              "path case retained");
        for (int version = 1; version <= 3; ++version) {
            auto j = example(version);
            const auto l = decodeExchange(bytes(j));
            check(l.stations.size() == 1 && l.groups.size() == 1 && l.bookmarks.size() == 1,
                  "valid version parsed");
            check(DataCodec::version(l) == version, "minimal version");
            if (version >= 2) {
                auto equivalent = l.bookmarks[0];
                equivalent.recognition["recognizedAt"] = "2026-10-28T13:00:05+01:00";
                equivalent.recognition["ignoredExtra"] = "ignored";
                check(comparableBookmarkJson(equivalent) == comparableBookmarkJson(l.bookmarks[0]),
                      "provenance equality compares time instants and known fields");
            }
            if (version == 3)
                check(l.bookmarks[0].recognition["listening"]["revision"].get<uint64_t>() ==
                          std::numeric_limits<uint64_t>::max(),
                      "UInt64 exact");
        }
        auto j = example();
        j["formatVersion"] = 4;
        rejects(j, "unknown version");
        j["formatVersion"] = uint64_t(4294967297ULL);
        rejects(j, "version integer overflow rejected");
        j = example(3);
        j["formatVersion"] = 2;
        rejects(j, "v2 listening invalid");
        j = example(2);
        j["formatVersion"] = 1;
        rejects(j, "v1 recognition invalid");
        j = example();
        j["stations"][0]["favorite"] = "yes";
        rejects(j, "wrong bool type");
        j = example();
        j["stations"][0]["id"] = "bad";
        rejects(j, "invalid UUID");
        j = example();
        j["groups"][0]["stationIDs"].push_back("11111111-1111-4111-8111-111111111111");
        rejects(j, "duplicate ref");
        j = example();
        j["groups"][0]["stationIDs"][0] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        rejects(j, "missing ref");
        j = example();
        j["bookmarks"][0]["heardAt"] = "2026-02-30T12:00:00Z";
        rejects(j, "invalid calendar");
        j = example(3);
        j["bookmarks"][0]["recognition"]["listening"].erase("receivedAt");
        rejects(j, "unpaired context");
        j = example(3);
        j["bookmarks"][0]["recognition"]["listening"]["revision"] = -1;
        rejects(j, "negative UInt64");
        j = example(2);
        j["bookmarks"][0]["recognition"]["appleMusicURL"] = "https://evil.example/song";
        rejects(j, "catalog host policy");
        j = example();
        j["stations"][0]["name"] = str(QString(129, QChar(0x00e4)));
        rejects(j, "UTF8 byte limit");
        bool fractional = true;
        try {
            date("2026-10-28T12:00:00.123456789Z");
        } catch (...) {
            fractional = false;
        }
        check(fractional, "nanosecond timestamps accepted");
        QTemporaryDir tmp;
        check(tmp.isValid(), "temporary directory");
        const auto fixture = tmp.filePath("incoming.json");
        write(fixture, bytes(example(3)));
        const auto root = tmp.filePath("data");
        QDir().mkpath(root);
        write(root + "/library.json", "{\"format\":\"mucke-baby-linux-library\",\"formatVersion\":1,"
                                      "\"stations\":[],\"groups\":[],\"bookmarks\":[]}");
        LibraryStore store(root);
        check(store.load(), "empty store loads");
        auto preview = store.previewImport(fixture);
        check(!preview.isEmpty(), "import preview");
        check(store.stations().isEmpty(), "preview no change");
        check(preview["counts"].toObject()["new"].toInt() == 3, "new counts");
        const auto beforeCancel = read(root + "/library.json");
        store.discardImport(preview);
        check(read(root + "/library.json") == beforeCancel, "cancel preserves exact file bytes");
        check(!store.applyImport(preview, {}), "cancelled preview cannot be applied");
        preview = store.previewImport(fixture);
        check(store.applyImport(preview, {}), "apply");
        check(store.stations().size() == 1 && store.groups().size() == 1 && store.bookmarks().size() == 1,
              "atomic library contents");
        check(store.bookmarks()[0].recognition["listening"]["revision"].get<uint64_t>() == UINT64_MAX,
              "stored UInt64 exact");
        const auto exported = tmp.filePath("out.json");
        check(store.exportLibrary(exported), "export");
        auto out = Json::parse(read(exported).toStdString());
        check(out["formatVersion"] == 3, "export V3");
        check(out["bookmarks"][0]["recognition"]["listening"]["revision"].get<uint64_t>() == UINT64_MAX,
              "export UInt64 exact");
        check(!store.exportLibrary(root + "/history.json"), "protected export");
        preview = store.previewImport(exported);
        check(preview["counts"].toObject()["unchanged"].toInt() == 3, "unchanged counts");
        check(store.applyImport(preview, {}), "unchanged import");
        check(store.saveSettings(
                  {{"recordingEnabled", false},
                   {"quickSlots", QJsonArray{QJsonValue::Null, QJsonValue::Null, QJsonValue::Null,
                                             QJsonValue::Null, QJsonValue::Null}}}),
              "initial settings");
        check(store.saveSettings({{"selectedTheme", "neon"}}), "settings patch");
        check(store.settings().contains("recordingEnabled") && store.settings()["selectedTheme"] == "neon",
              "settings merge");
        auto changed = example(3);
        changed["stations"][0]["name"] = "Imported rename";
        write(fixture, bytes(changed));
        preview = store.previewImport(fixture);
        check(preview["counts"].toObject()["conflict"].toInt() == 1, "conflict counts");
        check(store.applyImport(preview, {}), "local default");
        check(store.stations()[0].name == "Example Radio", "conflict local default");
        preview = store.previewImport(fixture);
        QJsonObject choices;
        choices["station:11111111-1111-4111-8111-111111111111"] = "both";
        check(store.applyImport(preview, choices), "keep both");
        check(store.stations().size() == 2 && store.stations()[0].id != store.stations()[1].id,
              "keep both fresh ID");
        preview = store.previewImport(fixture);
        auto s = store.stations()[0];
        s.favorite = true;
        check(store.saveStation(s), "edit after preview");
        check(!store.applyImport(preview, {}), "stale preview rejected");
        {
            LibraryStore other(root);
            check(!other.load(), "second writer read-only");
            s.name = "blocked";
            check(!other.saveStation(s), "second writer blocked");
        }
        Track t;
        t.raw = "Example Artist - Song";
        t.station = "Example Radio";
        t.receivedAt = QDateTime::currentDateTimeUtc().addSecs(-30);
        t.sessionID = newID();
        store.receiveTrack(t);
        check(store.history().size() == 1, "history receive");
        store.receiveTrack(t);
        check(store.history().size() == 1, "history dedup");
        store.endReception(QDateTime::currentDateTimeUtc());
        check(store.history()[0].endedAt.isValid(), "history ended");
        check(store.clearHistory() && store.history().isEmpty(), "clear history");
        check(store.stations().size() == 2 && store.bookmarks().size() == 1, "history clear isolated");
        const auto bytesBefore = read(root + "/library.json");
        write(root + "/library.json", bytesBefore + " ");
        s = store.stations()[0];
        s.name = "must not overwrite";
        check(!store.saveStation(s), "external change protected");
        check(read(root + "/library.json") == bytesBefore + " ", "external bytes intact");
        {
            const auto r = tmp.filePath("unknown");
            QDir().mkpath(r);
            write(r + "/library.json", "{\"format\":\"mucke-baby-linux-library\",\"formatVersion\":999}");
            LibraryStore unknown(r);
            check(!unknown.load(), "unknown local version blocked");
            check(read(r + "/library.json").contains("999"), "unknown version retained");
        }
        {
            const auto r = tmp.filePath("broken");
            QDir().mkpath(r);
            write(r + "/library.json", "{broken");
            LibraryStore broken(r);
            check(broken.load(), "corrupt backed up");
            check(QDir(r).entryList({"library.json.broken-*"}, QDir::Files).size() == 1,
                  "corrupt backup exists");
        }
        {
            const auto recordings = tmp.filePath("recordings");
            QDir().mkpath(recordings);
            const auto record = recordings + "/existing.mp3";
            write(record, "existing audio");
            check(store.saveSettings({{"recordingsDirectory", recordings}}), "recording directory setting");
            check(!store.exportLibrary(record), "recording export protected");
            check(read(record) == "existing audio", "recording contents retained");
            const auto hardlink = tmp.filePath("linked-library.json");
            check(::link(QFile::encodeName(root + "/library.json").constData(),
                         QFile::encodeName(hardlink).constData()) == 0,
                  "hardlink fixture");
            check(!store.exportLibrary(hardlink), "hardlink export protected");
            check(!store.saveSettings({{"quickSlots", QJsonArray{QJsonValue::Null}}}), "slot count guarded");
            check(!store.saveSettings({{"recordingEnabled", "yes"}}), "recording preference type guarded");
        }
        {
            auto legacy = example()["stations"];
            legacy[0].erase("id");
            const auto first = decodeExchange(bytes(legacy));
            check(first.stations.size() == 1 && !first.stations[0].id.isEmpty(), "legacy IDs assigned");
            Json collection = {{"formatVersion", 2},
                               {"stations", example()["stations"]},
                               {"groups", example()["groups"]},
                               {"quickSlots", Json::array({"11111111-1111-4111-8111-111111111111"})}};
            check(decodeExchange(bytes(collection)).groups.size() == 1, "Mac collection legacy import");
            check(groupIdentity("ＡＢＣ") == groupIdentity("abc"), "width folding");
            check(groupIdentity("²") != groupIdentity("2"), "unrelated compatibility chars stay distinct");
            auto plain = decodeExchange(bytes(example())).bookmarks[0];
            auto recognized = decodeExchange(bytes(example(2))).bookmarks[0];
            check(bookmarkIdentity(plain) != bookmarkIdentity(recognized),
                  "recognized original identity separated");
            auto mix = recognized;
            mix.recognition["originalICY"] = "A different mix";
            check(bookmarkIdentity(mix) != bookmarkIdentity(recognized), "radio mixes separated");
        }
        {
            const auto dir = tmp.filePath("bounded");
            QDir().mkpath(dir);
            Json history = Json::array();
            const auto start = QDateTime::currentDateTimeUtc().addSecs(-100000);
            for (int i = 0; i < 2001; ++i)
                history.push_back({{"id", str(newID())},
                                   {"station", "Example"},
                                   {"raw", "Track " + std::to_string(i)},
                                   {"start", timestamp(start.addSecs(i * 30))},
                                   {"end", timestamp(start.addSecs(i * 30 + 25))}});
            write(dir + "/history.json", bytes(history));
            LibraryStore bounded(dir);
            check(bounded.load(), "bounded history loads");
            check(bounded.history().size() == 2000 && bounded.history().front().raw == "Track 1",
                  "oldest excess history removed");
            const auto onDisk = Json::parse(read(dir + "/history.json").toStdString());
            check(onDisk.size() == 2000, "bounded history persisted");
        }
        QTextStream(stdout) << checks << " data contract checks passed\n";
        return 0;
    } catch (const std::exception &e) {
        QTextStream(stderr) << "Failed after " << checks << " checks: " << e.what() << "\n";
        return 1;
    }
}
