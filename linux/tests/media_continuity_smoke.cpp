#include "../src/media/mediaengine.h"
#include <QtCore>
#include <QTcpServer>
#include <QTcpSocket>
#include <cmath>
#include <cstring>
#include <iostream>
using namespace Mucke;
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc != 2 || qEnvironmentVariableIntValue("MUCKE_MEDIA_RUNTIME_TEST") != 1 ||
        (!qEnvironmentVariable("PULSE_SERVER").startsWith("unix:/tmp/mucke-continuity-") &&
         !qEnvironmentVariable("PULSE_SERVER").startsWith("unix:/tmp/mucke-media-tests.")))
        return 2;
    QFile source(QString::fromLocal8Bit(argv[1]));
    if (!source.open(QIODevice::ReadOnly)) return 2;
    const QByteArray contentType = source.fileName().endsWith(".aac") ? "audio/aac" : "audio/mpeg";
    const auto audio = source.readAll();
    if (audio.isEmpty()) return 2;
    QTemporaryDir temporary;
    QTcpServer server;
    if (!server.listen(QHostAddress::LocalHost)) return 2;
    int connections = 0;
    const bool pauseTest = qEnvironmentVariableIntValue("MUCKE_CONTINUITY_PAUSE") == 1;
    const bool burst = qEnvironmentVariableIntValue("MUCKE_CONTINUITY_BURST") == 1;
    QObject::connect(&server, &QTcpServer::newConnection, &app, [&] {
        while (server.hasPendingConnections()) {
            auto *socket = server.nextPendingConnection(); ++connections;
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                if (socket->property("started").toBool()) { socket->readAll(); return; }
                if (!socket->readAll().contains("\r\n\r\n")) return;
                socket->setProperty("started", true);
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: " + contentType + "\r\nConnection: close\r\n\r\n");
                auto clock = std::make_shared<QElapsedTimer>(); clock->start();
                auto offset = std::make_shared<qint64>(0);
                auto *timer = new QTimer(socket); timer->setInterval(50); timer->setTimerType(Qt::PreciseTimer);
                QObject::connect(timer, &QTimer::timeout, socket, [&, socket, clock, offset] {
                    if (socket->state() != QAbstractSocket::ConnectedState) return;
                    const qint64 elapsed = clock->elapsed();
                    if (burst && elapsed > 8000 && elapsed % 8000 < 2200) return;
                    // 128-kbit/s-Teststream: präziser Durchschnitt, mit optionalen Lieferpausen.
                    const qint64 due = elapsed * 16;
                    QByteArray data;
                    while (*offset < due) data.append(audio[(*offset)++ % audio.size()]);
                    socket->write(data);
                }); timer->start();
            });
            QObject::connect(socket, &QTcpSocket::disconnected, socket, &QTcpSocket::deleteLater);
        }
    });
    QByteArray pcm;
    QElapsedTimer clock; clock.start();
    qint64 lastPCMAt = 0;
    QProcess capture;
    QObject::connect(&capture, &QProcess::readyReadStandardOutput, &app,
                     [&] { pcm += capture.readAllStandardOutput(); lastPCMAt = clock.elapsed(); });
    capture.start("parec", {"--device=" + qEnvironmentVariable("MUCKE_CONTINUITY_SOURCE", "media_fixture.monitor"), "--format=float32le", "--rate=48000", "--channels=1", "--latency-msec=20"});
    if (!capture.waitForStarted(3000)) return 2;
    MediaEngine engine(temporary.filePath("recordings"), temporary.filePath("cache"));
    bool played = false, ready = false, failed = false, paused = false, resumed = false;
    double minimumDelay = 1000, maximumDelay = 0;
    QObject::connect(&engine, &MediaEngine::snapshotChanged, &app, [&](PlaybackSnapshot s) {
        played |= s.state == PlaybackState::Playing;
        ready |= s.timeshiftAvailable;
        paused |= s.timeshiftPaused;
        resumed |= paused && clock.elapsed() > 18000 && s.state == PlaybackState::Playing;
        if (clock.elapsed() > 10000 && s.state == PlaybackState::Error) failed = true;
        if (clock.elapsed() > 10000 && s.timeshiftAvailable) {
            minimumDelay = std::min(minimumDelay, s.delaySeconds);
            maximumDelay = std::max(maximumDelay, s.delaySeconds);
        }
    });
    engine.setVolume(100); engine.setTimeshiftEnabled(true);
    engine.play({"fixture", "Continuity fixture", QString("http://127.0.0.1:%1/live").arg(server.serverPort()), {}});
    if (pauseTest) {
        QTimer::singleShot(14000, &app, [&] { engine.togglePause(); });
        QTimer::singleShot(18000, &app, [&] { engine.togglePause(); });
    }
    QTimer::singleShot(40000, &app, [&] {
        engine.stop(); engine.shutdown();
        capture.terminate(); capture.waitForFinished(3000); pcm += capture.readAllStandardOutput();
        const int samples = pcm.size() / int(sizeof(float));
        int run = 0, maximumRun = 0, tested = 0; double maximumSilenceEnd = 0;
        for (int start = 10 * 48000; start + 480 < samples - 48000; start += 480) {
            double energy = 0;
            for (int i = 0; i < 480; ++i) {
                float value; std::memcpy(&value, pcm.constData() + (start + i) * sizeof(float), sizeof(float));
                energy += value * value;
            }
            ++tested;
            run = energy / 480 < 1e-8 ? run + 1 : 0;
            if (run > maximumRun) { maximumRun = run; maximumSilenceEnd = (start + 480) / 48000.; }
        }
        double marker = -1;
        for (int start = 48000; start + 4800 < samples; start += 4800) {
            int crossings = 0; float previous = 0;
            for (int i = 0; i < 4800; ++i) {
                float value; std::memcpy(&value, pcm.constData() + (start + i) * sizeof(float), sizeof(float));
                crossings += (value > 0 && previous <= 0) || (value < 0 && previous >= 0); previous = value;
            }
            if (crossings > 300) { marker = start / 48000. + lastPCMAt / 1000. - samples / 48000.; break; }
        }
        auto outputRMS = [&](double first, double last) {
            const double origin = lastPCMAt / 1000. - samples / 48000.;
            const int begin = int((first - origin) * 48000), end = int((last - origin) * 48000);
            if (begin < 0 || end > samples || end <= begin) return -1.;
            double energy = 0;
            for (int i = begin; i < end; ++i) {
                float value; std::memcpy(&value, pcm.constData() + i * sizeof(float), sizeof(float));
                energy += value * value;
            }
            return std::sqrt(energy / (end - begin));
        };
        const double pausedRMS = outputRMS(14.8, 17.5), resumedRMS = outputRMS(23, 26);
        const bool outputOkay = pauseTest ? paused && resumed && pausedRMS >= 0 && pausedRMS < 0.00001 && resumedRMS > 0.01
                                         : maximumRun <= 4;
        const bool okay = played && ready && !failed && connections == 1 && tested > 2000 && outputOkay && marker >= 12.8 && marker <= 15;
        std::cout << "continuity passed=" << okay << " burst=" << burst << " windows=" << tested
                  << " maxSilenceMs=" << maximumRun * 10 << " delay=" << minimumDelay << ".." << maximumDelay
                  << " maxSilenceAt=" << maximumSilenceEnd - maximumRun * .01 << ".." << maximumSilenceEnd
                  << " markerAt=" << marker << " measuredDelay=" << (marker < 0 ? -1 : marker - 10)
                  << " pause=" << pauseTest << " pausedRMS=" << pausedRMS << " resumedRMS=" << resumedRMS
                  << " connections=" << connections << '\n';
        app.exit(okay ? 0 : 1);
    });
    QTimer::singleShot(45000, &app, [&] { engine.shutdown(); capture.kill(); capture.waitForFinished(1000); app.exit(3); });
    return app.exec();
}
