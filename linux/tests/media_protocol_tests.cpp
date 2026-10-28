#include "../src/media/streamprotocol.h"
#include "../src/media/recorder.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrl>
#include <iostream>
#include <cstdlib>
#include <sys/resource.h>
#include <csignal>

using namespace Mucke::MediaPrivate;
static void require(bool value, const char *message) { if (!value) { std::cerr << message << '\n'; std::exit(1); } }
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    require(needsResolution(QUrl("https://example.test/list.pls?hint=.m3u8")), "Playlist path classification");
    require(!needsResolution(QUrl("https://pls.example.test/audio?hint=.pls")), "Host/query must not classify playlists");
    require(playlistTarget("[playlist]\nFilename=http://bad.test/\nFile1=https://good.test/live\n").host() == "good.test", "Exact PLS key");
    require(playlistTarget("#EXTM3U\nfile:///etc/passwd\nhttps://good.test/live").host() == "good.test", "M3U URL policy");
    require(playlistTarget("<asx><entry><ref href=\"https://good.test/live\"/></entry></asx>").host() == "good.test", "ASX target");
    QByteArray utf16 = QByteArray::fromHex("fffe"); for (char byte : QByteArray("<asx><entry><ref href='https://good.test/live'/></entry></asx>")) { utf16.append(byte); utf16.append(char(0)); }
    require(playlistTarget(utf16).host() == "good.test", "UTF-16 ASX target");
    require(playlistTarget("<playlist xmlns=\"http://xspf.org/ns/0/\"><trackList><track><location>https://good.test/live?a=1&amp;b=2</location></track></trackList></playlist>").query() == "a=1&b=2", "Namespaced XSPF target");
    require(playlistTarget("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><asx><entry><ref href='https://good.test/'/></entry></asx>").isEmpty(), "DTD rejection");
    require(playlistTarget("<asx><entry><ref href='https://good.test/'/></entry>").isEmpty(), "Malformed XML must fail closed");
    require(playlistTarget(QByteArray(65537, 'a')).isEmpty(), "Playlist size bound");
    QByteArray metadata("StreamTitle='Artist - Title';"); metadata.append(QByteArray((16 - metadata.size() % 16) % 16, '\0'));
    QByteArray wire("abcd"); wire.append(char(metadata.size() / 16)); wire.append(metadata); wire.append("efgh"); wire.append(char(0));
    QByteArray audio; QStringList titles;
    ICYParser parser(4);
    for (char value : wire) parser.feed(QByteArray(1, value), [&](auto value) { audio.append(value); }, [&](auto value) { titles.append(value); });
    require(audio == "abcdefgh" && titles == QStringList{"Artist - Title"}, "Fragmented ICY must strip metadata exactly");
    require(decodeText(QByteArray::fromHex("93fa967b")) == QString::fromUtf8("日本"), "CP932 fallback");
    require(safeExportName("../bad\\path:name") == "_bad_path_name", "Export names cannot traverse");
    QTemporaryDir directory; require(directory.isValid(), "Temporary directory");
    {
        Recorder recorder(directory.path()); recorder.initialize(); recorder.beginSession("Fixture", "test-session");
        QByteArray mp3(32768, 'x'); mp3[0] = char(0xff); mp3[1] = char(0xfb);
        recorder.audio(mp3); require(recorder.list().isEmpty(), "Recording defaults off");
        recorder.setEnabled(true); recorder.audio(mp3);
        require(recorder.active(), "Recording fixture starts (requires 10 GiB free)");
        auto entry = recorder.list().first(); require(entry.bytes == mp3.size(), "Audio byte accounting");
        require(!recorder.remove(entry.id), "Active recording deletion blocked");
        recorder.title("Fixture title"); recorder.finish(); require(recorder.list().first().bytes == mp3.size(), "Finish preserves length");
        require(QFileInfo(recorder.checkedPath(entry.id)).size() == mp3.size(), "Physical audio length");
    }
    {
        Recorder recovered(directory.path()); recovered.initialize(); require(recovered.list().size() == 1, "Index recovery");
        auto entry = recovered.list().first(); require(!entry.active && entry.bytes == 32768, "Recovery never truncates");
        require(recovered.remove(entry.id), "Completed recording deletion");
    }
    QTemporaryDir corrupt;
    QFile file(QDir(corrupt.path()).filePath("index.json")); require(file.open(QIODevice::WriteOnly), "Corrupt index fixture"); file.write("invalid-index"); file.close();
    {
        Recorder recorder(corrupt.path()); recorder.initialize(); recorder.beginSession("Fixture", "corrupt"); recorder.setEnabled(true); recorder.audio(QByteArray::fromHex("fffb") + QByteArray(100, 'a'));
        require(!recorder.active(), "Corrupt index cannot be overwritten by recording");
    }
    require(file.open(QIODevice::ReadOnly) && file.readAll() == "invalid-index", "Corrupt index preserved");
    QTemporaryDir writeFailure;
    {
        Recorder recorder(writeFailure.path()); recorder.initialize(); recorder.beginSession("Fixture", "write-failure"); recorder.setEnabled(true);
        struct rlimit previous{}; require(::getrlimit(RLIMIT_FSIZE, &previous) == 0, "Read file-size limit");
        auto signalHandler = std::signal(SIGXFSZ, SIG_IGN);
        bool limitApplied = false, observedEmptyOpenFile = false, advertisedActive = false;
        recorder.changed = [&] {
            advertisedActive = advertisedActive || recorder.active();
            if (!observedEmptyOpenFile && !recorder.list().isEmpty() && recorder.list().first().active && recorder.list().first().bytes == 0) {
                observedEmptyOpenFile = true; struct rlimit blocked = previous; blocked.rlim_cur = 0;
                require(::setrlimit(RLIMIT_FSIZE, &blocked) == 0, "Inject recording write failure"); limitApplied = true;
            } else if (limitApplied) { require(::setrlimit(RLIMIT_FSIZE, &previous) == 0, "Restore file-size limit"); limitApplied = false; }
        };
        recorder.audio(QByteArray::fromHex("fffb") + QByteArray(100, 'a'));
        if (limitApplied) ::setrlimit(RLIMIT_FSIZE, &previous);
        std::signal(SIGXFSZ, signalHandler);
        require(observedEmptyOpenFile && !advertisedActive && !recorder.active(), "Zero-byte/write-failed recording must never be advertised active");
        require(recorder.list().size() == 1 && !recorder.list().first().active && recorder.list().first().bytes == 0, "Write failure closes its empty file");
    }
    std::cout << "media protocol/recorder fixtures passed\n";
}
