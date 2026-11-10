#include "../src/media/mediaengine.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QTcpServer>
#include <QTcpSocket>
#include <QFile>
#include <QTimer>
#include <QElapsedTimer>
#include <QProcess>
#include <QJsonDocument>
#include <QJsonObject>
#include <iostream>

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc < 2) return 2;
    QFile input(QString::fromLocal8Bit(argv[1])); if (!input.open(QIODevice::ReadOnly)) return 2; QByteArray audio = input.readAll();
    QTemporaryDir directory; QTcpServer server;
    if (!server.listen(QHostAddress::LocalHost)) return 2;
    int connections = 0, metadataCount = 0, frames = 0; bool played = false, stopped = false, exported = false;
    QObject::connect(&server, &QTcpServer::newConnection, &app, [&] {
        while (server.hasPendingConnections()) {
            QTcpSocket *socket = server.nextPendingConnection(); ++connections;
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                QByteArray request = socket->readAll(); if (!request.contains("\r\n\r\n")) return;
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nicy-metaint: 4096\r\nConnection: close\r\n\r\n");
                if (request.startsWith("GET /blocked")) return;
                auto offset = std::make_shared<qsizetype>(0); auto timer = new QTimer(socket); timer->setInterval(125);
                QObject::connect(timer, &QTimer::timeout, socket, [&, socket, offset] {
                    if (socket->state() != QAbstractSocket::ConnectedState) return;
                    QByteArray body;
                    for (int i = 0; i < 4096; ++i) { body.append(audio[*offset % audio.size()]); ++*offset; }
                    QByteArray metadata("StreamTitle='Fixture - Test';"); metadata.append(QByteArray(32 - metadata.size(), '\0')); body.append(char(2)); body.append(metadata); socket->write(body);
                }); timer->start();
            });
            QObject::connect(socket, &QTcpSocket::disconnected, socket, &QTcpSocket::deleteLater);
        }
    });
    Mucke::MediaEngine engine(directory.path() + "/recordings", directory.path() + "/cache");
    const QString base = QString("http://127.0.0.1:%1").arg(server.serverPort());
    QObject::connect(&engine, &Mucke::MediaEngine::snapshotChanged, &app, [&](Mucke::PlaybackSnapshot state) { if (state.state == Mucke::PlaybackState::Playing) played = true; if (state.state == Mucke::PlaybackState::Stopped) stopped = true; });
    QObject::connect(&engine, &Mucke::MediaEngine::receivedTrack, &app, [&](Mucke::Track track) { if (track.title == "Test") ++metadataCount; });
    QObject::connect(&engine, &Mucke::MediaEngine::visualization, &app, [&](auto, auto, float) { ++frames; });
    QObject::connect(&engine, &Mucke::MediaEngine::exportFinished, &app, [&](QString id, QString path, QString error) {
        if (id != "fixture-export") return;
        if (!error.isEmpty()) { std::cerr << error.toStdString() << '\n'; app.exit(4); return; }
        QProcess probe; probe.start("ffprobe", {"-v", "error", "-show_entries", "format_tags=title,artist,album", "-of", "json", path});
        if (!probe.waitForFinished(3000)) { app.exit(4); return; }
        const auto tags = QJsonDocument::fromJson(probe.readAllStandardOutput()).object().value("format").toObject().value("tags").toObject();
        exported = QFileInfo(path).size() > 1000 && tags.value("title").toString() == QString::fromUtf8("Prüfung") && tags.value("artist").toString() == "Fixture";
        engine.previewFile(path);
        QTimer::singleShot(400, &app, [&] {
            const bool preview = engine.snapshot().previewActive;
            const int beforePreviewTracks = metadataCount, beforePreviewConnections = connections;
            engine.previewStation({"catalog", "Catalog fixture", base + "/preview", {}});
            QTimer::singleShot(1800, &app, [&, preview, beforePreviewTracks, beforePreviewConnections] {
                const auto state = engine.snapshot();
                const bool catalog = state.previewActive && state.recordRequested && !state.recordActive && metadataCount == beforePreviewTracks && connections == beforePreviewConnections + 1;
                if (!catalog) std::cerr << "catalog preview=" << state.previewActive << " requested=" << state.recordRequested << " active=" << state.recordActive << " tracks=" << metadataCount << "/" << beforePreviewTracks << " connections=" << connections << "/" << beforePreviewConnections << " state=" << int(state.state) << " error=" << state.error.toStdString() << '\n';
                engine.play({"manual", "Manual fixture", base + "/blocked", {}});
                QTimer::singleShot(200, &app, [&] { engine.stopPreview(); });
                QTimer::singleShot(500, &app, [&, preview, catalog] {
                    const bool protectedManual = !engine.snapshot().previewActive && engine.snapshot().stationID == "manual" && engine.snapshot().state != Mucke::PlaybackState::Stopped;
                    const auto recordings = engine.recordings(); engine.shutdown();
                    const bool ok = played && stopped && metadataCount >= 1 && connections <= 7 && frames > 0 && !recordings.isEmpty() && recordings.first().bytes > 0 && exported && preview && catalog && protectedManual;
                    std::cout << "played=" << played << " stopped=" << stopped << " tracks=" << metadataCount << " connections=" << connections << " frames=" << frames << " recordings=" << recordings.size() << " AAC-export=" << exported << " preview=" << preview << " catalog=" << catalog << " protectedManual=" << protectedManual << '\n';
                    app.exit(ok ? 0 : 1);
                });
            });
        });
    });
    engine.setRecordingEnabled(true); engine.setVisualizationActive(true); engine.play({"fixture", "Fixture", base + "/live", {}});
    QTimer::singleShot(5000, &app, [&] { engine.play({"blocked", "Blocked fixture", base + "/blocked", {}}); });
    QTimer::singleShot(5500, &app, [&] { stopped = false; engine.stop(); });
    QTimer::singleShot(6200, &app, [&] {
        const auto recordings = engine.recordings();
        if (recordings.isEmpty()) { app.exit(1); return; }
        engine.exportClip("fixture-export", recordings.first().id, 0, 1, 0.1, 0.2, {{"title", QString::fromUtf8("Prüfung")}, {"artist", "Fixture"}, {"album", "Test"}}, directory.path() + "/fixture.m4a");
    });
    QTimer::singleShot(15000, &app, [&] { app.exit(3); });
    return app.exec();
}
