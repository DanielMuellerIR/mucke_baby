#include "../src/data/librarystore.h"
#include "../src/data/codec_p.h"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QTextStream>
#include <limits>
using namespace Mucke;
using namespace Mucke::DataCodec;
namespace {
void check(bool condition, const char *why) {
    if (!condition)
        throw std::runtime_error(why);
}
void write(const QString &path, const QByteArray &data) {
    QFile file(path);
    check(file.open(QIODevice::WriteOnly) && file.write(data) == data.size(), "fixture write");
}
QByteArray read(const QString &path) {
    QFile file(path);
    check(file.open(QIODevice::ReadOnly), "fixture read");
    return file.readAll();
}
QByteArray digest(const QString &path) {
    QFile file(path);
    check(file.open(QIODevice::ReadOnly), "digest open");
    QCryptographicHash hash(QCryptographicHash::Sha256);
    check(hash.addData(&file), "digest read");
    return hash.result();
}
void emptyLibrary(const QString &root) {
    QDir().mkpath(root);
    write(root + "/library.json", "{\"format\":\"mucke-baby-linux-library\",\"formatVersion\":1,\"stations\":"
                                  "[],\"groups\":[],\"bookmarks\":[]}");
}
QString fixtureID(int number) {
    return QString("00000000-0000-4000-8000-%1").arg(number, 12, 10, QLatin1Char('0'));
}
} // namespace
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        QTemporaryDir temporary;
        check(temporary.isValid(), "temporary directory");
        const auto root = temporary.filePath("large-history");
        emptyLibrary(root);
        Json fixture = Json::array();
        const auto start = date("2026-10-27T00:00:00Z");
        const std::string raw(4096, '"');
        for (int i = 0; i < 2000; ++i)
            fixture.push_back({{"id", str(fixtureID(i + 1))},
                               {"station", "Example"},
                               {"raw", raw},
                               {"artist", "A"},
                               {"title", "T"},
                               {"start", timestamp(start.addSecs(i * 30))},
                               {"end", timestamp(start.addSecs(i * 30 + 25))}});
        auto payload = bytes(fixture);
        check(payload.size() > 16 * 1024 * 1024, "fixture must exceed the old 16 MiB read limit");
        QTextStream(stdout) << "History fixture: " << payload.size() << " bytes, 2,000 valid records\n";
        write(root + "/history.json", payload);
        fixture = nullptr;
        payload.clear();
        const auto libraryBefore = read(root + "/library.json");
        {
            LibraryStore store(root);
            check(store.load(), "history larger than 16 MiB must load");
            check(store.history().size() == 2000, "all existing records load");
            Track track;
            track.id = fixtureID(3000);
            track.station = "Example";
            track.raw = "New track";
            track.receivedAt = QDateTime::currentDateTimeUtc().addSecs(-30);
            store.receiveTrack(track);
            check(store.history().size() == 2000 && store.history().last().id == track.id,
                  "append must persist with the existing 2000-entry policy");
            check(store.history().first().id == fixtureID(2),
                  "only the existing count policy removes the oldest entry");
            store.endReception(QDateTime::currentDateTimeUtc());
            check(store.history().last().endedAt.isValid(), "close reception must persist");
        }
        {
            LibraryStore reload(root);
            check(reload.load(), "updated large history must reload");
            check(reload.history().size() == 2000 && reload.history().last().id == fixtureID(3000),
                  "updated records survive reload");
            check(reload.history().last().endedAt.isValid(), "closed interval survives reload");
            const auto beforeInvalid = digest(root + "/history.json");
            Track invalid;
            invalid.id = fixtureID(3001);
            invalid.station = "Example";
            invalid.raw = QString(4097, 'x');
            invalid.receivedAt = QDateTime::currentDateTimeUtc();
            reload.receiveTrack(invalid);
            check(digest(root + "/history.json") == beforeInvalid &&
                      reload.history().last().id == fixtureID(3000),
                  "out-of-contract fields cannot replace history");
            check(reload.clearHistory(), "clear large history succeeds");
            check(reload.history().isEmpty() &&
                      Json::parse(read(root + "/history.json").toStdString()).empty(),
                  "clear persisted");
        }
        {
            LibraryStore boundedWriter(root);
            check(boundedWriter.load() && boundedWriter.history().isEmpty(),
                  "empty history for byte-gate check");
            const auto original = digest(root + "/history.json");
            Track oversized;
            oversized.id = fixtureID(4000);
            oversized.station = "Example";
            oversized.raw = "A - Song";
            oversized.receivedAt = QDateTime::currentDateTimeUtc();
            oversized.recognition = {{"source", "shazam"},
                                     {"recognizedAt", "2026-10-28T12:00:00Z"},
                                     {"stationID", str(fixtureID(1))},
                                     {"originalICY", "A - Song"},
                                     {"futureExtension", std::string(64 * 1024 * 1024, 'x')}};
            boundedWriter.receiveTrack(std::move(oversized));
            check(!boundedWriter.lastError().isEmpty(), "oversized serialized history reports failure");
            check(boundedWriter.history().isEmpty() && digest(root + "/history.json") == original,
                  "oversized serialization cannot replace the original or visible history");
        }
        {
            const std::string maximumURL = "https://music.apple.com/" + std::string(4096 - 24, 'x');
            Json maximumKnown = {{"id", str(fixtureID(1))},
                                 {"stationID", str(fixtureID(2))},
                                 {"sessionID", str(fixtureID(3))},
                                 {"station", std::string(256, '\"')},
                                 {"raw", std::string(4096, '\"')},
                                 {"artist", std::string(1024, '\"')},
                                 {"title", std::string(1024, '\"')},
                                 {"placeholder", true},
                                 {"start", "2026-10-28T12:00:00.000Z"},
                                 {"end", "2026-10-28T12:01:00.000Z"},
                                 {"recognition",
                                  {{"source", "shazam"},
                                   {"recognizedAt", "2026-10-28T12:00:00.000Z"},
                                   {"stationID", str(fixtureID(1))},
                                   {"originalICY", std::string(4096, '\"')},
                                   {"shazamID", std::string(256, '\"')},
                                   {"appleMusicURL", maximumURL},
                                   {"listening",
                                    {{"outputID", str(fixtureID(4))},
                                     {"revision", std::numeric_limits<uint64_t>::max()},
                                     {"position", std::numeric_limits<double>::max()},
                                     {"receivedAt", "2026-10-28T12:00:00.000Z"}}}}}};
            validateRecognition(maximumKnown["recognition"]);
            const auto maximumBytes = bytes(maximumKnown).size();
            check(maximumBytes < 31744 && 31744LL * 2000 + 2 < 64LL * 1024 * 1024,
                  "known-field upper bound must fit the history budget");
            QTextStream(stdout) << "Known-field fixture: " << maximumBytes
                                << " bytes per record; conservative bound 31,744\n";
        }
        check(read(root + "/library.json") == libraryBefore,
              "history changes must not alter library or bookmarks");
        {
            const auto oversizedRoot = temporary.filePath("oversized");
            emptyLibrary(oversizedRoot);
            const auto path = oversizedRoot + "/history.json";
            QFile file(path);
            check(file.open(QIODevice::WriteOnly), "oversized fixture open");
            check(file.resize(64LL * 1024 * 1024 + 1), "oversized sparse fixture");
            file.close();
            const auto before = digest(path);
            LibraryStore protectedStore(oversizedRoot);
            check(!protectedStore.load(), "history above the declared limit must be read-only");
            check(!protectedStore.clearHistory(),
                  "oversized original cannot be cleared through an unloaded store");
            check(QFileInfo(path).size() == 64LL * 1024 * 1024 + 1 && digest(path) == before,
                  "oversized original remains byte-for-byte intact");
            check(QDir(oversizedRoot).entryList({"history.json.broken-*"}, QDir::Files).isEmpty(),
                  "oversized original must not be moved");
        }
        QTextStream(stdout) << "History size regressions passed\n";
        return 0;
    } catch (const std::exception &error) {
        QTextStream(stderr) << "History size regression failed: " << error.what() << '\n';
        return 1;
    }
}
