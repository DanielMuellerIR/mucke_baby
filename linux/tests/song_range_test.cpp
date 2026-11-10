#include "../src/export/songrangeresolver.h"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QEventLoop>
#include <QElapsedTimer>
#include <QFile>
#include <QProcess>
#include <QTemporaryDir>
#include <QTimer>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>
using namespace Mucke;
namespace {
int checks = 0;
void check(bool ok, const char *reason) { ++checks; if (!ok) throw std::runtime_error(reason); }
QByteArray run(const QString &program, const QStringList &args) {
    QProcess p; p.start(program, args); check(p.waitForFinished(30000), "fixture process timeout");
    if (p.exitCode()) qCritical().noquote() << p.readAllStandardError();
    check(p.exitStatus() == QProcess::NormalExit && p.exitCode() == 0, "fixture process failed"); return p.readAllStandardOutput();
}
QByteArray read(const QString &path) { QFile f(path); check(f.open(QIODevice::ReadOnly), "read fixture"); return f.readAll(); }
QByteArray hash(const QString &path) { return QCryptographicHash::hash(read(path), QCryptographicHash::Sha256); }
QVector<SongExportProposal> prepare(SongRangeResolver &resolver, QString request, QVector<Track> tracks, QVector<Recording> recordings,
                                    QVector<RecordingBoundary> boundaries, bool cancel = false) {
    QEventLoop loop; QVector<SongExportProposal> result; bool done = false;
    auto connection = QObject::connect(&resolver, &SongRangeResolver::prepared, &loop, [&](QString id, auto proposals) {
        if (id == request) { done = true; result = proposals; loop.quit(); }
    });
    QTimer timer; timer.setSingleShot(true); QObject::connect(&timer, &QTimer::timeout, &loop, &QEventLoop::quit); timer.start(15000);
    resolver.prepare(request, tracks, recordings, boundaries);
    if (cancel) resolver.cancel(request);
    if (!done) loop.exec();
    QObject::disconnect(connection); check(done, "resolver timed out"); return result;
}
struct Packet { qint64 pos; double pts; };
QVector<Packet> packets(const QString &path) {
    const auto out = run("ffprobe", {"-v", "error", "-select_streams", "a:0", "-show_packets", "-show_entries", "packet=pos,pts_time", "-of", "compact=p=0", path});
    QVector<Packet> result;
    for (const auto &line : out.split('\n')) {
        qint64 pos = -1; double pts = 0;
        for (const auto &field : line.split('|')) {
            if (field.startsWith("pos=")) pos = field.mid(4).toLongLong();
            if (field.startsWith("pts_time=")) pts = field.mid(9).toDouble();
        }
        if (pos >= 0) result.push_back({pos, pts});
    }
    return result;
}
qint64 marker(const QVector<Packet> &ps, double seconds) {
    for (const auto &p : ps) if (p.pts >= seconds) return p.pos;
    throw std::runtime_error("marker packet missing");
}
double energy(const QByteArray &pcm, double frequency) {
    const int count = pcm.size() / 4;
    const int begin = count / 3, end = count * 2 / 3;
    double real = 0, imag = 0;
    for (int i = begin; i < end; ++i) {
        float sample; std::memcpy(&sample, pcm.constData() + i * 4, 4);
        real += sample * std::cos(2 * M_PI * frequency * i / 8000);
        imag += sample * std::sin(2 * M_PI * frequency * i / 8000);
    }
    return real * real + imag * imag;
}
void codecCase(const QString &root, const QString &codec, const QString &extension, const QStringList &options) {
    const QString path = root + "/phases." + extension;
    QStringList args = {"-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        "-f", "lavfi", "-i", "sine=frequency=880:duration=1", "-f", "lavfi", "-i", "sine=frequency=1320:duration=1",
        "-filter_complex", "[0:a][1:a][2:a]concat=n=3:v=0:a=1[a]", "-map", "[a]", "-c:a", codec};
    args += options; args += {"-y", path}; run("ffmpeg", args);
    const auto original = hash(path); const auto ps = packets(path);
    Track track; track.id = "song"; track.raw = "Artist - Song"; track.artist = "Artist"; track.title = "Song";
    track.station = "Station"; track.sessionID = "session"; track.receivedAt = QDateTime::fromString("2026-10-28T10:00:01Z", Qt::ISODate);
    Recording recording; recording.id = "recording"; recording.file = QFileInfo(path).fileName(); recording.sessionID = track.sessionID;
    recording.bytes = QFileInfo(path).size(); recording.start = track.receivedAt.addSecs(-1); recording.end = track.receivedAt.addSecs(2);
    RecordingBoundary start; start.recordingID = recording.id; start.trackID = track.id; start.raw = track.raw; start.receivedAt = track.receivedAt; start.byteOffset = marker(ps, 1);
    RecordingBoundary end = start; end.trackID = "next"; end.raw = "Next"; end.byteOffset = marker(ps, 2); end.receivedAt = end.receivedAt.addSecs(1);
    SongRangeResolver resolver(root);
    auto result = prepare(resolver, "first", {track}, {recording}, {start, end});
    check(result.size() == 1, "one proposal");
    auto proposal = result.first();
    if (proposal.status != SongAudioStatus::Available && proposal.status != SongAudioStatus::Approximate)
        qCritical().noquote() << codec << proposal.explanation;
    check(proposal.status == SongAudioStatus::Available || proposal.status == SongAudioStatus::Approximate, "codec is supported");
    check(proposal.suggestedStart >= 0 && proposal.suggestedEnd <= proposal.audioEnd && proposal.suggestedEnd > proposal.suggestedStart, "finite audio range");
    check(resolver.validate(proposal), "issued proposal validates");
    auto forged = proposal; forged.suggestedStart += .001; check(!resolver.validate(forged), "modified proposal rejected");
    const auto pcm = run("ffmpeg", {"-hide_banner", "-loglevel", "error", "-ss", QString::number(proposal.suggestedStart, 'f', 6), "-i", path,
        "-t", QString::number(proposal.suggestedEnd - proposal.suggestedStart, 'f', 6), "-f", "f32le", "-ac", "1", "-ar", "8000", "pipe:1"});
    check(pcm.size() > 1000, "decoded excerpt");
    check(proposal.suggestedStart <= 1.4 && proposal.suggestedEnd >= 1.6, "suggestion retains known middle marker");
    const auto middle = pcm.mid(int((1.4 - proposal.suggestedStart) * 8000) * 4, 1600 * 4);
    check(energy(middle, 880) > energy(middle, 440) * 50 && energy(middle, 880) > energy(middle, 1320) * 50, "independent decoded marker at fixed source time matches");
    if (extension == "ogg" || extension == "opus") check(proposal.status == SongAudioStatus::Approximate &&
        (proposal.startUpper > proposal.startLower || proposal.endUpper > proposal.endLower), "Ogg page uncertainty is disclosed");
    // Empfangszeiten ändern weder Paketpositionen noch Schnittvorschläge.
    track.receivedAt = track.receivedAt.addSecs(10000); start.receivedAt = start.receivedAt.addSecs(-1000); end.receivedAt = end.receivedAt.addSecs(9999);
    result = prepare(resolver, "catchup", {track}, {recording}, {start, end});
    check(result.first().suggestedStart == proposal.suggestedStart && result.first().suggestedEnd == proposal.suggestedEnd, "catch-up receipts do not shift cuts");
    result = prepare(resolver, "missing", {track}, {recording}, {}); check(result.first().status == SongAudioStatus::MissingBoundaries, "missing boundaries never use clock fallback");
    recording.active = true; result = prepare(resolver, "active", {track}, {recording}, {start, end}); check(result.first().status == SongAudioStatus::ActiveRecording, "active recordings rejected"); recording.active = false;
    start.partialStart = true; result = prepare(resolver, "partial", {track}, {recording}, {start});
    check(result.first().partialStart && result.first().partialEnd, "partial start and end retained");
    result = prepare(resolver, "cancel", {track}, {recording}, {start, end}, true);
    check(result.first().status == SongAudioStatus::Failed, "cancel completes with explicit failure");
    result = prepare(resolver, "latest", {track}, {recording}, {start, end}); proposal = result.first();
    check(resolver.validate(proposal), "proposal validates before replacement");
    check(hash(path) == original, "analysis does not mutate source bytes");
    const auto old = path + ".old"; check(QFile::rename(path, old), "move old source"); check(QFile::copy(old, path), "replace identical bytes");
    check(!resolver.validate(proposal), "identical-byte inode replacement invalidates proposal");
    result = prepare(resolver, "new-inode", {track}, {recording}, {start, end}); check(resolver.validate(result.first()), "replacement can be reprobed");
    const auto hard = root + "/hard." + extension; check(::link(QFile::encodeName(path).constData(), QFile::encodeName(hard).constData()) == 0, "hard link fixture");
    check(!resolver.validate(result.first()), "hard linked source invalidates proposal"); check(QFile::remove(hard), "remove hard link fixture");
    check(QFile::remove(path), "remove source"); check(QFile::link(old, path), "symlink fixture");
    result = prepare(resolver, "symlink", {track}, {recording}, {start, end}); check(result.first().status == SongAudioStatus::MissingFile, "symlink source rejected");
    check(QFile::remove(path), "remove symlink");
    recording.file = "../escape";
    result = prepare(resolver, "traversal", {track}, {recording}, {start, end}); check(result.first().status == SongAudioStatus::MissingFile, "path traversal rejected");
    qInfo().noquote() << extension << "passed; marker range" << proposal.suggestedStart << proposal.suggestedEnd << "audio duration" << proposal.audioEnd;
}
void asyncCases(const QString &root) {
    const auto bin = root + "/bin"; check(QDir().mkdir(bin), "fake probe directory");
    const auto executable = bin + "/ffprobe";
    auto script = [&](const QByteArray &body) {
        QFile f(executable); check(f.open(QIODevice::WriteOnly | QIODevice::Truncate), "write fake probe");
        check(f.write("#!/bin/sh\n" + body) > 0, "write fake probe bytes"); f.close();
        check(f.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner), "fake probe executable");
    };
    QFile file(root + "/async.mp3"); check(file.open(QIODevice::WriteOnly), "async source"); check(file.write(QByteArray(100, 'a')) == 100, "async source bytes"); file.close();
    Track track; track.id = "async-song"; track.raw = "Async"; track.sessionID = "async-session";
    Recording recording; recording.id = "async-recording"; recording.file = "async.mp3"; recording.bytes = 100; recording.sessionID = track.sessionID;
    RecordingBoundary a; a.recordingID = recording.id; a.trackID = track.id; a.byteOffset = 25;
    RecordingBoundary b = a; b.trackID = "next"; b.byteOffset = 75;
    const auto originalPath = qgetenv("PATH"); qputenv("PATH", QFile::encodeName(bin) + ":" + originalPath);
    script("exec /bin/sleep 10\n");
    {
        SongRangeResolver resolver(root); QElapsedTimer elapsed; elapsed.start();
        QTimer::singleShot(100, &resolver, [&] { resolver.cancel("running-cancel"); });
        auto result = prepare(resolver, "running-cancel", {track}, {recording}, {a, b});
        check(result.first().status == SongAudioStatus::Failed && elapsed.elapsed() < 2000, "running probe cancels without blocking event loop");
    }
    const QByteArray good = "printf '%s\\n' 'packet|pts_time=0|duration_time=1|size=50|pos=0' 'packet|pts_time=1|duration_time=1|size=50|pos=50' 'stream|codec_name=mp3|sample_rate=44100|start_time=0|duration=2'\n";
    script(good + "/bin/sleep 0.3\n");
    {
        SongRangeResolver resolver(root);
        QTimer::singleShot(100, &resolver, [&] {
            QFile changed(root + "/async.mp3"); check(changed.open(QIODevice::ReadWrite), "mutate probing source"); changed.write("b");
        });
        auto result = prepare(resolver, "changed", {track}, {recording}, {a, b});
        check(result.first().status == SongAudioStatus::MissingFile, "source mutation during probe is rejected");
    }
    script("printf '%s\\n' 'packet|pts_time=0|duration_time=1|size=50|pos=N/A' 'stream|codec_name=mp3|sample_rate=44100|start_time=0|duration=2'\n");
    {
        SongRangeResolver resolver(root);
        auto result = prepare(resolver, "no-position", {track}, {recording}, {a, b});
        check(result.first().status == SongAudioStatus::Unsupported, "missing packet positions fail honestly");
    }
    script("printf '%s\\n' 'packet|pts_time=1|duration_time=1|size=50|pos=50' 'packet|pts_time=0|duration_time=1|size=50|pos=0' 'stream|codec_name=mp3|sample_rate=44100|start_time=0|duration=2'\n");
    {
        SongRangeResolver resolver(root);
        auto result = prepare(resolver, "reversed", {track}, {recording}, {a, b});
        check(result.first().status == SongAudioStatus::Unsupported, "reversed packet positions fail honestly");
    }
    script(good);
    {
        SongRangeResolver resolver(root);
        auto result = prepare(resolver, "within-frame", {track}, {recording}, {a, b});
        const auto p = result.first();
        check(p.status == SongAudioStatus::Approximate && p.startLower == 0 && p.startUpper == 1 && p.endLower == 1 && p.endUpper == 2, "inside-frame byte boundaries yield packet intervals, no interpolation");
        auto legacy = a; legacy.trackID.clear(); legacy.raw = track.raw; legacy.receivedAt = QDateTime::currentDateTimeUtc(); track.receivedAt = legacy.receivedAt;
        result = prepare(resolver, "legacy", {track}, {recording}, {legacy, b});
        check(result.first().status == SongAudioStatus::Approximate, "unique legacy raw and receipt can match");
        legacy.receivedAt = legacy.receivedAt.addMSecs(1);
        result = prepare(resolver, "legacy-mismatch", {track}, {recording}, {legacy, b});
        check(result.first().status == SongAudioStatus::MissingBoundaries, "legacy receipt mismatch never guesses");
    }
    // Ein langes Aufnahmefile darf mit nur einem gewählten Titel weiter funktionieren.
    check(file.open(QIODevice::WriteOnly | QIODevice::Truncate), "large marker source");
    check(file.write(QByteArray(10000, 'c')) == 10000, "large marker source bytes"); file.close(); recording.bytes = 10000;
    const QByteArray largeProbe = "printf '%s\\n' 'packet|pts_time=0|duration_time=1|size=5000|pos=0' 'packet|pts_time=1|duration_time=1|size=5000|pos=5000' 'stream|codec_name=mp3|sample_rate=44100|start_time=0|duration=2'\n";
    script(largeProbe);
    {
        SongRangeResolver resolver(root); QVector<RecordingBoundary> markers;
        for (int i = 1; i <= 200; ++i) {
            auto marker = a; marker.byteOffset = i; marker.trackID = i == 25 ? track.id : QString("other-%1").arg(i); markers.push_back(marker);
        }
        auto result = prepare(resolver, "many-markers", {track}, {recording}, markers);
        check(result.first().status == SongAudioStatus::Approximate, ">100 stored markers with one selected track works");
        script("exit 42\n");
        track.id = "other-100";
        result = prepare(resolver, "reuse-unselected-marker", {track}, {recording}, markers);
        check(result.first().status == SongAudioStatus::Approximate, "cached unselected marker reuses single file scan");
        script(largeProbe);
        for (int i = 201; i <= 4096; ++i) {
            auto marker = a; marker.byteOffset = i; marker.trackID = QString("other-%1").arg(i); markers.push_back(marker);
        }
        result = prepare(resolver, "maximum-markers", {track}, {recording}, markers);
        check(result.first().status == SongAudioStatus::Approximate, "4096 marker limit is supported");
        auto extra = a; extra.byteOffset = 4097; extra.trackID = "over-limit"; markers.push_back(extra);
        result = prepare(resolver, "over-marker-limit", {track}, {recording}, markers);
        check(result.first().status == SongAudioStatus::Unsupported, "marker map is hard bounded");
    }
    // 250000 Pakete: kein Paketarray im Resolver und weiterhin laufende Engine-Timer.
    check(file.open(QIODevice::WriteOnly | QIODevice::Truncate), "streaming source");
    check(file.resize(1000000), "streaming source size"); file.close(); recording.bytes = 1000000;
    a.trackID = track.id; a.byteOffset = 250000; b.byteOffset = 750000;
    script("exec /usr/bin/python3 -c 'import sys\nfor i in range(250000): print(\"packet|pts_time=%.2f|duration_time=0.01|size=4|pos=%d\" % (i/100, i*4))\nprint(\"stream|codec_name=mp3|sample_rate=44100|start_time=0|duration=2500\")'\n");
    {
        SongRangeResolver resolver(root); QElapsedTimer elapsed; elapsed.start(); qint64 previous = 0, largestGap = 0; int beats = 0;
        QTimer heartbeat; heartbeat.setInterval(5);
        QObject::connect(&heartbeat, &QTimer::timeout, &resolver, [&] {
            const auto now = elapsed.elapsed(); largestGap = std::max(largestGap, now - previous); previous = now; ++beats;
        });
        heartbeat.start();
        auto result = prepare(resolver, "streaming", {track}, {recording}, {a, b}); heartbeat.stop();
        const auto p = result.first();
        check(p.status == SongAudioStatus::Available && p.suggestedStart == 625 && p.suggestedEnd == 1875, "large packet stream resolves byte positions exactly");
        check(beats > 5 && largestGap < 500, "packet scanning yields to engine event loop");
        QVector<Track> excessive(101, track);
        result = prepare(resolver, "batch-limit", excessive, {recording}, {a, b});
        check(result.size() == 100 && result.first().status == SongAudioStatus::Failed, "selection batches have explicit bounded failure");
        qInfo() << "streaming scan elapsed ms" << elapsed.elapsed() << "heartbeat gap ms" << largestGap;
    }
    qputenv("PATH", originalPath);
}

}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        QTemporaryDir root; check(root.isValid(), "temporary directory");
        codecCase(root.path(), "libmp3lame", "mp3", {"-q:a", "3"});
        codecCase(root.path(), "aac", "aac", {"-b:a", "128k", "-f", "adts"});
        codecCase(root.path(), "libvorbis", "ogg", {"-q:a", "4"});
        codecCase(root.path(), "libopus", "opus", {"-b:a", "96k"});
        codecCase(root.path(), "flac", "flac", {});
        asyncCases(root.path());
        qInfo() << checks << "song range checks passed";
    } catch (const std::exception &error) { qCritical() << error.what(); return 1; }
}
