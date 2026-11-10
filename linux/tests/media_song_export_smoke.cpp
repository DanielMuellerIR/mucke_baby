#include "../src/media/mediaengine.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QDir>
#include <QJsonDocument>
#include <QJsonArray>
#include <QFileSystemWatcher>
#include <QTimer>
#include <QCryptographicHash>
#include <QUuid>
#include <iostream>
using namespace Mucke;
static QByteArray bytes(QString path) { QFile f(path); if (!f.open(QIODevice::ReadOnly)) return {}; return f.readAll(); }
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); if (argc < 2) return 2;
    const bool noPreview = qEnvironmentVariable("MUCKE_EXPORT_NO_PREVIEW") == "1";
    QTemporaryDir directory; const QString root = directory.path(), recordings = root + "/recordings"; QDir().mkpath(recordings);
    const QString recordingID = QUuid::createUuid().toString(QUuid::WithoutBraces), sessionID = QUuid::createUuid().toString(QUuid::WithoutBraces);
    if (!QFile::copy(QString::fromLocal8Bit(argv[1]), recordings + "/fixture.mp3")) return 2;
    const QDateTime date = QDateTime::currentDateTimeUtc(); QVector<Track> tracks;
    for (int i = 0; i < 3; ++i) { Track t; t.id = QUuid::createUuid().toString(QUuid::WithoutBraces); t.raw = "Fixture - Song " + QString::number(i); t.artist = "Fixture"; t.title = "Song " + QString::number(i); t.station = "Fixture station"; t.sessionID = sessionID; t.receivedAt = date.addSecs(i * 5); tracks.append(t); }
    QJsonArray markers;
    for (int i = 0; i < 3; ++i) markers.append(QJsonObject{{"recordingID", recordingID}, {"trackID", tracks[i].id}, {"title", tracks[i].raw}, {"bytes", i * 79872}, {"receivedAt", tracks[i].receivedAt.toString(Qt::ISODateWithMs)}, {"captureStart", i == 0}, {"partialStart", i == 0}});
    const QJsonObject recording{{"id", recordingID}, {"file", "fixture.mp3"}, {"station", "Fixture station"}, {"sessionID", sessionID}, {"ext", "mp3"}, {"start", date.toString(Qt::ISODateWithMs)}, {"end", date.addSecs(20).toString(Qt::ISODateWithMs)}, {"receivedEnd", date.addSecs(20).toString(Qt::ISODateWithMs)}, {"bytes", bytes(recordings + "/fixture.mp3").size()}, {"active", false}};
    QFile index(recordings + "/index.json"); if (!index.open(QIODevice::WriteOnly)) return 2; index.write(QJsonDocument(QJsonObject{{"version", 1}, {"recordings", QJsonArray{recording}}, {"currentBoundaries", markers}}).toJson()); index.close();
    MediaEngine engine(recordings, root + "/cache"); QFileSystemWatcher watcher; watcher.addPath(root);
    QHash<QString, int> finishes; SongExportProposal proposal; bool preparationStarted = false, realStarted = false, raceStarted = false, raceCreated = false, previewChecked = false;
    const QByteArray originalPATH = qgetenv("PATH");
    const QString realPath = root + "/real.m4a", racedPath = root + "/race.m4a";
    auto fail = [&](QString reason) { qputenv("PATH", originalPATH); std::cerr << reason.toStdString() << '\n'; engine.shutdown(); app.exit(1); };
    QObject::connect(&engine, &MediaEngine::recordingsChanged, &app, [&] { if (!preparationStarted && engine.recordings().size() == 1) { preparationStarted = true; engine.prepareSongExports("request", {tracks[1]}); } });
    QObject::connect(&watcher, &QFileSystemWatcher::directoryChanged, &app, [&](QString) {
        if (!raceStarted || raceCreated || QDir(root).entryList({".mucke-export-*"}, QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot).isEmpty()) return;
        QFile f(racedPath); if (f.open(QIODevice::WriteOnly | QIODevice::NewOnly)) { f.write("sentinel"); f.close(); raceCreated = true; }
    });
    QObject::connect(&engine, &MediaEngine::songExportsPrepared, &app, [&](QString request, QVector<SongExportProposal> proposals) {
        if (request != "request" || proposals.size() != 1 || proposals[0].sourceRevision.isEmpty()) { fail("Song preparation failed"); return; }
        proposal = proposals[0];
        if (proposal.suggestedStart < 4 || proposal.suggestedStart > 6 || proposal.suggestedEnd < 9 || proposal.suggestedEnd > 11 || proposal.partialStart || proposal.partialEnd) { fail("Wrong byte-to-audio song range"); return; }
        engine.exportPreparedSong("cancel-running", proposal, 0, 0, 0, 0, root + "/cancel-running.m4a");
        engine.exportPreparedSong("cancel-running", proposal, 0, 0, 0, 0, root + "/duplicate.m4a");
        engine.exportClip("cancel-queued", recordingID, 0, 1, 0, 0, {}, root + "/cancel-queued.m4a");
        engine.cancelExport("cancel-running"); engine.cancelExport("cancel-queued");
        auto forged = proposal; forged.metadata["title"] = "forged"; engine.exportPreparedSong("forged", forged, 0, 0, 0, 0, root + "/forged.m4a");
    });
    QObject::connect(&engine, &MediaEngine::exportFinished, &app, [&](QString id, QString path, QString error) {
        if (++finishes[id] != 1) { fail("Duplicate exportFinished"); return; }
        if (id == "cancel-running" || id == "cancel-queued" || id == "forged") {
            if (error.isEmpty() || !path.isEmpty()) { fail("Cancel or forged proposal accepted"); return; }
            if (!realStarted && finishes.value("cancel-running") == 1 && finishes.value("cancel-queued") == 1 && finishes.value("forged") == 1) { realStarted = true; engine.exportPreparedSong("real", proposal, 0.1, -0.1, 0.1, 0.2, realPath); }
        } else if (id == "real") {
            if (!error.isEmpty() || path != realPath || bytes(path).size() < 1000) { fail("Prepared export failed: " + error); return; }
            const QByteArray hash = QCryptographicHash::hash(bytes(path), QCryptographicHash::Sha256);
            if (noPreview) {
                previewChecked = QCryptographicHash::hash(bytes(realPath), QCryptographicHash::Sha256) == hash;
                raceStarted = true;
                engine.exportPreparedSong("race", proposal, 0, 0, 0, 0, racedPath);
            } else {
                engine.previewFile(path);
                QTimer::singleShot(400, &app, [&, hash] { previewChecked = engine.snapshot().previewActive && QCryptographicHash::hash(bytes(realPath), QCryptographicHash::Sha256) == hash; engine.stopPreview(); raceStarted = true; engine.exportPreparedSong("race", proposal, 0, 0, 0, 0, racedPath); });
            }
        } else if (id == "race") {
            if (error.isEmpty() || !path.isEmpty() || !raceCreated || bytes(racedPath) != "sentinel") { fail("Atomic no-overwrite race failed"); return; }
            qputenv("PATH", "/nonexistent"); engine.exportClip("start-failure", recordingID, 0, 1, 0, 0, {}, root + "/failed.m4a"); engine.cancelExport("start-failure");
        } else if (id == "start-failure") {
            qputenv("PATH", originalPATH);
            if (error.isEmpty() || !path.isEmpty() || !previewChecked || finishes.size() != 6 || QFile::exists(root + "/duplicate.m4a") || QFile::exists(root + "/cancel-running.m4a") || QFile::exists(root + "/cancel-queued.m4a") || QFile::exists(root + "/forged.m4a") || QFile::exists(root + "/failed.m4a")) { fail("Export completion guarantee failed"); return; }
            engine.shutdown(); if (noPreview) std::cout << "Explicit headless target run: audio preview skipped; prepared file hash checked.\n";
            std::cout << "song export: real byte boundaries, immutable proposal, running/queued cancellation exactly once, duplicate job guard, pinned encoder input, atomic no-overwrite race and start-failure passed\n"; app.exit(0);
        }
    });
    QTimer::singleShot(20000, &app, [&] { fail("Song export fixture timed out"); }); return app.exec();
}
