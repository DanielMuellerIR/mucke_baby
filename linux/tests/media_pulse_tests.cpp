#include "../src/media/pulsemonitor.h"
#include <QCoreApplication>
#include <QProcess>
#include <QTimer>
#include <QElapsedTimer>
#include <cmath>
#include <cstring>
#include <iostream>
#include <unistd.h>
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QProcess foreign, own, ambiguous;
    auto start = [&](QProcess &process, bool samePID) {
        QStringList args{"--playback", "--raw", "--format=float32le", "--rate=48000", "--channels=1", "--latency-msec=30"};
        if (samePID) args << QString("--property=application.process.id=%1").arg(::getpid());
        process.start("pacat", args); return process.waitForStarted(2000);
    };
    if (!start(foreign, false)) return 2;
    Mucke::MediaPrivate::PulseMonitor monitor;
    QElapsedTimer elapsed; elapsed.start();
    int noOwnFrames = 0, isolatedFrames = 0, ambiguousFrames = 0, silentFrames = 0;
    float strongest440 = 0, strongest880 = 0, maximumSilence = 0;
    float strongest12000 = 0;
    int fullSpectrumFrames = 0;
    monitor.frames = [&](QVector<float>, QVector<float> spectrum, float rms) {
        const qint64 now = elapsed.elapsed();
        if (now < 500) ++noOwnFrames;
        if (now > 2200 && now < 3500) {
            ++isolatedFrames;
            for (int index = 7; index <= 10; ++index) strongest440 = std::max(strongest440, spectrum[index]);
            for (int index = 16; index <= 20; ++index) strongest880 = std::max(strongest880, spectrum[index]);
        }
        if (now > 5100 && now < 5500) ++ambiguousFrames;
        if (now > 6500 && now < 6900 && spectrum.size() == 512) {
            ++fullSpectrumFrames;
            for (int index = 254; index <= 257; ++index)
                strongest12000 = std::max(strongest12000, spectrum[index]);
        }
        if (now > 7800 && now < 8300) { ++silentFrames; maximumSilence = std::max(maximumSilence, rms); }
    };
    monitor.status = [](QString value) { std::cout << value.toStdString() << '\n'; };
    monitor.setActive(true);
    auto feed = [&](QProcess &process, double frequency, float amplitude) {
        if (process.state() != QProcess::Running || process.bytesToWrite() > 65536) return;
        static quint64 count440 = 0, count880 = 0;
        quint64 &count = frequency == 440 ? count440 : count880;
        QByteArray block(480 * int(sizeof(float)), '\0');
        for (int i = 0; i < 480; ++i) { const float value = amplitude * std::sin(2 * 3.141592653589793 * frequency * count++ / 48000); std::memcpy(block.data() + i * sizeof(float), &value, sizeof(float)); }
        process.write(block);
    };
    QTimer writer; writer.setInterval(10); writer.setTimerType(Qt::PreciseTimer);
    QObject::connect(&writer, &QTimer::timeout, &app, [&] {
        feed(foreign, 880, 0.5); feed(own, elapsed.elapsed() < 6000 ? 440 : 12000, elapsed.elapsed() < 7000 ? 0.5 : 0); feed(ambiguous, 880, 0.5);
    }); writer.start();
    QTimer::singleShot(500, Qt::PreciseTimer, &app, [&] { if (!start(own, true)) app.exit(2); });
    QTimer::singleShot(3500, Qt::PreciseTimer, &app, [&] { if (!start(ambiguous, true)) app.exit(2); });
    QTimer::singleShot(5500, Qt::PreciseTimer, &app, [&] { ambiguous.kill(); });
    QTimer::singleShot(8400, Qt::PreciseTimer, &app, [&] {
        monitor.setActive(false); foreign.kill(); own.kill(); ambiguous.kill();
        foreign.waitForFinished(1000); own.waitForFinished(1000); ambiguous.waitForFinished(1000);
        std::cout << "absent=" << noOwnFrames << " isolated=" << isolatedFrames << " ambiguous=" << ambiguousFrames << " 440=" << strongest440 << " 880=" << strongest880 << " silence=" << maximumSilence << " silenceFrames=" << silentFrames << '\n';
        std::cout << "fullSpectrumFrames=" << fullSpectrumFrames << " 12000=" << strongest12000 << '\n';
        app.exit(noOwnFrames == 0 && isolatedFrames > 10 && ambiguousFrames == 0 && strongest440 > 0.05 && strongest880 < strongest440 / 10 && silentFrames > 5 && maximumSilence < 0.00001 && fullSpectrumFrames > 5 && strongest12000 > 0.05 ? 0 : 1);
    });
    return app.exec();
}
