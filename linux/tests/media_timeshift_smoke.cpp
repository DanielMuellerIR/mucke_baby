#include "../src/media/mediaengine.h"
#include "../src/media/pulsemonitor.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QTcpServer>
#include <QTcpSocket>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QElapsedTimer>
#include <QTimer>
#include <iostream>
#include <cmath>
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); if (argc < 2) return 2;
    const bool overrun = argc > 2 && QString::fromLocal8Bit(argv[2]) == "overrun";
    const bool fallback = argc > 2 && QString::fromLocal8Bit(argv[2]) == "fallback";
    const QByteArray contentType = QString::fromLocal8Bit(argv[1]).endsWith(".aac") ? "audio/aac" : "audio/mpeg";
    QFile file(QString::fromLocal8Bit(argv[1])); if (!file.open(QIODevice::ReadOnly)) return 2;
    const QByteArray audio = file.readAll(); QTemporaryDir directory; QTcpServer server;
    if (!server.listen(QHostAddress::LocalHost)) return 2;
    int connections = 0, activeConnections = 0, received = 0; bool played = false, ready = false, paused = false, stablePause = false, seekPreservedReception = false, heardSecond = false;
    QString pausedTrack, latestError; qint64 bytesAtPause = 0; bool expired = false, returnedLive = false, fallbackNative = false; int seekSignals = 0; bool seekPositionsMatch = true;
    QObject::connect(&server, &QTcpServer::newConnection, &app, [&] {
        while (server.hasPendingConnections()) {
            auto *socket = server.nextPendingConnection(); ++connections; ++activeConnections;
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                if (socket->property("sent").toBool()) return;
                if (!socket->readAll().contains("\r\n\r\n")) return;
                socket->setProperty("sent", true); socket->write("HTTP/1.1 200 OK\r\nContent-Type: " + contentType + "\r\nicy-metaint: 4096\r\nConnection: close\r\n\r\n");
                auto offset = std::make_shared<qsizetype>(0); auto *writer = new QTimer(socket); writer->setTimerType(Qt::PreciseTimer); writer->setInterval(256);
                const auto feed = [&, socket, offset] {
                    if (socket->state() != QAbstractSocket::ConnectedState) return;
                    QByteArray chunk; chunk.reserve(4096);
                    for (int i = 0; i < 4096; ++i) chunk.append(audio[(*offset + i) % audio.size()]);
                    *offset += 4096;
                    QByteArray metadata = *offset >= 6 * 16000 ? "StreamTitle='Fixture - Second';" : "StreamTitle='Fixture - First';";
                    const int blocks = (metadata.size() + 15) / 16; metadata.append(QByteArray(blocks * 16 - metadata.size(), '\0'));
                    chunk.append(char(blocks)); chunk.append(metadata); socket->write(chunk);
                };
                QObject::connect(writer, &QTimer::timeout, socket, feed); writer->start();
                if (overrun && connections == 1) QTimer::singleShot(8500, Qt::PreciseTimer, socket, [feed] { for (int i = 0; i < 1280; ++i) feed(); });
            });
            QObject::connect(socket, &QTcpSocket::disconnected, socket, [&, socket] { --activeConnections; socket->deleteLater(); });
        }
    });
    Mucke::MediaEngine engine(directory.path() + "/recordings", directory.path() + "/cache");
    Mucke::MediaPrivate::PulseMonitor rawMonitor; QElapsedTimer elapsed; elapsed.start(); float earlyRMS = 0; int earlyFrames = 0;
    rawMonitor.frames = [&](auto, auto, float rms) { if (elapsed.elapsed() < 2500) { earlyRMS = std::max(earlyRMS, rms); ++earlyFrames; } }; rawMonitor.setActive(true);
    QObject::connect(&engine, &Mucke::MediaEngine::receivedTrack, &app, [&](Mucke::Track) { ++received; });
    QObject::connect(&engine, &Mucke::MediaEngine::positionDiscontinuity, &app, [&](double position) { ++seekSignals; const auto s = engine.snapshot(); seekPositionsMatch = seekPositionsMatch && std::abs(position - std::max(0.0, s.bufferSeconds - s.delaySeconds)) < 0.05 && s.state == Mucke::PlaybackState::Playing; });
    QObject::connect(&engine, &Mucke::MediaEngine::snapshotChanged, &app, [&](Mucke::PlaybackSnapshot state) {
        if (!state.error.isEmpty()) latestError = state.error;
        if (state.state == Mucke::PlaybackState::Playing) played = true;
        if (state.timeshiftAvailable && state.bufferSeconds >= 3) ready = true;
        if (state.timeshiftPaused) paused = true;
        if (state.heardTrack.title == "Second") heardSecond = true;
    });
    engine.setTimeshiftEnabled(true); engine.setRecordingEnabled(true); engine.play({"fixture", "Timeshift fixture", QString("http://127.0.0.1:%1/live").arg(server.serverPort()), {}});
    QTimer::singleShot(7000, Qt::PreciseTimer, &app, [&] {
        if (fallback) return;
        pausedTrack = engine.snapshot().heardTrack.id;
        if (!engine.recordings().isEmpty()) bytesAtPause = QFileInfo(QDir(engine.recordingsDirectory()).filePath(engine.recordings().first().file)).size();
        engine.togglePause();
    });
    QTimer::singleShot(9000, Qt::PreciseTimer, &app, [&] {
        if (overrun || fallback) return;
        const auto state = engine.snapshot();
        stablePause = state.timeshiftPaused && !pausedTrack.isEmpty() && state.heardTrack.id == pausedTrack && state.delaySeconds > 4.5;
        engine.seekDelay(5);
    });
    QTimer::singleShot(11000, Qt::PreciseTimer, &app, [&] {
        if (fallback) return;
        if (overrun) {
            expired = engine.snapshot().state == Mucke::PlaybackState::Stopped && !engine.snapshot().error.isEmpty() && connections == 1 && engine.snapshot().recordActive;
            engine.goLive(); return;
        }
        const qint64 actualBytes = engine.recordings().isEmpty() ? 0 : QFileInfo(QDir(engine.recordingsDirectory()).filePath(engine.recordings().first().file)).size();
        seekPreservedReception = connections == 1 && received == 2 && engine.recordings().size() == 1 && actualBytes > bytesAtPause;
        engine.goLive();
    });
    QTimer::singleShot(fallback ? 6500 : overrun ? 18500 : 14000, Qt::PreciseTimer, &app, [&] {
        if (fallback) fallbackNative = engine.snapshot().state == Mucke::PlaybackState::Playing && !engine.snapshot().timeshiftAvailable && !engine.snapshot().error.isEmpty() && connections == 2 && engine.snapshot().recordActive;
        if (overrun) returnedLive = engine.snapshot().state == Mucke::PlaybackState::Playing && engine.snapshot().timeshiftAvailable && connections >= 1 && connections <= 2;
        engine.stop();
    });
    QTimer::singleShot(fallback ? 7200 : overrun ? 19200 : 14700, Qt::PreciseTimer, &app, [&] {
        const auto state = engine.snapshot(); engine.shutdown();
        const bool normalOK = stablePause && seekPreservedReception && heardSecond && received == 2 && connections == 1 && seekSignals == 2 && seekPositionsMatch;
        const bool ok = (fallback ? played && !ready && fallbackNative : played && ready && paused && (overrun ? expired && returnedLive : normalOK)) && activeConnections == 0 && state.state == Mucke::PlaybackState::Stopped && (fallback || contentType != "audio/aac" || earlyRMS == 0);
        std::cout << "timeshift played=" << played << " ready=" << ready << " paused=" << paused << " stablePause=" << stablePause << " receptionPreserved=" << seekPreservedReception << " heardSecond=" << heardSecond << " tracks=" << received << " connections=" << connections << " remaining=" << activeConnections << " overrun=" << overrun << " expired=" << expired << " manualLive=" << returnedLive << " fallback=" << fallbackNative << " seekSignals=" << seekSignals << " seekPositions=" << seekPositionsMatch << " probeEarlyRMS=" << earlyRMS << " probeFrames=" << earlyFrames << " error=" << latestError.toStdString() << '\n';
        app.exit(ok ? 0 : 1);
    });
    QTimer::singleShot(30000, Qt::PreciseTimer, &app, [&] { app.exit(3); });
    return app.exec();
}
