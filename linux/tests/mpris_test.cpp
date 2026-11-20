#include "../src/data/librarystore.h"
#include "../src/integration/mpris.h"
#include "../src/media/mediaengine.h"
#include <QDBusConnection>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QFile>
#include <QTimer>
#include <memory>
#include <QTcpServer>
#include <QTcpSocket>
#include <QtTest>
using namespace Mucke;

class PropertyObserver final : public QObject {
    Q_OBJECT
public slots:
    void changed(QString interface, QVariantMap properties, QStringList) {
        if (interface == "org.mpris.MediaPlayer2.Player") emit received(properties);
    }
signals:
    void received(QVariantMap properties);
};

class MprisTest final : public QObject {
    Q_OBJECT
    void call(MprisBridge &bridge, QString method) {
        auto message = QDBusMessage::createMethodCall(bridge.serviceName, "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", method);
        QDBusPendingCallWatcher pending(QDBusConnection::sessionBus().asyncCall(message));
        QTRY_VERIFY(pending.isFinished());
        const QDBusPendingReply<> reply = pending;
        QVERIFY2(!reply.isError(), qPrintable(reply.error().message()));
    }
    void clearStations(LibraryStore &store) {
        QVERIFY(store.load());
        for (const auto &station : store.stations()) QVERIFY(store.removeStation(station.id));
    }
private slots:
    void stationCapabilitiesAreAnnounced() {
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); clearStations(store);
        MediaEngine engine(temporary.filePath("recordings"), temporary.filePath("cache"));
        MprisBridge bridge(&engine, &store, nullptr);
        QVERIFY(!bridge.serviceName.isEmpty());
        QVERIFY(!bridge.findChild<MprisPlayer*>()->canPlay());
        QVERIFY(!bridge.findChild<MprisPlayer*>()->canPause());
        call(bridge, "PlayPause");
        QCOMPARE(engine.snapshot().state, PlaybackState::Stopped);
        PropertyObserver observer;
        QVERIFY(QDBusConnection::sessionBus().connect(bridge.serviceName, "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties", "PropertiesChanged", &observer,
            SLOT(changed(QString,QVariantMap,QStringList))));
        QSignalSpy changes(&observer, &PropertyObserver::received);
        auto expect = [&](bool play) {
            QTRY_VERIFY(!changes.isEmpty());
            const auto properties = changes.last().first().toMap(); changes.clear();
            QVERIFY(properties.contains("CanPlay"));
            QCOMPARE(properties.value("CanPlay").toBool(), play);
            QCOMPARE(properties.value("CanPause").toBool(), play);
            QCOMPARE(properties.value("CanGoNext").toBool(), false);
            QCOMPARE(properties.value("CanGoPrevious").toBool(), false);
        };
        Station first{newID(), "First", "https://radio.example/first", {}, true, false};
        Station second{newID(), "Second", "https://radio.example/second", {}, true, false};
        QVERIFY(store.saveStation(first)); expect(true);
        QVERIFY(store.saveStation(second));
        second.enabled = false; QVERIFY(store.saveStation(second));
        QVERIFY(store.removeStation(first.id)); expect(false);
        engine.shutdown();
    }
    void repeatedPlayKeepsPendingResolution() {
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); clearStations(store);
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        int requests = 0;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            while (auto *socket = server.nextPendingConnection()) {
                connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                    if (socket->property("counted").toBool()) return;
                    if (!socket->readAll().isEmpty()) { ++requests; socket->setProperty("counted", true); }
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
        Station station{newID(), "Slow playlist", QString("http://127.0.0.1:%1/slow.m3u").arg(server.serverPort()), {}, true, false};
        QVERIFY(store.saveStation(station));
        MediaEngine engine(temporary.filePath("recordings"), temporary.filePath("cache"));
        MprisBridge bridge(&engine, &store, nullptr);
        call(bridge, "PlayPause");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Resolving);
        QTRY_COMPARE(requests, 1);
        bridge.play(); bridge.play();
        QTest::qWait(250);
        QCOMPARE(requests, 1);
        QCOMPARE(engine.snapshot().state, PlaybackState::Resolving);
        call(bridge, "Next"); call(bridge, "Previous");
        QCOMPARE(engine.snapshot().state, PlaybackState::Resolving);
        QCOMPARE(requests, 1);
        call(bridge, "PlayPause");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Stopped);
        call(bridge, "Pause");
        QCOMPARE(engine.snapshot().state, PlaybackState::Stopped);
        call(bridge, "PlayPause");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Resolving);
        QTRY_COMPARE(requests, 2);
        call(bridge, "Pause");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Stopped);
        // Auch eine nicht gespeicherte URL muss nach der Unterbrechung wieder starten.
        QVERIFY(store.removeStation(station.id));
        call(bridge, "Play");
        QTRY_COMPARE(requests, 3);
        QCOMPARE(engine.snapshot().stationID, station.id);
        call(bridge, "Stop");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Stopped);
        engine.shutdown();
    }
    void stoppedStationPreviewNeverBecomesRegularPlayback() {
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); clearStations(store);
        QTcpServer server; QVERIFY(server.listen(QHostAddress::LocalHost));
        int requests = 0;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            while (auto *socket = server.nextPendingConnection()) {
                connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                    if (socket->property("counted").toBool()) return;
                    if (!socket->readAll().isEmpty()) { ++requests; socket->setProperty("counted", true); }
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
        MediaEngine engine(temporary.filePath("recordings"), temporary.filePath("cache"));
        MprisBridge bridge(&engine, &store, nullptr);
        QSignalSpy tracks(&engine, &MediaEngine::receivedTrack);
        engine.setRecordingEnabled(true);
        engine.previewStation({newID(), "Preview", QString("http://127.0.0.1:%1/slow.m3u").arg(server.serverPort()), {}});
        QTRY_COMPARE(requests, 1);
        int expectedRequests = 1;
        for (const auto &method : {"Pause", "Stop"}) {
            call(bridge, method);
            QTRY_COMPARE(engine.snapshot().state, PlaybackState::Stopped);
            call(bridge, "Play");
            QTRY_COMPARE(engine.snapshot().state, PlaybackState::Resolving);
            ++expectedRequests;
            QTRY_COMPARE(requests, expectedRequests);
            QVERIFY(engine.snapshot().previewActive);
            QVERIFY(engine.snapshot().recordRequested);
            QVERIFY(!engine.snapshot().recordActive);
        }
        call(bridge, "Stop");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Stopped);
        QVERIFY(!engine.snapshot().stationID.isEmpty());
        engine.stopPreview();
        QTRY_VERIFY(engine.snapshot().state == PlaybackState::Stopped && engine.snapshot().stationID.isEmpty());
        const int completedRequests = requests;
        call(bridge, "Play"); QTest::qWait(150);
        QCOMPARE(engine.snapshot().state, PlaybackState::Stopped);
        QCOMPARE(requests, completedRequests);
        QVERIFY(engine.recordings().isEmpty());
        QVERIFY(tracks.isEmpty());

        engine.setTimeshiftEnabled(true);
        engine.previewStation({newID(), "Resolved preview", QString("http://127.0.0.1:%1/live").arg(server.serverPort()), {}});
        QTRY_VERIFY(engine.snapshot().state == PlaybackState::Buffering && engine.snapshot().previewActive);
        QTRY_COMPARE(requests, completedRequests + 1);
        call(bridge, "Stop");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Stopped);
        engine.stopPreview();
        QTRY_VERIFY(engine.snapshot().state == PlaybackState::Stopped && engine.snapshot().stationID.isEmpty());

        engine.goLive();
        engine.setVolume(41);
        QTRY_COMPARE(engine.snapshot().volume, 41);
        QCOMPARE(engine.snapshot().state, PlaybackState::Stopped);
        QCOMPARE(requests, completedRequests + 1);
        QVERIFY(!engine.snapshot().recordActive);
        QVERIFY(engine.recordings().isEmpty());
        QVERIFY(tracks.isEmpty());
        engine.shutdown();
    }
    void bufferedAndPreviewTransport() {
        const QString fixture = qEnvironmentVariable("MUCKE_MPRIS_AUDIO_FIXTURE");
        if (fixture.isEmpty()) QSKIP("Requires a local MP3 fixture and an explicitly isolated Pulse server");
        QVERIFY(qEnvironmentVariable("PULSE_SERVER").startsWith("unix:/tmp/mucke-"));
        QFile input(fixture); QVERIFY(input.open(QIODevice::ReadOnly));
        const QByteArray audio = input.readAll(); QVERIFY(!audio.isEmpty());
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); clearStations(store);
        QTcpServer server; QVERIFY(server.listen(QHostAddress::LocalHost));
        int requests = 0;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            while (auto *socket = server.nextPendingConnection()) {
                connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                    if (socket->property("responded").toBool()) { socket->readAll(); return; }
                    QByteArray request = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", request);
                    if (!request.contains("\r\n\r\n")) return;
                    socket->setProperty("responded", true); ++requests;
                    socket->write("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\n");
                    auto offset = std::make_shared<qsizetype>(0);
                    auto *timer = new QTimer(socket);
                    connect(timer, &QTimer::timeout, socket, [&, socket, offset] {
                        QByteArray body;
                        for (int i = 0; i < 2048; ++i) body.append(audio[(*offset)++ % audio.size()]);
                        socket->write(body);
                    });
                    timer->start(128);
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
        MediaEngine engine(temporary.filePath("recordings"), temporary.filePath("cache"));
        MprisBridge bridge(&engine, &store, nullptr);
        engine.setTimeshiftEnabled(true);
        engine.play({newID(), "Buffered fixture", QString("http://127.0.0.1:%1/live").arg(server.serverPort()), {}});
        QTRY_VERIFY_WITH_TIMEOUT(engine.snapshot().timeshiftAvailable && engine.snapshot().state == PlaybackState::Playing, 15000);
        const int beforePause = requests;
        call(bridge, "Pause");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Paused);
        QVERIFY(engine.snapshot().timeshiftPaused);
        call(bridge, "Pause"); QTest::qWait(150);
        QCOMPARE(engine.snapshot().state, PlaybackState::Paused);
        call(bridge, "Play");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Playing);
        QCOMPARE(requests, beforePause);
        QVERIFY(!engine.snapshot().recordRequested);
        engine.previewFile(fixture);
        QTRY_VERIFY(engine.snapshot().previewActive && engine.snapshot().state == PlaybackState::Playing);
        call(bridge, "PlayPause");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Paused);
        call(bridge, "Pause"); call(bridge, "Pause"); QTest::qWait(150);
        QCOMPARE(engine.snapshot().state, PlaybackState::Paused);
        call(bridge, "Play"); call(bridge, "Play");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Playing);
        QVERIFY(engine.snapshot().previewActive);
        call(bridge, "Stop");
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Stopped);
        engine.shutdown();
    }
};
QTEST_GUILESS_MAIN(MprisTest)
#include "mpris_test.moc"
