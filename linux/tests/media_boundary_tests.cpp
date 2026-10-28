#include "../src/media/recorder.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QDir>
#include <iostream>
#include <cstdlib>
#include <unistd.h>
using namespace Mucke;
using namespace Mucke::MediaPrivate;
static void check(bool value, const char *message) { if (!value) { std::cerr << message << '\n'; std::exit(1); } }
static Track track(QString id, QString raw, QDateTime date) { Track t; t.id = id; t.raw = raw; t.title = raw; t.sessionID = "session"; t.receivedAt = date; return t; }
static QByteArray oggPage(QByteArray packet) {
    QByteArray page(27, '\0'); page.replace(0, 4, "OggS"); page[26] = 1; page.append(char(packet.size())); page.append(packet); return page;
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); QTemporaryDir directory;
    QDateTime time = QDateTime::fromString("2028-02-28T23:59:50.000Z", Qt::ISODateWithMs);
    QString firstID, secondID;
    QByteArray mp3 = QByteArray::fromHex("fffb") + QByteArray(32766, 'a');
    {
        Recorder recorder(directory.path(), [&] { return time; }); recorder.initialize(); recorder.beginSession("Fixture", "session");
        const Track a = track("track-a", "Artist - First", time); recorder.title(a); recorder.setEnabled(true); recorder.audio(mp3);
        check(recorder.active(), "Initial recording active after bytes"); firstID = recorder.list().first().id;
        auto boundaries = recorder.songBoundaries();
        check(boundaries.size() == 1 && boundaries[0].recordingID == firstID && boundaries[0].trackID == a.id && boundaries[0].byteOffset == 0 && boundaries[0].captureStart && boundaries[0].partialStart, "Mid-song capture begins at byte0 and remains partial");
        time = time.addSecs(86401); recorder.audio(mp3);
        check(recorder.list().size() == 1, "24h waits for song boundary");
        const Track b = track("track-b", "Artist - Second", time); recorder.title(b);
        check(recorder.list().size() == 2 && !recorder.active() && recorder.list()[1].active && recorder.list()[1].bytes == 0, "Rollover does not advertise empty new file active");
        check(recorder.list()[1].file.startsWith("20280229T"), "Rollover filename uses correct leap-day calendar"); secondID = recorder.list()[1].id;
        boundaries = recorder.songBoundaries();
        check(boundaries.size() == 2 && boundaries[1].recordingID == firstID && boundaries[1].trackID == b.id && boundaries[1].byteOffset == 2 * mp3.size(), "Old file receives terminal next-title boundary at EOF");
        recorder.audio(mp3); boundaries = recorder.songBoundaries();
        check(recorder.active() && boundaries.size() == 3 && boundaries[2].recordingID == secondID && boundaries[2].trackID == b.id && boundaries[2].byteOffset == 0 && boundaries[2].captureStart && !boundaries[2].partialStart, "New song byte0 anchor is committed only after successful write");
        check(recorder.openReadFD(secondID) < 0, "Active source cannot be pinned for export");
        time = time.addSecs(30); const Track c = track("track-c", "Artist - Third", time); recorder.title(c); recorder.finish();
        const int descriptor = recorder.openReadFD(secondID); check(descriptor >= 0, "Completed source can be pinned"); ::close(descriptor);
    }
    {
        Recorder recovered(directory.path()); recovered.initialize(); const auto boundaries = recovered.songBoundaries();
        check(boundaries.size() == 4 && boundaries[0].trackID == "track-a" && boundaries[2].trackID == "track-b" && boundaries[3].trackID == "track-c", "Typed track IDs and boundaries recover unchanged");
        check(recovered.remove(firstID) && recovered.songBoundaries().size() == 2, "Recording deletion removes only its own boundaries");
    }
    const QByteArray flac = QByteArray("fLaC") + QByteArray::fromHex("80000022") + QByteArray(34, '\0') + QByteArray(32, 'a');
    QByteArray opusHead("OpusHead"); opusHead.append(QByteArray(11, '\0')); opusHead[8] = 1; opusHead[9] = 2;
    const QByteArray ogg = oggPage(opusHead) + oggPage(QByteArray("OpusTags") + QByteArray(8, '\0'));
    for (const QByteArray &header : {flac, ogg}) {
        QTemporaryDir temporary; time = QDateTime::fromString("2026-10-01T00:00:00.000Z", Qt::ISODateWithMs);
        Recorder recorder(temporary.path(), [&] { return time; }); recorder.initialize(); recorder.beginSession("Fixture", "session"); recorder.setEnabled(true); recorder.audio(header);
        check(recorder.active(), "Complete FLAC/Ogg headers start capture");
        time = time.addSecs(86401); recorder.title(track("changed", "Next song", time));
        check(!recorder.active() && recorder.rolloverNeedsHeader() && recorder.needsFreshHeader() && recorder.list().size() == 1, "FLAC/Ogg rollover requests fresh receiver header");
        recorder.audio(header); check(recorder.list().size() == 1, "Midstream header cannot silently append a new container");
        recorder.beginSession("Fixture", "fresh-receiver"); recorder.audio(header);
        check(recorder.active() && !recorder.rolloverNeedsHeader() && recorder.list().size() == 2, "Fresh receiver starts next FLAC/Ogg file without altering prior data");
    }
    std::cout << "media boundaries: track IDs, capture/partial flags, leap-day24h rollover, deferred first write, FLAC/Ogg header restart passed\n";
}
