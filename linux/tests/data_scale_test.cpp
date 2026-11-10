#include "../src/data/librarystore.h"
#include "../src/data/codec_p.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QTemporaryDir>
#include <QTextStream>
#include <limits>
#include <stdexcept>
using namespace Mucke;
using namespace Mucke::DataCodec;
namespace {
void check(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}
QString fixtureID(int value) {
    return QString("00000000-0000-4000-8000-%1").arg(value, 12, 10, QLatin1Char('0'));
}
void write(const QString &path, const QByteArray &data) {
    QFile file(path);
    check(file.open(QIODevice::WriteOnly) && file.write(data) == data.size(), "fixture write");
}
qint64 processMemory(const QString &field) {
    QFile status("/proc/self/status");
    if (!status.open(QIODevice::ReadOnly))
        return -1;
    for (const auto &line : status.readAll().split('\n')) {
        if (line.startsWith(field.toUtf8() + ':')) {
            const auto values = line.simplified().split(' ');
            return values.size() > 1 ? values[1].toLongLong() * 1024 : -1;
        }
    }
    return -1;
}
QJsonObject timedPreview(LibraryStore &store, const QString &path, const QString &label) {
    QElapsedTimer elapsed;
    elapsed.start();
    auto result = store.previewImport(path);
    const auto milliseconds = elapsed.elapsed();
    QTextStream(stdout) << label << " preview: " << milliseconds << " ms, RSS " << processMemory("VmRSS")
                        << " bytes\n";
    check(!result.isEmpty(), "preview failed");
    check(milliseconds < 10000, "preview exceeded the 10-second regression budget");
    return result;
}
void timedApply(LibraryStore &store, QJsonObject preview, QJsonObject choices, const QString &label) {
    QElapsedTimer elapsed;
    elapsed.start();
    const auto success = store.applyImport(preview, choices);
    const auto milliseconds = elapsed.elapsed();
    QTextStream(stdout) << label << " apply: " << milliseconds << " ms, RSS " << processMemory("VmRSS")
                        << " bytes\n";
    check(success, "apply failed");
    check(milliseconds < 10000, "apply exceeded the 10-second regression budget");
}
QJsonObject importedChoices(const QJsonObject &preview) {
    QJsonObject choices;
    for (const auto &value : preview["items"].toArray())
        choices[value.toObject()["key"].toString()] = "incoming";
    return choices;
}
Json maximumLibrary() {
    Json document = {
        {"format", "mucke-baby-library"}, {"formatVersion", 3},      {"exportedAt", "2026-10-28T12:00:00Z"},
        {"stations", Json::array()},      {"groups", Json::array()}, {"bookmarks", Json::array()}};
    for (int i = 0; i < 2000; ++i)
        document["stations"].push_back({{"id", str(fixtureID(i + 1))},
                                        {"name", "Radio " + std::to_string(i)},
                                        {"url", "https://radio.example/stream/" + std::to_string(i)}});
    for (int i = 0; i < 200; ++i) {
        Json ids = Json::array();
        for (int member = 0; member < 10; ++member)
            ids.push_back(str(fixtureID(i * 10 + member + 1)));
        document["groups"].push_back(
            {{"id", str(fixtureID(10000 + i))}, {"name", "Group " + std::to_string(i)}, {"stationIDs", ids}});
    }
    for (int i = 0; i < 20000; ++i)
        document["bookmarks"].push_back({{"id", str(fixtureID(100000 + i))},
                                         {"station", "Radio"},
                                         {"raw", "A - Song " + std::to_string(i)},
                                         {"artist", "A"},
                                         {"title", "Song " + std::to_string(i)},
                                         {"heardAt", "2026-10-28T12:00:00Z"},
                                         {"savedAt", "2026-10-28T12:00:01Z"}});
    document["bookmarks"][0]["recognition"] = {
        {"source", "shazam"},
        {"recognizedAt", "2026-10-28T12:00:05Z"},
        {"stationID", str(fixtureID(1))},
        {"originalICY", "Original Mix"},
        {"listening",
         {{"outputID", str(fixtureID(999999))}, {"revision", std::numeric_limits<uint64_t>::max()}}}};
    return document;
}
void verifyMaximum(const LibraryStore &store) {
    check(store.stations().size() == 2000 && store.groups().size() == 200 &&
              store.bookmarks().size() == 20000,
          "record counts changed");
    check(store.stations().first().id == fixtureID(1) && store.bookmarks().last().id == fixtureID(119999),
          "local UUIDs were replaced");
    check(store.groups().first().stationIDs.first() == fixtureID(1), "group reference remapping");
    check(store.bookmarks().first().recognition["listening"]["revision"].get<uint64_t>() == UINT64_MAX,
          "UInt64 provenance changed");
}
} // namespace
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        QTemporaryDir directory;
        check(directory.isValid(), "temporary directory");
        const auto root = directory.filePath("data");
        QDir().mkpath(root);
        write(root + "/library.json", "{\"format\":\"mucke-baby-linux-library\",\"formatVersion\":1,"
                                      "\"stations\":[],\"groups\":[],\"bookmarks\":[]}");
        LibraryStore store(root);
        check(store.load(), "empty store load");
        auto document = maximumLibrary();
        const auto path = directory.filePath("maximum.json");
        auto payload = bytes(document);
        QTextStream(stdout) << "Fixture: " << payload.size()
                            << " bytes, 2,000 stations + 200 groups + 20,000 bookmarks\n";
        check(payload.size() <= 8 * 1024 * 1024, "maximum fixture exceeds exchange limit");
        write(path, payload);
        auto preview = timedPreview(store, path, "new");
        check(preview["counts"].toObject()["new"].toInt() == 22200, "new record count");
        timedApply(store, preview, {}, "new");
        preview = {};
        verifyMaximum(store);
        qint64 warmedDiscardRSS = -1;
        for (int repeat = 0; repeat < 3; ++repeat) {
            auto discarded = timedPreview(store, path, QString("repeat %1").arg(repeat));
            check(discarded["counts"].toObject()["unchanged"].toInt() == 22200, "unchanged count");
            store.discardImport(discarded);
            check(!store.applyImport(discarded, {}), "discarded token survived");
            discarded = {};
            const auto discardedRSS = processMemory("VmRSS");
            QTextStream(stdout) << "After discard RSS " << discardedRSS << " bytes\n";
            if (repeat == 0)
                warmedDiscardRSS = discardedRSS;
            if (repeat == 2 && warmedDiscardRSS >= 0 && discardedRSS >= 0)
                check(discardedRSS <= warmedDiscardRSS + 32 * 1024 * 1024,
                      "discarded previews retain multiple large plans");
        }
        for (auto &station : document["stations"])
            station["name"] = station["name"].get<std::string>() + " updated";
        for (auto &group : document["groups"])
            group["name"] = group["name"].get<std::string>() + " updated";
        for (auto &bookmark : document["bookmarks"])
            bookmark["station"] = "Updated";
        write(path, bytes(document));
        preview = timedPreview(store, path, "same UUID update");
        check(preview["counts"].toObject()["conflict"].toInt() == 22200, "UUID update conflict count");
        timedApply(store, preview, importedChoices(preview), "same UUID update");
        preview = {};
        verifyMaximum(store);
        check(store.bookmarks().last().station == "Updated", "UUID update not applied");
        for (int i = 0; i < 2000; ++i) {
            document["stations"][i]["id"] = str(fixtureID(1000000 + i));
            document["stations"][i]["name"] = "Secondary " + std::to_string(i);
        }
        for (int i = 0; i < 200; ++i) {
            auto &group = document["groups"][i];
            group["id"] = str(fixtureID(2000000 + i));
            for (int m = 0; m < 10; ++m)
                group["stationIDs"][m] = str(fixtureID(1000000 + i * 10 + m));
        }
        for (int i = 0; i < 20000; ++i) {
            document["bookmarks"][i]["id"] = str(fixtureID(3000000 + i));
            document["bookmarks"][i]["station"] = "Secondary";
        }
        write(path, bytes(document));
        preview = timedPreview(store, path, "secondary matches");
        check(preview["counts"].toObject()["new"].toInt() == 0 &&
                  preview["counts"].toObject()["conflict"].toInt() == 22000 &&
                  preview["counts"].toObject()["unchanged"].toInt() == 200,
              "secondary matching counts");
        timedApply(store, preview, importedChoices(preview), "secondary matches");
        preview = {};
        verifyMaximum(store);
        check(store.bookmarks().last().station == "Secondary", "secondary update not applied");
        const auto exportPath = directory.filePath("roundtrip.json");
        check(store.exportLibrary(exportPath), "maximum export");
        QFile exported(exportPath);
        check(exported.open(QIODevice::ReadOnly), "roundtrip read");
        const auto roundtrip = decodeExchange(exported.readAll());
        check(roundtrip.bookmarks.size() == 20000 &&
                  roundtrip.bookmarks.first().recognition["listening"]["revision"].get<uint64_t>() ==
                      UINT64_MAX,
              "maximum roundtrip provenance");
        {
            const auto matchingRoot = directory.filePath("matching");
            QDir().mkpath(matchingRoot);
            write(matchingRoot + "/library.json",
                  "{\"format\":\"mucke-baby-linux-library\",\"formatVersion\":1,\"stations\":[],\"groups\":[]"
                  ",\"bookmarks\":[]}");
            LibraryStore matching(matchingRoot);
            check(matching.load(), "matching store load");
            Json local = {{"format", "mucke-baby-library"},
                          {"formatVersion", 1},
                          {"exportedAt", "2026-10-28T12:00:00Z"},
                          {"stations", Json::array()},
                          {"groups", Json::array()},
                          {"bookmarks", Json::array()}};
            for (int i = 0; i < 3; ++i) {
                local["stations"].push_back(
                    {{"id", str(fixtureID(10 + i))},
                     {"name", "Local " + std::to_string(i)},
                     {"url", i < 2 ? "https://radio.example/duplicate" : "https://radio.example/unique"}});
                local["bookmarks"].push_back({{"id", str(fixtureID(30 + i))},
                                              {"station", "Local"},
                                              {"raw", i < 2 ? "A - Duplicate" : "A - Unique"},
                                              {"artist", "A"},
                                              {"title", i < 2 ? "Duplicate" : "Unique"},
                                              {"heardAt", "2026-10-28T12:00:00Z"},
                                              {"savedAt", "2026-10-28T12:00:01Z"}});
            }
            write(path, bytes(local));
            auto initial = matching.previewImport(path);
            check(matching.applyImport(initial, {}), "matching fixture import");
            auto incoming = local;
            incoming["stations"].erase(incoming["stations"].begin() + 2);
            incoming["bookmarks"].erase(incoming["bookmarks"].begin() + 2);
            for (int i = 0; i < 2; ++i) {
                incoming["stations"][i]["id"] = str(fixtureID(100 + i));
                incoming["bookmarks"][i]["id"] = str(fixtureID(130 + i));
            }
            write(path, bytes(incoming));
            auto ambiguous = matching.previewImport(path);
            check(ambiguous["counts"].toObject()["new"].toInt() == 4, "ambiguous identities must remain new");
            matching.discardImport(ambiguous);
            incoming = local;
            incoming["stations"] = Json::array({local["stations"][0]});
            incoming["bookmarks"] = Json::array({local["bookmarks"][0]});
            incoming["stations"][0]["url"] = local["stations"][2]["url"];
            incoming["bookmarks"][0]["title"] = "Unique";
            write(path, bytes(incoming));
            auto priority = matching.previewImport(path);
            check(priority["counts"].toObject()["conflict"].toInt() == 2,
                  "UUIDs take priority over different identity matches");
            check(matching.applyImport(priority, importedChoices(priority)), "UUID priority apply");
            check(matching.stations()[0].url.endsWith("/unique") && matching.bookmarks()[0].title == "Unique",
                  "UUID priority targeted the wrong local row");
            // Der folgende Datensatz benötigt wieder genau einen eindeutigen Sekundärschlüssel.
            local["stations"][0]["url"] = "https://radio.example/other";
            local["bookmarks"][0]["title"] = "Other";
            write(path, bytes(local));
            auto reset = matching.previewImport(path);
            check(matching.applyImport(reset, importedChoices(reset)), "matching reset");
            incoming = local;
            incoming["stations"] = Json::array({local["stations"][2], local["stations"][2]});
            incoming["bookmarks"] = Json::array({local["bookmarks"][2], local["bookmarks"][2]});
            incoming["stations"][0]["id"] = str(fixtureID(999));
            incoming["stations"][1]["url"] = "https://radio.example/replaced";
            incoming["bookmarks"][0]["id"] = str(fixtureID(998));
            incoming["bookmarks"][1]["title"] = "Replaced";
            write(path, bytes(incoming));
            auto reserved = matching.previewImport(path);
            check(reserved["counts"].toObject()["new"].toInt() == 2 &&
                      reserved["counts"].toObject()["conflict"].toInt() == 2,
                  "secondary matches must not steal reserved UUID matches");
            auto replacement = matching.previewImport(path);
            check(!matching.applyImport(reserved, {}), "new preview must invalidate the previous token");
            matching.discardImport(replacement);
        }
        QTextStream(stdout) << "Peak RSS " << processMemory("VmHWM") << " bytes; scale regressions passed\n";
        return 0;
    } catch (const std::exception &e) {
        QTextStream(stderr) << "Scale regression failed: " << e.what() << '\n';
        return 1;
    }
}
