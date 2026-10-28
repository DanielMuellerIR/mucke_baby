#include "../src/media/mediaengine.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QTcpServer>
#include <QTcpSocket>
#include <QFile>
#include <QTimer>
#include <iostream>
using namespace Mucke;
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); if (argc < 2) return 2;
    QFile input(QString::fromLocal8Bit(argv[1])); if (!input.open(QIODevice::ReadOnly)) return 2;
    const QByteArray audio = input.readAll(); QTemporaryDir directory; QTcpServer server; if (!server.listen(QHostAddress::LocalHost)) return 2;
    int connections = 0, active = 0; QString stage = "initial";
    QObject::connect(&server, &QTcpServer::newConnection, &app, [&] {
        while (server.hasPendingConnections()) {
            auto *socket = server.nextPendingConnection(); ++connections; ++active;
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                if (socket->property("sent").toBool() || !socket->readAll().contains("\r\n\r\n")) return;
                socket->setProperty("sent", true); socket->write("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nicy-metaint: 4096\r\nConnection: close\r\n\r\n");
                auto offset = std::make_shared<qsizetype>(0); auto *timer = new QTimer(socket); timer->setInterval(256); timer->setTimerType(Qt::PreciseTimer);
                QObject::connect(timer, &QTimer::timeout, socket, [&, socket, offset] {
                    QByteArray data; data.reserve(4129); for (int i = 0; i < 4096; ++i) data.append(audio[(*offset)++ % audio.size()]);
                    QByteArray title("StreamTitle='Sleep - Fixture';"); title.append(QByteArray(32 - title.size(), '\0')); data.append(char(2)); data.append(title); socket->write(data);
                }); timer->start();
            });
            QObject::connect(socket, &QTcpSocket::disconnected, socket, [&, socket] { --active; socket->deleteLater(); });
        }
    });
    MediaEngine engine(directory.path() + "/recordings", directory.path() + "/cache");
    const Station station{"fixture", "Sleep fixture", QString("http://127.0.0.1:%1/live").arg(server.serverPort()), {}};
    auto fail = [&](QString why) { std::cerr << stage.toStdString() << ": " << why.toStdString() << '\n'; engine.shutdown(); app.exit(1); };
    QObject::connect(&engine, &MediaEngine::snapshotChanged, &app, [&](PlaybackSnapshot s) {
        if (stage == "initial" && s.state == PlaybackState::Playing) {
            stage = "first-sleep"; engine.prepareForSleep(true);
            QTimer::singleShot(800, &app, [&] { if (active || engine.snapshot().recordActive || engine.snapshot().state != PlaybackState::Stopped) { fail("Sleep did not close stream/recording/output"); return; } stage = "resume"; engine.prepareForSleep(false); });
        } else if (stage == "resume" && s.state == PlaybackState::Playing) {
            stage = "manual-stop"; const int before = connections; engine.prepareForSleep(true); engine.stop();
            QTimer::singleShot(800, &app, [&] { engine.prepareForSleep(false); });
            QTimer::singleShot(1800, &app, [&, before] { if (active || connections != before || engine.snapshot().state != PlaybackState::Stopped) { fail("Manual stop was overridden by wake"); return; } stage = "timer-start"; engine.play(station); });
        } else if (stage == "timer-start" && s.state == PlaybackState::Playing) {
            stage = "timer-expired"; const int before = connections; engine.setSleepTimer(1); engine.prepareForSleep(true);
            QTimer::singleShot(1800, &app, [&] { engine.prepareForSleep(false); });
            QTimer::singleShot(2800, &app, [&, before] { if (active || connections != before || engine.snapshot().state != PlaybackState::Stopped || engine.snapshot().sleepRemaining != 0) { fail("Expired timer resumed playback"); return; } stage = "buffer-start"; engine.setTimeshiftEnabled(true); engine.play(station); });
        } else if (stage == "buffer-start" && s.state == PlaybackState::Playing) {
            stage = "buffer-pause"; engine.togglePause();
        } else if (stage == "buffer-pause" && s.timeshiftPaused) {
            stage = "paused-sleep"; const int before = connections; engine.prepareForSleep(true);
            QTimer::singleShot(800, &app, [&] { engine.prepareForSleep(false); });
            QTimer::singleShot(1800, &app, [&, before] { if (active || connections != before || engine.snapshot().state != PlaybackState::Stopped) { fail("Paused radio resumed after wake"); return; } stage = "preview"; engine.previewFile(QString::fromLocal8Bit(argv[1])); });
        } else if (stage == "preview" && s.previewActive && s.state == PlaybackState::Playing) {
            stage = "preview-sleep"; const int before = connections; engine.prepareForSleep(true);
            QTimer::singleShot(300, &app, [&] { engine.previewFile(QString::fromLocal8Bit(argv[1])); });
            QTimer::singleShot(800, &app, [&] { if (engine.snapshot().error.isEmpty()) { fail("Sleeping preview failed silently"); return; } engine.prepareForSleep(false); });
            QTimer::singleShot(1800, &app, [&, before] {
                if (active || connections != before || engine.snapshot().state != PlaybackState::Stopped || engine.snapshot().previewActive) { fail("File preview resumed after wake"); return; }
                QFile invalid(directory.path() + "/invalid.mp3"); if (!invalid.open(QIODevice::WriteOnly) || invalid.write("invalid audio fixture") < 0) { fail("Cannot create invalid fixture"); return; } invalid.close();
                stage = "invalid-preview"; engine.previewFile(invalid.fileName());
            });
        } else if (stage == "invalid-preview" && s.state == PlaybackState::Error && !s.error.isEmpty()) {
            if (s.previewActive || active) { fail("Failed preview retained active output"); return; }
            engine.shutdown(); std::cout << "sleep simulation: live resumes; manual stop, expired timer, paused buffer and preview remain stopped; sleeping/invalid preview reports error; all connections/recordings closed\n"; app.exit(0);
        }
    });
    engine.setRecordingEnabled(true); engine.play(station);
    QTimer::singleShot(40000, &app, [&] { fail("Sleep lifecycle fixture timed out"); }); return app.exec();
}
