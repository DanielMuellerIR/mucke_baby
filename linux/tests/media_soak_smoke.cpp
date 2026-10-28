#include "../src/media/mediaengine.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QElapsedTimer>
#include <QFile>
#include <QDirIterator>
#include <QPointer>
#include <QDir>
#include <QJsonDocument>
#include <QJsonArray>
#include <QSaveFile>
#include <QFileInfo>
#include <iostream>
#include <limits>
#include <cmath>
#include <unistd.h>
using namespace Mucke;
// Opt-in: MUCKE_MEDIA_RUNTIME_TEST=1 MUCKE_MEDIA_TEST_MODE=soak-aac.
// AAC-Laufzeit: MUCKE_MEDIA_SOAK_AAC_SECONDS=340..1200 (Standard 1080).
// Modus soak führt zusätzlich den bisherigen MP3-Reconnect-Lauf aus.
// Der Runner erzeugt synthetisches Audio und einen privaten Pulse-Server.
static QByteArray read(QString path) { QFile file(path); if (!file.open(QIODevice::ReadOnly)) return {}; return file.readAll(); }
static qint64 rssKiB() { for (auto line : read("/proc/self/status").split('\n')) if (line.startsWith("VmRSS:")) return line.simplified().split(' ').value(1).toLongLong(); return 0; }
static qint64 pssKiB() { for (auto line : read("/proc/self/smaps_rollup").split('\n')) if (line.startsWith("Pss:")) return line.simplified().split(' ').value(1).toLongLong(); return 0; }
static qint64 cpuTicks() { const auto data = read("/proc/self/stat"); const auto fields = data.mid(data.lastIndexOf(')') + 2).split(' '); return fields.value(11).toLongLong() + fields.value(12).toLongLong(); }
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); if (argc != 4) return 2;
    const bool aacOnly = qEnvironmentVariableIntValue("MUCKE_MEDIA_SOAK_AAC_ONLY") == 1;
    const bool exerciseSeek = qEnvironmentVariableIntValue("MUCKE_MEDIA_SOAK_SEEK") == 1;
    bool durationOkay = true; const auto durationText = qEnvironmentVariable("MUCKE_MEDIA_SOAK_AAC_SECONDS");
    const int aacSeconds = durationText.isEmpty() ? 340 : durationText.toInt(&durationOkay);
    if (!durationOkay || aacSeconds < 340 || aacSeconds > 1200) { std::cerr << "AAC duration must be 340..1200 seconds\n"; return 2; }
    const qint64 pauseAt = aacSeconds >= 900 ? 480000 : 100000;
    const QByteArray mp3 = aacOnly ? QByteArray() : read(QString::fromLocal8Bit(argv[1])), aac = read(QString::fromLocal8Bit(argv[2])); if ((!aacOnly && mp3.isEmpty()) || aac.isEmpty()) return 2;
    const QString prefix = QString::fromLocal8Bit(argv[3]) + "-" + QDateTime::currentDateTimeUtc().toString("yyyyMMdd'T'HHmmss'Z'"); QTemporaryDir directory; QElapsedTimer clock; clock.start();
    MediaEngine engine(directory.path() + "/recordings", directory.path() + "/cache"); QTcpServer server; if (!server.listen(QHostAddress::LocalHost)) return 2;
    int phase = aacOnly ? 1 : 0, active = 0, maximumActive = 0, connections[2] = {0, 0}, tracks = 0, frames = 0;
    qint64 phaseStart = 0, lastSample = 0, lastCPU = cpuTicks(), minRSS = std::numeric_limits<qint64>::max(), maxRSS = 0;
    qint64 minPSS = std::numeric_limits<qint64>::max(), maxPSS = 0;
    double maximumBuffer[2] = {0, 0}; qint64 maxCacheBytes = 0; int maxSegments = 0;
    bool stalled = false, recovered = false, pauseSent = false, pauseConfirmed = false, resumeSent = false, pauseStayedConnected = true, finishing = false;
    bool seekSent = false, liveSent = false, seekPositionsMatch = true; int seekSignals = 0;
    int connectionsAtPause = 0; QString pausedTrack; QPointer<QTcpSocket> firstMP3;
    QJsonArray samples; QFile csv(prefix + ".csv"); if (!csv.open(QIODevice::WriteOnly | QIODevice::NewOnly)) return 2;
    csv.write("seconds,phase,rssKiB,pssKiB,cpuPercent,bufferSeconds,delaySeconds,cacheBytes,segments,connections,active,tracks,frames\n");
    const QString protectedPath = directory.path() + "/recordings/protected-fixture.txt";
    QDir().mkpath(QFileInfo(protectedPath).absolutePath()); QFile protectedFile(protectedPath);
    if (!protectedFile.open(QIODevice::WriteOnly | QIODevice::NewOnly) || protectedFile.write("protected-fixture") != 17) return 2;
    protectedFile.close();
    auto fail = [&](QString why) { engine.shutdown(); std::cerr << "SOAK FAILED: " << why.toStdString() << '\n'; app.exit(1); };
    QObject::connect(&server, &QTcpServer::newConnection, &app, [&] {
        while (server.hasPendingConnections()) {
            auto *socket = server.nextPendingConnection(); ++active; maximumActive = std::max(maximumActive, active);
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                if (socket->property("sent").toBool()) { socket->readAll(); return; }
                const auto request = socket->readAll(); if (!request.contains("\r\n\r\n")) return;
                const bool isAAC = request.startsWith("GET /aac"); const int source = isAAC ? 1 : 0; ++connections[source];
                if (!isAAC && connections[0] == 1) firstMP3 = socket;
                socket->setProperty("sent", true); socket->write(QByteArray("HTTP/1.1 200 OK\r\nContent-Type: ") + (isAAC ? "audio/aac" : "audio/mpeg") + "\r\nicy-metaint: 4096\r\nConnection: close\r\n\r\n");
                auto offset = std::make_shared<qint64>(0); auto *timer = new QTimer(socket); timer->setInterval(256); timer->setTimerType(Qt::PreciseTimer);
                QObject::connect(timer, &QTimer::timeout, socket, [&, socket, offset, isAAC] {
                    if (socket->property("freeze").toBool() || socket->state() != QAbstractSocket::ConnectedState || socket->bytesToWrite() > 131072) return;
                    const auto &audio = isAAC ? aac : mp3; QByteArray output; output.reserve(4193);
                    for (int i = 0; i < 4096; ++i) output.append(audio[(*offset)++ % audio.size()]);
                    QByteArray title = "StreamTitle='Fixture - " + QByteArray(isAAC ? "AAC " : "MP3 ") + QByteArray::number(*offset / 480000) + "';";
                    const int blocks = (title.size() + 15) / 16; title.append(QByteArray(blocks * 16 - title.size(), '\0')); output.append(char(blocks)); output.append(title); socket->write(output);
                }); timer->start();
            });
            QObject::connect(socket, &QTcpSocket::disconnected, socket, [&, socket] { --active; socket->deleteLater(); });
        }
    });
    QObject::connect(&engine, &MediaEngine::receivedTrack, &app, [&](Track) { ++tracks; });
    QObject::connect(&engine, &MediaEngine::visualization, &app, [&](auto, auto, float) { ++frames; });
    QObject::connect(&engine, &MediaEngine::positionDiscontinuity, &app, [&](double position) { ++seekSignals; const auto state = engine.snapshot(); seekPositionsMatch = seekPositionsMatch && std::abs(position - std::max(0.0, state.bufferSeconds - state.delaySeconds)) < 0.05 && state.state == PlaybackState::Playing; });
    QObject::connect(&engine, &MediaEngine::snapshotChanged, &app, [&](PlaybackSnapshot state) {
        if ((phase == 0 && state.stationID != "mp3") || (phase == 1 && state.stationID != "aac")) return;
        if (state.bufferSeconds > 300.05) fail("Buffer exceeded300s");
        maximumBuffer[phase] = std::max(maximumBuffer[phase], state.bufferSeconds);
        if (pauseSent && !pauseConfirmed && state.timeshiftPaused) { pauseConfirmed = true; pausedTrack = state.heardTrack.id; }
        if (phase == 0 && stalled && connections[0] >= 2 && state.state == PlaybackState::Playing && state.timeshiftAvailable) recovered = true;
        if (state.state == PlaybackState::Error) fail("Unexpected playback error: " + state.error);
    });
    const QString base = QString("http://127.0.0.1:%1/").arg(server.serverPort());
    engine.setRecordingEnabled(true); engine.setTimeshiftEnabled(true); engine.setVisualizationActive(true);
    engine.play({aacOnly ? "aac" : "mp3", aacOnly ? "AAC soak" : "MP3 soak", base + (aacOnly ? "aac" : "mp3"), {}});
    QTimer control; control.setInterval(250);
    QObject::connect(&control, &QTimer::timeout, &app, [&] {
        const qint64 elapsed = clock.elapsed() - phaseStart; const auto state = engine.snapshot();
        if (phase == 0 && elapsed > 310000 && !stalled && firstMP3) { stalled = true; firstMP3->setProperty("freeze", true); std::cout << "MP3 source intentionally stalls after310s\n" << std::flush; }
        if (phase == 0 && elapsed > 340000 && recovered) { phase = 1; phaseStart = clock.elapsed(); engine.play({"aac", "AAC soak", base + "aac", {}}); std::cout << "MP3 recovery confirmed; AAC phase starts\n" << std::flush; return; }
        if (phase == 0 && elapsed > 380000 && !recovered) { fail("15s watchdog did not recover source stall"); return; }
        if (phase == 1 && elapsed > pauseAt && !pauseSent) { pauseSent = true; connectionsAtPause = connections[1]; engine.togglePause(); }
        if (phase == 1 && elapsed > pauseAt + 18000 && !resumeSent) { resumeSent = true; pauseStayedConnected = pauseConfirmed && state.timeshiftPaused && state.heardTrack.id == pausedTrack && connections[1] == connectionsAtPause; engine.togglePause(); }
        if (exerciseSeek && phase == 1 && elapsed > 200000 && !seekSent) { seekSent = true; engine.seekDelay(10); }
        if (exerciseSeek && phase == 1 && elapsed > 230000 && !liveSent) { liveSent = true; engine.goLive(); }
        if (phase == 1 && elapsed > qint64(aacSeconds) * 1000 && !finishing) {
            finishing = true; control.stop(); engine.goLive();
            QTimer::singleShot(2000, &app, [&] { engine.stop(); });
            QTimer::singleShot(2800, &app, [&] {
                const auto snapshot = engine.snapshot(); const auto recordings = engine.recordings(); engine.shutdown();
                qint64 recorded = 0; bool allClosed = true, filesIntact = read(protectedPath) == "protected-fixture";
                for (const auto &r : recordings) { recorded += r.bytes; allClosed = allClosed && !r.active; const QFileInfo file(directory.path() + "/recordings/" + r.file); filesIntact = filesIntact && file.isFile() && !file.isSymLink() && file.size() == r.bytes && r.bytes > 0; }
                const bool okay = (aacOnly || (recovered && maximumBuffer[0] > 295)) && pauseStayedConnected && (!exerciseSeek || (seekSignals >= 2 && seekPositionsMatch)) && maximumBuffer[1] > 295 && maximumActive <= 2 && active == 0 && snapshot.state == PlaybackState::Stopped && allClosed && filesIntact && recorded > qint64(aacSeconds) * 12000 && frames > 1000;
                QSaveFile result(prefix + ".json"); result.open(QIODevice::WriteOnly); result.write(QJsonDocument(QJsonObject{{"passed", okay}, {"aacOnly", aacOnly}, {"aacSeconds", aacSeconds}, {"seconds", clock.elapsed() / 1000.0}, {"minRSSKiB", double(minRSS)}, {"maxRSSKiB", double(maxRSS)}, {"minPSSKiB", double(minPSS)}, {"maxPSSKiB", double(maxPSS)}, {"mp3MaximumBuffer", maximumBuffer[0]}, {"aacMaximumBuffer", maximumBuffer[1]}, {"maximumCacheBytes", double(maxCacheBytes)}, {"maximumSegments", maxSegments}, {"maximumConnections", maximumActive}, {"mp3Connections", connections[0]}, {"aacConnections", connections[1]}, {"sourceRecovered", recovered}, {"pauseStayedConnected", pauseStayedConnected}, {"filesIntact", filesIntact}, {"connectionsClosed", active == 0}, {"stopped", snapshot.state == PlaybackState::Stopped}, {"allRecordingsClosed", allClosed}, {"seekSignals", seekSignals}, {"seekPositionsMatch", seekPositionsMatch}, {"recordings", recordings.size()}, {"recordedBytes", double(recorded)}, {"samples", samples}}).toJson()); result.commit();
                std::cout << "SOAK " << (okay ? "PASSED" : "FAILED") << " seconds=" << clock.elapsed() / 1000 << " RSSKiB=" << minRSS << ".." << maxRSS << " PSSKiB=" << minPSS << ".." << maxPSS << " buffers=" << maximumBuffer[0] << "/" << maximumBuffer[1] << " cache=" << maxCacheBytes << " segments=" << maxSegments << " recorded=" << recorded << " result=" << prefix.toStdString() << ".json\n"; app.exit(okay ? 0 : 1);
            });
        }
        if (clock.elapsed() - lastSample >= 5000) {
            qint64 cacheBytes = 0; int segments = 0; QDirIterator files(directory.path() + "/cache/timeshift", {"segment-*.data"}, QDir::Files, QDirIterator::Subdirectories); while (files.hasNext()) { files.next(); cacheBytes += files.fileInfo().size(); ++segments; }
            if (cacheBytes > 32 * 1024 * 1024 || segments > 256) { fail("Cache byte/segment limit exceeded"); return; }
            maxCacheBytes = std::max(maxCacheBytes, cacheBytes); maxSegments = std::max(maxSegments, segments);
            const qint64 rss = rssKiB(), pss = pssKiB(), ticks = cpuTicks(); const double cpu = (ticks - lastCPU) * 100000.0 / (sysconf(_SC_CLK_TCK) * double(clock.elapsed() - lastSample)); lastCPU = ticks; lastSample = clock.elapsed(); minRSS = std::min(minRSS, rss); maxRSS = std::max(maxRSS, rss); minPSS = std::min(minPSS, pss); maxPSS = std::max(maxPSS, pss);
            const QJsonObject sample{{"seconds", lastSample / 1000.0}, {"phase", phase}, {"rssKiB", double(rss)}, {"pssKiB", double(pss)}, {"cpuPercent", cpu}, {"bufferSeconds", state.bufferSeconds}, {"delaySeconds", state.delaySeconds}, {"cacheBytes", double(cacheBytes)}, {"segments", segments}}; samples.append(sample);
            const QString line = QString("%1,%2,%3,%4,%5,%6,%7,%8,%9,%10,%11,%12,%13\n").arg(lastSample / 1000.0, 0, 'f', 2).arg(phase).arg(rss).arg(pss).arg(cpu, 0, 'f', 2).arg(state.bufferSeconds, 0, 'f', 3).arg(state.delaySeconds, 0, 'f', 3).arg(cacheBytes).arg(segments).arg(connections[phase]).arg(active).arg(tracks).arg(frames); csv.write(line.toUtf8()); csv.flush();
            if (int(lastSample / 1000) % 60 < 5) std::cout << "sample t=" << lastSample / 1000 << " phase=" << phase << " rssKiB=" << rss << " pssKiB=" << pss << " buffer=" << state.bufferSeconds << " cache=" << cacheBytes << " segments=" << segments << '\n' << std::flush;
        }
    }); control.start(); QTimer::singleShot((aacSeconds + (aacOnly ? 0 : 380) + 30) * 1000, &app, [&] { fail("Soak exceeded configured duration plus cleanup allowance"); }); return app.exec();
}
