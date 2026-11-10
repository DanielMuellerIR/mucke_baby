#include "../src/data/librarystore.h"
#include "../src/integration/mpris.h"
#include "../src/media/mediaengine.h"
#include <QDBusConnection>
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
        PropertyObserver observer;
        QVERIFY(QDBusConnection::sessionBus().connect(bridge.serviceName, "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties", "PropertiesChanged", &observer,
            SLOT(changed(QString,QVariantMap,QStringList))));
        QSignalSpy changes(&observer, &PropertyObserver::received);
        auto expect = [&](bool play, bool step) {
            QTRY_VERIFY(!changes.isEmpty());
            const auto properties = changes.last().first().toMap(); changes.clear();
            QVERIFY(properties.contains("CanPlay"));
            QCOMPARE(properties.value("CanPlay").toBool(), play);
            QCOMPARE(properties.value("CanGoNext").toBool(), step);
            QCOMPARE(properties.value("CanGoPrevious").toBool(), step);
        };
        Station first{newID(), "First", "https://radio.example/first", {}, true, false};
        Station second{newID(), "Second", "https://radio.example/second", {}, true, false};
        QVERIFY(store.saveStation(first)); expect(true, false);
        QVERIFY(store.saveStation(second)); expect(true, true);
        second.enabled = false; QVERIFY(store.saveStation(second)); expect(true, false);
        QVERIFY(store.removeStation(first.id)); expect(false, false);
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
        engine.play(station);
        QTRY_COMPARE(engine.snapshot().state, PlaybackState::Resolving);
        QTRY_COMPARE(requests, 1);
        bridge.play(); bridge.play();
        QTest::qWait(250);
        QCOMPARE(requests, 1);
        QCOMPARE(engine.snapshot().state, PlaybackState::Resolving);
        engine.shutdown();
    }
};
QTEST_GUILESS_MAIN(MprisTest)
#include "mpris_test.moc"
