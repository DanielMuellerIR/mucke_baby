// Eigenständiges QtTest-Ziel: songexportdialog.cpp und mediaengine.h (AUTOMOC), ohne echten MediaEngine-Link.
#include "../src/ui/songexportdialog.h"
#include "../src/ui/songexportfile_p.h"
#include "../src/media/mediaengine.h"
#include <QtTest>
#include <QtWidgets>
#include <QCryptographicHash>
#include <limits>
#include <thread>

using namespace Mucke;
namespace {
QVector<SongExportProposal> fixture;
PlaybackSnapshot playback;
int preparations = 0, exports = 0, activeExports = 0, peakExports = 0, cancels = 0, stoppedPreviews = 0;
QString currentJob;
bool failFirst = false;
void reset() {
    fixture.clear(); playback = {}; preparations = exports = activeExports = peakExports = cancels = stoppedPreviews = 0;
    currentJob.clear(); failFirst = false;
}
Track track(QString id) { Track t; t.id = id; t.artist = "Example Artist"; t.title = "Example Song"; return t; }
SongExportProposal proposal(QString id, SongAudioStatus status = SongAudioStatus::Available) {
    SongExportProposal p;
    p.trackID = id; p.status = status; p.audioStart = 0; p.audioEnd = 120;
    p.suggestedStart = 10; p.suggestedEnd = 60;
    p.startLower = 9; p.startUpper = 11; p.endLower = 59; p.endUpper = 61;
    p.sourceRevision = "opaque-fixture";
    return p;
}
QByteArray read(QString path) { QFile f(path); if (!f.open(QIODevice::ReadOnly)) return {}; return f.readAll(); }
}
namespace Mucke {
class MediaEngine::Impl {};
MediaEngine::MediaEngine(QString, QString, QObject *parent) : QObject(parent) {}
MediaEngine::~MediaEngine() = default;
PlaybackSnapshot MediaEngine::snapshot() const { return playback; }
void MediaEngine::prepareSongExports(QString request, QVector<Track>) {
    ++preparations;
    auto proposals = fixture;
    for (auto &p : proposals) p.requestID = request;
    QTimer::singleShot(0, this, [this, request, proposals] { emit songExportsPrepared(request, proposals); });
}
void MediaEngine::cancelSongPreparation(QString) { ++cancels; }
void MediaEngine::exportPreparedSong(QString job, SongExportProposal, double, double, double, double, QString path) {
    ++exports; ++activeExports; peakExports = std::max(peakExports, activeExports); currentJob = job;
    const bool fail = failFirst && exports == 1;
    QTimer::singleShot(15, this, [this, job, path, fail] {
        if (currentJob != job) return;
        --activeExports; currentJob.clear();
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly)) { emit exportFinished(job, {}, f.errorString()); return; }
        f.write("exact prepared audio bytes"); f.close();
        emit exportFinished(job, fail ? QString() : path, fail ? QString("fixture encoder failure") : QString());
    });
}
void MediaEngine::cancelExport(QString job) {
    if (currentJob == job) { --activeExports; currentJob.clear(); emit exportFinished(job, {}, "cancelled"); }
}
void MediaEngine::previewFile(QString) { playback.recordActive = false; playback.previewActive = true; emit snapshotChanged(playback); }
void MediaEngine::stopPreview() { ++stoppedPreviews; playback.previewActive = false; emit snapshotChanged(playback); }
QString newID() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
}
class SongExportTest final : public QObject {
    Q_OBJECT
    void modal(MediaEngine &media, QVector<Track> tracks, const std::function<void(QDialog *)> &interact) {
        QObject guard;
        QTimer::singleShot(5000, &guard, [] { if (auto *d = qobject_cast<QDialog *>(QApplication::activeModalWidget())) d->reject(); });
        bool reached = false;
        QTimer::singleShot(0, &guard, [&] {
            auto *d = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            if (!d) return;
            reached = true;
            interact(d);
            d->reject();
        });
        showSongExportDialog(std::move(tracks), &media);
        QVERIFY(reached);
    }
    QPushButton *button(QDialog *d, const char *name) { return d->findChild<QPushButton *>(name); }
  private slots:
    void init() { reset(); QLocale::setDefault(QLocale::English); }
    void namesAndAtomicPublication() {
        QTemporaryDir sourceDir, destinationDir;
        QVERIFY(sourceDir.isValid()); QVERIFY(destinationDir.isValid());
        Track t = track("a"); t.artist = "../A/B"; t.title = "hidden\\path\n?";
        const QString base = SongExportFile::safeBase(t);
        QVERIFY(!base.startsWith('.')); QVERIFY(!base.contains('/')); QVERIFY(!base.contains('\\')); QVERIFY(!base.contains('\n'));
        t.artist = ""; t.title = ".."; QCOMPARE(SongExportFile::safeBase(t), QString("Mucke"));
        const QString source = sourceDir.filePath("prepared.m4a");
        QFile f(source); QVERIFY(f.open(QIODevice::WriteOnly));
        const QByteArray bytes = QByteArray(600000, '\x42') + "M4A fixture";
        QCOMPARE(f.write(bytes), qint64(bytes.size())); f.close();
        const auto before = QCryptographicHash::hash(read(source), QCryptographicHash::Sha256);
        QFile collision(destinationDir.filePath("Song.m4a")); QVERIFY(collision.open(QIODevice::WriteOnly)); collision.write("keep"); collision.close();
        std::atomic_bool cancelled(false);
        const auto first = SongExportFile::publishExact(source, destinationDir.path(), "Song", cancelled);
        QVERIFY2(first.error.isEmpty(), qPrintable(first.error)); QVERIFY(first.path.endsWith("Song (2).m4a"));
        const auto second = SongExportFile::publishExact(source, destinationDir.path(), "Song", cancelled);
        QVERIFY(second.path.endsWith("Song (3).m4a"));
        QCOMPARE(read(first.path), bytes); QCOMPARE(read(second.path), bytes);
        QCOMPARE(read(collision.fileName()), QByteArray("keep"));
        QCOMPARE(QCryptographicHash::hash(read(source), QCryptographicHash::Sha256), before);
        std::atomic_bool startRace(false);
        SongExportFile::PublishResult raceOne, raceTwo;
        auto race = [&](SongExportFile::PublishResult &result) {
            while (!startRace.load()) std::this_thread::yield();
            result = SongExportFile::publishExact(source, destinationDir.path(), "Race", cancelled);
        };
        std::thread one([&] { race(raceOne); }), two([&] { race(raceTwo); });
        startRace = true; one.join(); two.join();
        QVERIFY2(raceOne.error.isEmpty(), qPrintable(raceOne.error));
        QVERIFY2(raceTwo.error.isEmpty(), qPrintable(raceTwo.error));
        QVERIFY(raceOne.path != raceTwo.path);
        QCOMPARE(read(raceOne.path), bytes); QCOMPARE(read(raceTwo.path), bytes);
        cancelled = true;
        QVERIFY(SongExportFile::publishExact(source, destinationDir.path(), "Cancelled", cancelled).cancelled);
        QVERIFY(!QFileInfo::exists(destinationDir.filePath("Cancelled.m4a")));
        QCOMPARE(QDir(destinationDir.path()).entryList({".mucke-export-*"}, QDir::Files | QDir::Hidden).size(), 0);
    }
    void ranges() {
        auto p = proposal("a");
        QVERIFY(SongExportFile::validRange(p, -10, 60, 1, 1));
        QVERIFY(!SongExportFile::validRange(p, -11, 0, 0, 0));
        QVERIFY(!SongExportFile::validRange(p, 0, 61, 0, 0));
        QVERIFY(!SongExportFile::validRange(p, 0, 0, 30, 30));
        QVERIFY(!SongExportFile::validRange(p, 0, 0, -1, 0));
        p.endUpper = std::numeric_limits<double>::quiet_NaN();
        QVERIFY(!SongExportFile::validRange(p, 0, 0, 0, 0));
    }
    void partialConsentAndPreviewOwnership() {
        QTemporaryDir temp; MediaEngine media(temp.path(), temp.path());
        fixture = {proposal("a", SongAudioStatus::Partial)}; fixture[0].partialStart = true;
        modal(media, {track("a")}, [&](QDialog *d) {
            auto *consent = d->findChild<QCheckBox *>("songExportConsent"); QVERIFY(consent);
            QTRY_VERIFY(consent->isEnabled());
            QVERIFY(!button(d, "songPrepare")->isEnabled());
            consent->setChecked(true); QVERIFY(button(d, "songPrepare")->isEnabled());
            button(d, "songPrepare")->click(); QTRY_VERIFY(button(d, "songListen")->isEnabled());
            QCOMPARE(preparations, 1); QCOMPARE(exports, 1);
            playback.recordRequested = true; playback.state = PlaybackState::Stopped;
            button(d, "songListen")->click(); QVERIFY(playback.previewActive);
            QVERIFY(playback.recordRequested);
            playback.previewActive = false; emit media.snapshotChanged(playback);
            for (auto state : {PlaybackState::Playing, PlaybackState::Stopped}) {
                playback.state = state; playback.recordActive = true;
                bool asked = false;
                QTimer::singleShot(0, d, [&] {
                    if (auto *question = qobject_cast<QMessageBox *>(QApplication::activeModalWidget())) {
                        asked = question->text().contains("active recording"); question->reject();
                    }
                });
                button(d, "songListen")->click(); QVERIFY(asked);
                QVERIFY(!playback.previewActive); QVERIFY(playback.recordActive);
                QVERIFY(playback.recordRequested);
            }
            playback.recordActive = false; playback.state = PlaybackState::Playing;
            QTimer::singleShot(0, d, [] {
                if (auto *question = qobject_cast<QMessageBox *>(QApplication::activeModalWidget())) question->reject();
            });
            button(d, "songListen")->click(); QVERIFY(!playback.previewActive);
            playback.recordActive = true; playback.state = PlaybackState::Stopped;
            QTimer::singleShot(0, d, [] {
                if (auto *question = qobject_cast<QMessageBox *>(QApplication::activeModalWidget()))
                    for (auto *choice : question->buttons())
                        if (question->buttonRole(choice) == QMessageBox::AcceptRole) { choice->click(); break; }
            });
            button(d, "songListen")->click(); QVERIFY(playback.previewActive);
            QVERIFY(!playback.recordActive); QVERIFY(playback.recordRequested);
            playback.previewActive = false; emit media.snapshotChanged(playback);
            d->reject(); QCOMPARE(stoppedPreviews, 0);
        });
        QCOMPARE(stoppedPreviews, 0);
    }
    void errorsDoNotBlockBatch() {
        QTemporaryDir temp; MediaEngine media(temp.path(), temp.path());
        fixture = {proposal("a"), proposal("b"), proposal("c", SongAudioStatus::ActiveRecording)};
        failFirst = true;
        modal(media, {track("a"), track("b"), track("c")}, [&](QDialog *d) {
            auto *all = button(d, "songPrepareAll"); QTRY_VERIFY(all->isEnabled()); all->click();
            QTRY_COMPARE(exports, 2); QTRY_VERIFY(all->isEnabled());
            QCOMPARE(peakExports, 1); QCOMPARE(preparations, 1);
            auto *view = d->findChild<QTableView *>("songExportTable"); QVERIFY(view);
            QCOMPARE(view->model()->index(0, 3).data().toString(), QString("fixture encoder failure"));
            QCOMPARE(view->model()->index(1, 2).data().toString(), QString("Prepared"));
            view->selectRow(2); QVERIFY(!button(d, "songPrepare")->isEnabled());
            QVERIFY(d->findChild<QLabel *>("songExportDetails")->text().contains("Stop the recording yourself"));
        });
    }
    void editInvalidatesPreparedAndValidates() {
        QTemporaryDir temp; MediaEngine media(temp.path(), temp.path()); fixture = {proposal("a")};
        modal(media, {track("a")}, [&](QDialog *d) {
            QTRY_VERIFY(button(d, "songPrepare")->isEnabled()); button(d, "songPrepare")->click();
            QTRY_VERIFY(button(d, "songListen")->isEnabled());
            button(d, "songListen")->click();
            d->findChild<QDoubleSpinBox *>("songFadeIn")->setValue(30);
            QCOMPARE(stoppedPreviews, 1); QVERIFY(!button(d, "songSave")->isEnabled());
            d->findChild<QDoubleSpinBox *>("songFadeOut")->setValue(30);
            button(d, "songPrepare")->click();
            QTRY_VERIFY(button(d, "songPrepare")->isEnabled());
            QCOMPARE(exports, 1);
        });
    }
    void closeCancelsAndStopsOwnPreview() {
        QTemporaryDir temp; MediaEngine media(temp.path(), temp.path()); fixture = {proposal("a")};
        modal(media, {track("a")}, [&](QDialog *d) {
            QTRY_VERIFY(button(d, "songPrepare")->isEnabled()); button(d, "songPrepare")->click();
            QTRY_VERIFY(button(d, "songListen")->isEnabled()); button(d, "songListen")->click();
        });
        QCOMPARE(stoppedPreviews, 1); QCOMPARE(cancels, 1);
    }
    void cancelBatchWaitsForEncoder() {
        QTemporaryDir temp; MediaEngine media(temp.path(), temp.path());
        fixture = {proposal("a"), proposal("b"), proposal("c")};
        modal(media, {track("a"), track("b"), track("c")}, [&](QDialog *d) {
            auto *all = button(d, "songPrepareAll"); QTRY_VERIFY(all->isEnabled()); all->click();
            QCOMPARE(exports, 1); button(d, "songCancel")->click();
            QTRY_VERIFY(all->isEnabled()); QCOMPARE(exports, 1); QCOMPARE(activeExports, 0);
            auto *view = d->findChild<QTableView *>("songExportTable");
            for (int row = 0; row < 3; ++row)
                QCOMPARE(view->model()->index(row, 2).data().toString(), QString("Cancelled"));
            all->click(); QTRY_COMPARE(exports, 4); QTRY_VERIFY(all->isEnabled());
            QCOMPARE(peakExports, 1);
        });
    }
    void localizedAndNarrow() {
        QLocale::setDefault(QLocale::German);
        QTemporaryDir temp; MediaEngine media(temp.path(), temp.path()); fixture = {proposal("a")};
        modal(media, {track("a")}, [&](QDialog *d) {
            QTRY_VERIFY(button(d, "songPrepare")->isEnabled());
            d->resize(660, 720); QApplication::processEvents();
            QCOMPARE(button(d, "songClose")->text(), QString::fromUtf8("Schließen"));
            const auto shots = qEnvironmentVariable("MUCKE_UI_SHOTS");
            if (!shots.isEmpty()) { QDir().mkpath(shots); QVERIFY(d->grab().save(shots + "/de-song-export-660.png")); }
        });
    }
};
QTEST_MAIN(SongExportTest)
#include "ui_song_export_test.moc"
