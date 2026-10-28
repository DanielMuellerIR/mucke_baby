#include "../src/media/mediaengine.h"
#include "../src/ui/songexportdialog.h"
#include "../src/ui/songexportfile_p.h"
#include <QtTest>
#include <QtWidgets>
#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <functional>

using namespace Mucke;
namespace {
QByteArray fileBytes(const QString &path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
}
QByteArray digest(const QString &path) { return QCryptographicHash::hash(fileBytes(path), QCryptographicHash::Sha256); }
bool process(const QString &program, const QStringList &args, QByteArray *output, QString *error) {
    QProcess child;
    child.start(program, args);
    if (!child.waitForFinished(20000)) {
        child.kill(); child.waitForFinished(2000); *error = program + ": timed out"; return false;
    }
    if (child.exitStatus() != QProcess::NormalExit || child.exitCode() != 0) {
        *error = program + ": " + QString::fromUtf8(child.readAllStandardError()); return false;
    }
    if (output) *output = child.readAllStandardOutput();
    return true;
}
struct Fixture {
    QString recordings, error;
    QVector<Track> tracks;
    QStringList sources;
    QVector<QByteArray> hashes;
    bool create(const QString &root, const QString &codec, bool independentSources = false) {
        recordings = root + "/recordings";
        if (!QDir().mkpath(recordings)) { error = "Cannot create fixture directory"; return false; }
        const QString ext = codec == "aac" ? "aac" : "mp3", input = root + "/fixture." + ext;
        QStringList args = {"-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i",
                            "sine=frequency=880:sample_rate=48000:duration=20", "-c:a", codec == "aac" ? "aac" : "libmp3lame", "-b:a", "128k"};
        if (codec == "aac") args << "-f" << "adts";
        args << input;
        if (!process("ffmpeg", args, nullptr, &error)) return false;
        QByteArray probe;
        if (!process("ffprobe", {"-v", "error", "-select_streams", "a:0", "-show_packets", "-show_entries",
                                  "packet=pos,pts_time", "-of", "json", input}, &probe, &error)) return false;
        const auto packets = QJsonDocument::fromJson(probe).object().value("packets").toArray();
        auto marker = [&](double seconds) -> qint64 {
            for (const auto &entry : packets) {
                const auto packet = entry.toObject();
                if (packet.value("pts_time").toString().toDouble() >= seconds)
                    return packet.value("pos").toString().toLongLong();
            }
            return -1;
        };
        if (marker(14) < 0) { error = "Fixture packet anchors missing"; return false; }
        const QDateTime date = QDateTime::fromString("2026-10-28T12:00:00Z", Qt::ISODate);
        for (int i = 0; i < 2; ++i) {
            Track track;
            track.id = newID(); track.sessionID = independentSources ? "session-" + QString::number(i) : "session";
            track.artist = "../Fixture/ Artist"; track.title = "../Song\\?"; track.raw = track.artist + " - " + track.title;
            track.station = "Local fixture"; track.receivedAt = date.addSecs(independentSources ? 2 : 2 + i * 6);
            tracks.append(track);
        }
        Track missing = tracks[0]; missing.id = newID(); missing.title = "No byte anchor"; missing.raw = missing.title;
        missing.receivedAt = date.addSecs(19); tracks.append(missing);
        QJsonArray records, boundaries;
        for (int i = 0; i < (independentSources ? 2 : 1); ++i) {
            const QString filename = QString("recording-%1.").arg(i) + ext, path = QDir(recordings).filePath(filename);
            if (!QFile::copy(input, path)) { error = "Fixture copy failed"; return false; }
            sources.append(path); hashes.append(digest(path));
            const QString id = "recording-" + QString::number(i), session = independentSources ? tracks[i].sessionID : "session";
            records.append(QJsonObject{{"id", id}, {"file", filename}, {"station", "Local fixture"}, {"sessionID", session},
                                       {"ext", ext}, {"start", date.toString(Qt::ISODateWithMs)}, {"end", date.addSecs(20).toString(Qt::ISODateWithMs)},
                                       {"receivedEnd", date.addSecs(20).toString(Qt::ISODateWithMs)}, {"bytes", double(QFileInfo(path).size())}, {"active", false}});
            auto boundary = [&](QString trackID, QString raw, double seconds) {
                boundaries.append(QJsonObject{{"recordingID", id}, {"trackID", trackID}, {"title", raw}, {"bytes", double(marker(seconds))},
                                              {"receivedAt", date.addMSecs(qint64(seconds * 1000)).toString(Qt::ISODateWithMs)},
                                              {"captureStart", false}, {"partialStart", false}});
            };
            if (independentSources) {
                boundary(tracks[i].id, tracks[i].raw, 2); boundary("next-" + QString::number(i), "Next", 8);
            } else {
                boundary(tracks[0].id, tracks[0].raw, 2); boundary(tracks[1].id, tracks[1].raw, 8); boundary("next", "Next", 14);
            }
        }
        QFile index(QDir(recordings).filePath("index.json"));
        if (!index.open(QIODevice::WriteOnly)) { error = index.errorString(); return false; }
        index.write(QJsonDocument(QJsonObject{{"version", 1}, {"recordings", records}, {"currentBoundaries", boundaries}}).toJson());
        return true;
    }
};
}
class UISongBackendTest final : public QObject {
    Q_OBJECT
    QPushButton *button(QDialog *dialog, const char *name) { return dialog->findChild<QPushButton *>(name); }
    void modal(MediaEngine &engine, const QVector<Track> &tracks, const std::function<void(QDialog *)> &interact) {
        QObject guard;
        bool reached = false;
        QTimer::singleShot(30000, &guard, [] {
            if (auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget())) dialog->reject();
        });
        QTimer::singleShot(0, &guard, [&] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            if (!dialog) return;
            reached = true; interact(dialog); dialog->reject();
        });
        showSongExportDialog(tracks, &engine);
        QVERIFY2(reached, "Real song export dialog opened");
    }
    void chooseDirectory(QDialog *owner, const QString &directory, bool *reached) {
        QTimer::singleShot(0, owner, [directory, reached] {
            auto *fileDialog = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
            if (!fileDialog) return;
            *reached = true; fileDialog->setDirectory(directory); fileDialog->selectFile(directory);
            static_cast<QDialog *>(fileDialog)->accept();
        });
    }
  private slots:
    void initTestCase() {
        if (qEnvironmentVariable("MUCKE_UI_SONG_BACKEND") != "1")
            QSKIP("Requires explicit isolated audio run: MUCKE_UI_SONG_BACKEND=1 and private PULSE_SERVER");
        QVERIFY2(qEnvironmentVariable("PULSE_SERVER").startsWith("unix:"), "Use an explicit private Unix Pulse server");
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
        QLocale::setDefault(QLocale::English);
    }
    void previewAndPublish_data() {
        QTest::addColumn<QString>("codec");
        QTest::newRow("MP3") << QString("mp3");
        QTest::newRow("AAC") << QString("aac");
    }
    void previewAndPublish() {
        QFETCH(QString, codec);
        QTemporaryDir temporary; QVERIFY(temporary.isValid());
        Fixture fixture; QVERIFY2(fixture.create(temporary.path(), codec), qPrintable(fixture.error));
        MediaEngine engine(fixture.recordings, temporary.filePath("cache"));
        QTRY_COMPARE_WITH_TIMEOUT(engine.recordings().size(), 1, 5000);
        engine.setVolume(70); engine.setVisualizationActive(true);
        float peak = 0;
        QObject observation;
        connect(&engine, &MediaEngine::visualization, &observation, [&](QVector<float>, QVector<float>, float rms) { peak = std::max(peak, rms); });
        QSignalSpy preparation(&engine, &MediaEngine::songExportsPrepared), completion(&engine, &MediaEngine::exportFinished);
        QSignalSpy snapshots(&engine, &MediaEngine::snapshotChanged);
        int snapshotsBeforeClose = 0;
        const QString destination = temporary.filePath("published"); QVERIFY(QDir().mkpath(destination));
        const QString sentinelPath = QDir(destination).filePath(SongExportFile::safeBase(fixture.tracks[0]) + ".m4a");
        QFile sentinel(sentinelPath); QVERIFY(sentinel.open(QIODevice::WriteOnly)); sentinel.write("existing destination"); sentinel.close();
        modal(engine, fixture.tracks, [&](QDialog *dialog) {
            auto *all = button(dialog, "songPrepareAll"); QVERIFY(all);
            QTRY_VERIFY_WITH_TIMEOUT(all->isEnabled(), 10000);
            QCOMPARE(preparation.size(), 1);
            auto *table = dialog->findChild<QTableView *>("songExportTable"); QVERIFY(table);
            QVERIFY(table->model()->index(2, 2).data().toString() == "Unavailable");
            auto *consent = dialog->findChild<QCheckBox *>("songExportConsent"); QVERIFY(consent);
            consent->setChecked(true);
            dialog->findChild<QDoubleSpinBox *>("songStartAdjustment")->setValue(.05);
            dialog->findChild<QDoubleSpinBox *>("songEndAdjustment")->setValue(-.05);
            dialog->findChild<QDoubleSpinBox *>("songFadeIn")->setValue(.1);
            dialog->findChild<QDoubleSpinBox *>("songFadeOut")->setValue(.2);
            int peakPreparing = 0;
            QTimer observe; observe.setInterval(1);
            connect(&observe, &QTimer::timeout, dialog, [&] {
                int preparing = 0;
                for (int row = 0; row < table->model()->rowCount(); ++row)
                    preparing += table->model()->index(row, 2).data().toString() == "Preparing M4A …";
                peakPreparing = std::max(peakPreparing, preparing);
            });
            observe.start(); all->click();
            QTRY_COMPARE_WITH_TIMEOUT(completion.size(), 2, 15000);
            QTRY_VERIFY(all->isEnabled()); observe.stop();
            QVERIFY(peakPreparing <= 1);
            QVector<QByteArray> preparedHashes;
            for (const auto &event : completion) {
                QVERIFY2(event[2].toString().isEmpty(), qPrintable(event[2].toString()));
                QVERIFY(QFileInfo(event[1].toString()).size() > 1000);
                preparedHashes.append(digest(event[1].toString()));
            }
            button(dialog, "songListen")->click();
            QTRY_VERIFY_WITH_TIMEOUT(engine.snapshot().previewActive, 5000);
            QTRY_VERIFY_WITH_TIMEOUT(peak > .001f, 5000);
            QCOMPARE(digest(completion[0][1].toString()), preparedHashes[0]);
            QVERIFY2(button(dialog, "songStopPreview")->isEnabled(), "Own preview retains its stop control after the engine's intermediate stop snapshot");
            button(dialog, "songStopPreview")->click();
            QTRY_VERIFY_WITH_TIMEOUT(!engine.snapshot().previewActive, 2000);
            bool directoryReached = false;
            chooseDirectory(dialog, destination, &directoryReached); button(dialog, "songSaveAll")->click();
            QVERIFY(directoryReached);
            QTRY_COMPARE_WITH_TIMEOUT(table->model()->index(0, 2).data().toString(), QString("Saved"), 10000);
            QTRY_COMPARE_WITH_TIMEOUT(table->model()->index(1, 2).data().toString(), QString("Saved"), 10000);
            const QString first = table->model()->index(0, 3).data().toString(), second = table->model()->index(1, 3).data().toString();
            QVERIFY(first != second); QVERIFY(first.endsWith(" (2).m4a")); QVERIFY(second.endsWith(" (3).m4a"));
            QCOMPARE(digest(first), preparedHashes[0]); QCOMPARE(digest(second), preparedHashes[1]);
            QCOMPARE(fileBytes(sentinelPath), QByteArray("existing destination"));
            QCOMPARE(completion.size(), 2); QCOMPARE(preparation.size(), 1);
            snapshotsBeforeClose = int(snapshots.size());
            button(dialog, "songListen")->click();
            // Workerstart zulassen, aber dessen Start-Snapshot noch nicht im GUI-Thread ausliefern.
            QTest::qSleep(250);
            dialog->reject();
        });
        engine.setVolume(71);
        QTRY_COMPARE_WITH_TIMEOUT(engine.snapshot().volume, 71, 5000);
        QVERIFY2(!engine.snapshot().previewActive, "Closing while own preview is starting queues its stop");
        bool startedBeforeClose = false;
        for (int i = snapshotsBeforeClose; i < snapshots.size(); ++i)
            startedBeforeClose |= snapshots[i][0].value<PlaybackSnapshot>().previewActive;
        QVERIFY2(startedBeforeClose, "The close test stopped an actual pending preview start");
        engine.setVisualizationActive(false); engine.shutdown();
        for (int i = 0; i < fixture.sources.size(); ++i) QCOMPARE(digest(fixture.sources[i]), fixture.hashes[i]);
    }
    void batchFailureAndCancellation() {
        QTemporaryDir temporary; QVERIFY(temporary.isValid());
        Fixture fixture; QVERIFY2(fixture.create(temporary.path(), "mp3", true), qPrintable(fixture.error));
        MediaEngine engine(fixture.recordings, temporary.filePath("cache"));
        QTRY_COMPARE_WITH_TIMEOUT(engine.recordings().size(), 2, 5000);
        QSignalSpy preparation(&engine, &MediaEngine::songExportsPrepared), completion(&engine, &MediaEngine::exportFinished);
        modal(engine, fixture.tracks, [&](QDialog *dialog) {
            auto *all = button(dialog, "songPrepareAll"); QTRY_VERIFY_WITH_TIMEOUT(all->isEnabled(), 10000);
            dialog->findChild<QCheckBox *>("songExportConsent")->setChecked(true);
            const QString old = fixture.sources[0] + ".old";
            QVERIFY(QFile::rename(fixture.sources[0], old)); QVERIFY(QFile::copy(old, fixture.sources[0]));
            all->click(); QTRY_COMPARE_WITH_TIMEOUT(completion.size(), 2, 15000); QTRY_VERIFY(all->isEnabled());
            auto *table = dialog->findChild<QTableView *>("songExportTable"); QVERIFY(table);
            QCOMPARE(table->model()->index(0, 2).data().toString(), QString("Preparation failed"));
            QVERIFY(!table->model()->index(0, 3).data().toString().isEmpty());
            QCOMPARE(table->model()->index(1, 2).data().toString(), QString("Prepared"));
            QVERIFY(!completion[0][2].toString().isEmpty()); QVERIFY(completion[1][2].toString().isEmpty());
            QCOMPARE(preparation.size(), 1);
        });
        completion.clear(); preparation.clear();
        modal(engine, fixture.tracks, [&](QDialog *dialog) {
            auto *all = button(dialog, "songPrepareAll"); QTRY_VERIFY_WITH_TIMEOUT(all->isEnabled(), 10000);
            dialog->findChild<QCheckBox *>("songExportConsent")->setChecked(true);
            all->click(); button(dialog, "songCancel")->click();
            QTRY_VERIFY_WITH_TIMEOUT(all->isEnabled(), 10000);
            QTRY_COMPARE_WITH_TIMEOUT(completion.size(), 1, 5000);
            QVERIFY(!completion[0][2].toString().isEmpty());
            auto *table = dialog->findChild<QTableView *>("songExportTable"); QVERIFY(table);
            QCOMPARE(table->model()->index(0, 2).data().toString(), QString("Cancelled"));
            QCOMPARE(table->model()->index(1, 2).data().toString(), QString("Cancelled"));
            QCOMPARE(preparation.size(), 1);
        });
        engine.shutdown();
        for (int i = 0; i < fixture.sources.size(); ++i) QCOMPARE(digest(fixture.sources[i]), fixture.hashes[i]);
    }
};
QTEST_MAIN(UISongBackendTest)
#include "ui_song_backend_test.moc"
