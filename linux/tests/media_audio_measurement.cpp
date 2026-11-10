#include "../src/media/mediaengine.h"
#include "../src/media/pulsemonitor.h"
#include <QCoreApplication>
#include <QFile>
#include <QTemporaryDir>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QElapsedTimer>
#include <QProcess>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <iostream>
#include <cmath>
#include <functional>
#include <vlc/vlc.h>

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); if (argc < 2) return 2;
    for (unsigned i = 0; i < libvlc_audio_equalizer_get_band_count(); ++i) std::cout << "band=" << i << " Hz=" << libvlc_audio_equalizer_get_band_frequency(i) << std::endl;
    QFile input(QString::fromLocal8Bit(argv[1])); if (!input.open(QIODevice::ReadOnly)) return 2;
    const QByteArray audio = input.readAll(); QTemporaryDir directory; QTcpServer server;
    if (!server.listen(QHostAddress::LocalHost)) return 2;
    QObject::connect(&server, &QTcpServer::newConnection, &app, [&] {
        while (server.hasPendingConnections()) {
            QTcpSocket *socket = server.nextPendingConnection();
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [&, socket] { if (socket->property("sent").toBool()) return; if (!socket->readAll().contains("\r\n\r\n")) return; socket->setProperty("sent", true); socket->write("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: " + QByteArray::number(audio.size()) + "\r\nConnection: close\r\n\r\n"); socket->write(audio); });
            QObject::connect(socket, &QTcpSocket::disconnected, socket, &QTcpSocket::deleteLater);
        }
    });
    Mucke::MediaEngine engine(directory.path() + "/recordings", directory.path() + "/cache");
    Mucke::MediaPrivate::PulseMonitor rawMonitor;
    constexpr int stageCount = 11;
    QVector<double> sums(stageCount, 0), minimum(stageCount, 100), maximum(stageCount, 0), normalized(stageCount, 0); QVector<int> counts(stageCount, 0), zeros(stageCount, 0), normalizedCounts(stageCount, 0); int stage = -1; bool started = false; QElapsedTimer stageClock; float startupRMS = 0;
    std::function<void(int)> next;
    next = [&](int index) {
        stage = index; stageClock.restart();
        if (index == 0 || index == 4) engine.setVolume(100);
        if (index == 1) engine.setVolume(50);
        if (index == 2) engine.setVolume(25);
        if (index == 3) engine.setVolume(0);
        if (index == 5) engine.setStationGain("fixture", -6);
        if (index == 6) { engine.setStationGain("fixture", 0); engine.setEqualizer(true, QVector<double>(10, 0), -6); }
        if (index == 7) { QVector<double> bands(10, 0); bands[5] = 6; engine.setEqualizer(true, bands, 0); }
        if (index == 8) { engine.setEqualizer(false, QVector<double>(10, 0), 0); engine.setStationGain("fixture", 12); }
        if (index == 9) engine.setStationGain("fixture", -12);
        if (index == 10) { engine.setStationGain("fixture", 0); QVector<double> bands(10, 0); bands[5] = 6; engine.setEqualizer(true, bands, -12); }
        if (index < stageCount) QTimer::singleShot(4200, &app, [&] {
            QProcess process; process.start("pactl", {"--format=json", "list", "sink-inputs"}); process.waitForFinished(1000);
            const auto inputs = QJsonDocument::fromJson(process.readAllStandardOutput()).array();
            for (const auto &input : inputs) std::cout << "stage=" << stage << " pulse-volume=" << QJsonDocument(input.toObject().value("volume").toObject()).toJson(QJsonDocument::Compact).toStdString() << std::endl;
        });
        if (index < stageCount) QTimer::singleShot(5000, &app, [&] { next(stage + 1); });
        else {
            engine.shutdown(); bool ok = true;
            for (int i = 0; i < stageCount; ++i) { sums[i] /= std::max(1, counts[i]); std::cout << "stage=" << i << " RMS=" << sums[i] << " min=" << minimum[i] << " max=" << maximum[i] << " zeros=" << zeros[i] << " frames=" << counts[i] << '\n'; if (counts[i] < 5) ok = false; }
            const double baseline = sums[0];
            const double v50 = sums[1] / baseline, v25 = sums[2] / baseline, gain = sums[5] / sums[4], preamp = sums[6] / sums[4], band = sums[7] / sums[4];
            std::cout << "volume50/100=" << v50 << " volume25/100=" << v25 << " gain-6dB=" << gain << " preamp-6dB=" << preamp << " EQ1k+6dB+autoHeadroom=" << band << '\n';
            ok = ok && baseline > 0.01 && sums[3] < 0.00001 && v50 > 0 && v50 < 1 && v25 < v50 && gain > 0.44 && gain < 0.57 && preamp > 0.44 && preamp < 0.57 && band > 0.95 && band < 1.05;
            std::cout << "gain+12dB=" << sums[8] / sums[4] << " gain-12dB=" << sums[9] / sums[4] << '\n';
            ok = ok && sums[8] / sums[4] > 3.7 && sums[8] / sums[4] < 4.3 && sums[9] / sums[4] > 0.23 && sums[9] / sums[4] < 0.27;
            for (int i = 0; i < stageCount; ++i) normalized[i] /= std::max(1, normalizedCounts[i]);
            std::cout << "normalized100=" << normalized[0] << " normalized50=" << normalized[1] << " normalized25=" << normalized[2] << " normalized0=" << normalized[3] << " normalizedGain+12=" << normalized[8] / normalized[4] << '\n';
            ok = ok && normalizedCounts[0] > 5 && normalizedCounts[1] > 5 && normalizedCounts[2] > 5 && normalizedCounts[3] > 5 && normalized[3] == 0
                && std::abs(normalized[1] / normalized[0] - 1) < 0.05 && std::abs(normalized[2] / normalized[0] - 1) < 0.05 && normalized[8] / normalized[4] > 3.7;
            std::cout << "band+6userPreamp-12=" << sums[10] / sums[4] << '\n'; ok = ok && sums[10] / sums[4] > 0.47 && sums[10] / sums[4] < 0.53;
            std::cout << "startupVolume0RMS=" << startupRMS << '\n'; ok = ok && startupRMS == 0;
            app.exit(ok ? 0 : 1);
        }
    };
    QObject::connect(&engine, &Mucke::MediaEngine::snapshotChanged, &app, [&](Mucke::PlaybackSnapshot state) { if (state.state == Mucke::PlaybackState::Playing && !started) { started = true; QTimer::singleShot(300, &app, [&] { next(0); }); } });
    rawMonitor.frames = [&](auto, auto, float rms) { if (!started) startupRMS = std::max(startupRMS, rms); if (stage >= 0 && stage < stageCount && stageClock.elapsed() > 4000) { sums[stage] += rms; minimum[stage] = std::min(minimum[stage], double(rms)); maximum[stage] = std::max(maximum[stage], double(rms)); if (rms < 0.00001) ++zeros[stage]; ++counts[stage]; } };
    rawMonitor.status = [](QString status) { std::cout << status.toStdString() << '\n'; };
    QObject::connect(&engine, &Mucke::MediaEngine::visualization, &app, [&](auto, auto, float rms) { if (stage >= 0 && stage < stageCount && stageClock.elapsed() > 4000) { normalized[stage] += rms; ++normalizedCounts[stage]; } });
    rawMonitor.setActive(true); engine.setVisualizationActive(true); engine.setVolume(0); engine.play({"fixture", "Fixture", QString("http://127.0.0.1:%1/tone.wav").arg(server.serverPort()), {}});
    QTimer::singleShot(75000, &app, [&] { app.exit(3); }); return app.exec();
}
