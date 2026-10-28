#include "../src/data/catalogservice.h"
#include "../src/data/librarystore.h"
#include "../src/media/mediaengine.h"
#include "../src/ui/historyfilter_p.h"
#include "../src/ui/mainwindow.h"
#include "../src/ui/consolewidgets.h"
#include "../src/ui/songtools_p.h"
#include <QUrlQuery>
#include <QTcpServer>
#include <QTcpSocket>
#include <QtTest>
#include <QtWidgets>
#include <functional>
#include <cmath>
using namespace Mucke;

class UIFlowTest final : public QObject {
    Q_OBJECT
    QString shots;
    QString lang;
    QString label(const char *de, const char *en) const { return QString::fromUtf8(lang == "de" ? de : en); }
    QPushButton *push(QWidget *widget, QString caption) {
        for (auto *button : widget->findChildren<QPushButton *>())
            if (button->text() == caption)
                return button;
        return nullptr;
    }
    QAction *action(QWidget *widget, QString caption) {
        for (auto *candidate : widget->findChildren<QAction *>())
            if (candidate->text() == caption)
                return candidate;
        return nullptr;
    }
    void capture(QWidget *widget, QString name) {
        QVERIFY(widget);
        QApplication::processEvents();
        QVERIFY2(widget->grab().save(shots + "/" + lang + "-" + name + ".png"), "dialog screenshot saved");
    }
    void modal(const std::function<void()> &open, const std::function<void(QDialog *)> &interact) {
        QObject guard;
        QTimer::singleShot(2500, &guard, [] {
            if (auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget()))
                dialog->reject();
        });
        bool reached = false;
        QTimer::singleShot(0, &guard, [callback = interact, &reached] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            if (dialog) {
                reached = true;
                callback(dialog);
            }
        });
        open();
        QVERIFY2(reached, "requested dialog became modal");
    }
    void accept(QDialog *dialog, QDialogButtonBox::StandardButton role = QDialogButtonBox::Save) {
        auto *buttons = dialog->findChild<QDialogButtonBox *>();
        QVERIFY(buttons);
        QVERIFY(buttons->button(role));
        buttons->button(role)->click();
    }
  private slots:
    void musicLinkEncoding() {
        Track track;
        track.artist = "Artist & Co / ?#";
        track.title = "Song + value=other&admin=true";
        const QString expected = SongTools::query(track);
        const QUrl apple = SongTools::appleMusicURL(track), spotify = SongTools::spotifyURL(track);
        QCOMPARE(apple.scheme(), QString("https"));
        QCOMPARE(apple.host(), QString("music.apple.com"));
        QCOMPARE(QUrlQuery(apple).queryItems().size(), 1);
        QCOMPARE(QUrlQuery(apple).queryItemValue("term", QUrl::FullyDecoded), expected);
        QCOMPARE(spotify.host(), QString("open.spotify.com"));
        QVERIFY(!spotify.hasQuery());
        QVERIFY(!spotify.hasFragment());
        const QUrl lyrics = SongTools::lyricsURL("Artist/name?private=true", "Title/#fragment");
        QCOMPARE(lyrics.host(), QString("api.lyrics.ovh"));
        QVERIFY(!lyrics.hasQuery());
        QVERIFY(!lyrics.hasFragment());
        QCOMPARE(SongTools::cleanedTitle("Example Song (Extended Mix)"), QString("Example Song"));
        QCOMPARE(SongTools::cleanedArtist("Example Artist feat. Guest"), QString("Example Artist"));
    }
    void historyDateRanges() {
        const QTimeZone berlin("Europe/Berlin");
        QVERIFY(berlin.isValid());
        const QDate today(2026, 10, 28);
        Track track;
        track.heardAt = QDateTime::fromString("2026-10-28T23:30:00Z", Qt::ISODate);
        track.endedAt = track.heardAt.addSecs(120);
        QVERIFY(!HistoryFilter::overlaps(track, today, today, track.endedAt, berlin));
        QVERIFY(HistoryFilter::overlaps(track, today.addDays(1), today.addDays(1), track.endedAt, berlin));
        track.heardAt = QDateTime::fromString("2026-10-28T21:30:00Z", Qt::ISODate);
        QVERIFY(HistoryFilter::overlaps(track, today, today, track.endedAt, berlin));
        QVERIFY(HistoryFilter::overlaps(track, today.addDays(1), today.addDays(1), track.endedAt, berlin));
        track.endedAt = QDateTime::fromString("2026-10-28T23:00:00Z", Qt::ISODate);
        QVERIFY(!HistoryFilter::overlaps(track, today.addDays(1), today.addDays(1), track.endedAt, berlin));
        track.endedAt = {};
        QVERIFY(HistoryFilter::overlaps(track, today.addDays(1), today.addDays(1),
                                        QDateTime::fromString("2026-10-29T01:00:00Z", Qt::ISODate), berlin));
        QVERIFY(!HistoryFilter::overlaps(track, today.addDays(2), today.addDays(2),
                                         QDateTime::fromString("2026-10-29T01:00:00Z", Qt::ISODate), berlin));
        for (const auto preset : {2, 3}) {
            int days = preset == 2 ? 7 : 30;
            track.heardAt = QDateTime(today.addDays(-(days - 1)), QTime(12, 0), berlin);
            track.endedAt = track.heardAt.addSecs(60);
            QVERIFY(HistoryFilter::overlaps(track, HistoryFilter::presetStart(preset, today), today,
                                            track.endedAt, berlin));
            track.heardAt = track.heardAt.addDays(-1);
            track.endedAt = track.heardAt.addSecs(60);
            QVERIFY(!HistoryFilter::overlaps(track, HistoryFilter::presetStart(preset, today), today,
                                             track.endedAt, berlin));
        }
        // Ein Kalendertag bleibt auch beim Wechsel zwischen Sommer- und Winterzeit vollständig.
        for (const auto day : {QDate(2026, 3, 29), QDate(2026, 10, 25)}) {
            track.heardAt = QDateTime(day, QTime(23, 59), berlin);
            track.endedAt = track.heardAt.addSecs(30);
            QVERIFY(HistoryFilter::overlaps(track, day, day, track.endedAt, berlin));
            QVERIFY(!HistoryFilter::overlaps(track, day.addDays(1), day.addDays(1), track.endedAt, berlin));
        }
    }
    void defaultThemeAndSavedChoice() {
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); QVERIFY(store.load());
        CatalogService catalog(temporary.filePath("cache"));
        MediaEngine media(temporary.filePath("recordings"), temporary.filePath("cache"));
        for (const auto &choice : {QString(), QString("acid"), QString("unknown")}) {
            if (!choice.isEmpty()) QVERIFY(store.saveSettings({{"selectedTheme", choice}}));
            MainWindow window(&store, &catalog, &media);
            auto *visual = dynamic_cast<Console::Visualizer *>(window.findChild<QWidget *>("mainVisualizer"));
            QVERIFY(visual);
            QCOMPARE(visual->theme, choice == "acid" ? QString("acid") : QString("midi"));
        }
        media.shutdown();
    }
    void consoleGeometry() {
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); QVERIFY(store.load());
        CatalogService catalog(temporary.filePath("cache"));
        MediaEngine media(temporary.filePath("recordings"), temporary.filePath("cache"));
        MainWindow window(&store, &catalog, &media); window.show();
        auto *visual = window.findChild<QWidget *>("mainVisualizer");
        auto *header = window.findChild<QWidget *>("consoleHeader");
        auto *footer = window.findChild<QWidget *>("consoleFooter");
        QVERIFY(visual); QVERIFY(header); QVERIFY(footer);
        for (const auto &theme : {"schlicht", "acid", "retro", "fanzine", "stack", "danish", "midi"}) {
            window.applyTheme(theme);
            for (int width : {940, 780, 779, 660, 620}) {
                window.resize(width, width == 620 ? 420 : 620); QApplication::processEvents();
                QCOMPARE(window.width(), width);
                QCOMPARE(visual->isVisible(), width >= 780);
                if (visual->isVisible()) {
                    QVERIFY(visual->width() >= 280);
                    QVERIFY(visual->height() > window.height()/2);
                }
                QVERIFY(footer->geometry().bottom() < window.height());
                for (auto *panel : {header, footer}) {
                    const auto buttons = panel->findChildren<QPushButton *>();
                    for (auto *button : buttons) if (button->isVisible()) {
                        const QRect actual(button->mapTo(panel, QPoint()), button->size());
                        QVERIFY2(panel->rect().contains(actual), qPrintable(QString("%1: %2").arg(theme, button->accessibleName())));
                    }
                }
            }
        }
        media.shutdown();
    }
    void stationClickSwitchesAndStops() {
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); QVERIFY(store.load());
        for (const auto &station : store.stations()) QVERIFY(store.removeStation(station.id));
        QTcpServer server; QVERIFY(server.listen(QHostAddress::LocalHost));
        connect(&server,&QTcpServer::newConnection,&server,[&] {
            while (auto *socket=server.nextPendingConnection())
                connect(socket,&QTcpSocket::disconnected,socket,&QObject::deleteLater);
        });
        Station first{newID(),"First",QString("http://127.0.0.1:%1/first.m3u").arg(server.serverPort()),{},true,false};
        Station second{newID(),"Second",QString("http://127.0.0.1:%1/second.m3u").arg(server.serverPort()),{},true,false};
        QVERIFY(store.saveStation(first)); QVERIFY(store.saveStation(second));
        CatalogService catalog(temporary.filePath("cache"));
        MediaEngine media(temporary.filePath("recordings"),temporary.filePath("cache"));
        MainWindow window(&store,&catalog,&media); window.show(); QApplication::processEvents();
        auto *stations=window.findChild<QTableView *>("stations"); QVERIFY(stations);
        auto click=[&](int row) { QTest::mouseClick(stations->viewport(),Qt::LeftButton,Qt::NoModifier,
            stations->visualRect(stations->model()->index(row,0)).center()); };
        click(0); QTRY_COMPARE(media.snapshot().stationID,first.id);
        QTRY_COMPARE(media.snapshot().state,PlaybackState::Resolving);
        click(1); QTRY_COMPARE(media.snapshot().stationID,second.id);
        QTRY_COMPARE(media.snapshot().state,PlaybackState::Resolving);
        click(1); QTRY_COMPARE(media.snapshot().state,PlaybackState::Stopped);
        stations->selectRow(0); stations->setFocus();
        QTest::keyClick(stations,Qt::Key_Return); QTRY_COMPARE(media.snapshot().stationID,first.id);
        QTest::keyClick(stations,Qt::Key_Space); QTRY_COMPARE(media.snapshot().state,PlaybackState::Stopped);
        QTest::keyClick(stations,Qt::Key_Down);
        QTest::keyClick(stations,Qt::Key_Space); QTRY_COMPARE(media.snapshot().stationID,second.id);
        QTRY_COMPARE(media.snapshot().state,PlaybackState::Resolving);
        media.stop(); QTRY_COMPARE(media.snapshot().state,PlaybackState::Stopped);
        window.applyTheme("stack");
        auto *knob=window.findChild<QSlider *>("volumeKnob"); QVERIFY(knob); QVERIFY(knob->isVisible());
        const int original=knob->value();
        QTest::mousePress(knob,Qt::LeftButton,Qt::NoModifier,QPoint(15,20));
        QTest::mouseMove(knob,QPoint(25,10));
        QTest::mouseRelease(knob,Qt::LeftButton,Qt::NoModifier,QPoint(25,10));
        QVERIFY(knob->value()>original); QTRY_COMPARE(media.snapshot().volume,knob->value());
        media.shutdown();
    }
    void previewTimerAndNoticeStayVisible() {
        QTemporaryDir temporary;
        LibraryStore store(temporary.filePath("data")); QVERIFY(store.load());
        CatalogService catalog(temporary.filePath("cache"));
        MediaEngine media(temporary.filePath("recordings"),temporary.filePath("cache"));
        MainWindow window(&store,&catalog,&media); window.show(); QTest::qWait(30);
        auto *buffer=window.findChild<QWidget *>("bufferControls");
        auto *status=window.findChild<QLabel *>("playbackStatus");
        QVERIFY(buffer); QVERIFY(status);
        PlaybackSnapshot state; state.state=PlaybackState::Playing;state.previewActive=true;
        emit media.snapshotChanged(state); QVERIFY(buffer->isVisible());
        auto *pause=push(buffer,QLocale().language()==QLocale::German?"Pause":"Pause");
        QVERIFY(pause); QVERIFY(pause->isEnabled());
        state.state=PlaybackState::Paused;emit media.snapshotChanged(state);
        QVERIFY(buffer->isVisible()); QVERIFY(pause->isEnabled());
        state.previewActive=false;state.state=PlaybackState::Playing;state.sleepRemaining=120;
        emit media.snapshotChanged(state); QVERIFY(status->isVisible()); QVERIFY(status->text().contains("2:00"));
        state.sleepRemaining=0;state.recordRequested=true;
        state.recordStatus="Fixture recording storage unavailable";
        emit media.snapshotChanged(state);
        QVERIFY(status->isVisible());QVERIFY(status->text().contains(state.recordStatus));
        state.recordRequested=false;
        state.sleepRemaining=0; emit store.error("Fixture persistent notice");emit media.snapshotChanged(state);
        QVERIFY(status->isVisible()); QCOMPARE(status->text(),QString("Fixture persistent notice"));
        media.shutdown();
    }
    void midiFineCellsAndEnergyColors() {
        Console::Visualizer visual;
        visual.theme = "midi";
        visual.resize(300, 500);
        visual.spectrum = QVector<float>(512, .9f);
        // Schwaches Band neben mittleren und starken Bändern: alle drei Farbbereiche müssen sichtbar sein.
        for (int bin = 3; bin < 7; ++bin) visual.spectrum[bin - 1] = .18f;
        visual.rms = .4f;
        visual.show(); QApplication::processEvents();
        const auto frame = visual.grab().toImage();
        auto cell = [&](int lane, int y = 21) {
            return frame.pixelColor(qRound(20 + (lane + .5) * 260 / 24.), y);
        };
        const auto low = cell(6), middle = cell(8), high = cell(22);
        QVERIFY2(low.red() < 140 && low.green() > 140 && low.blue() > 180, "Low energy is turquoise");
        QVERIFY2(middle.red() > 200 && middle.green() < 120 && middle.blue() > 150, "Medium energy is pink");
        QVERIFY2(high.red() > 225 && high.green() > 225 && high.blue() > 225, "High energy approaches white");
        QVERIFY2(cell(22, 25).red() < 180, "One history cell remains thinner than five pixels");
        const auto barTop = cell(22, 449), barBottom = cell(22, 477);
        QVERIFY2(barTop.red() > 200 && barBottom.green() > 150 && barTop.red() > barBottom.red() + 100,
                 "Each lower bar spans the turquoise-to-pink gradient");
        const QString directory = qEnvironmentVariable("MUCKE_UI_SHOTS");
        if (!directory.isEmpty()) {
            QVERIFY(frame.save(directory + "/midi-energy-colors.png"));
            // Synthetische Spektren füllen das Prüfbild; das Produkt erzeugt keine solchen Signale.
            for (int row = 0; row < 140; ++row) {
                for (int bin = 0; bin < 512; ++bin) {
                    const double frequency = std::log2(bin + 1.);
                    const double center = 4.5 + 2 * std::sin(row * .05);
                    visual.spectrum[bin] = .4 * std::exp(-std::pow((frequency - center) / 1.1, 2)) +
                                            .1 * std::exp(-std::pow((frequency - 9) / 1.3, 2));
                }
                visual.update(); QTest::qWait(55);
            }
            QVERIFY(visual.grab().save(directory + "/midi-history.png"));
        }
    }
    void visualizerSignalAndSilence() {
        QTemporaryDir temporary;
        const QString directory=qEnvironmentVariable("MUCKE_UI_SHOTS",temporary.path());
        QDir().mkpath(directory);
        Console::initializeFonts();
        QVERIFY(QFontDatabase::families().contains("Zilla Slab"));
        for (const auto &theme : {"schlicht","acid","retro","fanzine","stack","danish","midi"}) {
            Console::Visualizer visual; visual.theme=theme; visual.resize(300,500); visual.show();
            QApplication::processEvents(); const auto silent=visual.grab().toImage();
            for (int i=0;i<256;++i) visual.wave.append(.65f*std::sin(i*.18f));
            for (int i=0;i<64;++i) visual.spectrum.append(.08f+.75f*std::exp(-std::pow((i-22)/16.f,2)));
            visual.rms=.4f;
            QTest::qWait(50); visual.update(); QApplication::processEvents();
            const auto signal=visual.grab().toImage(); QVERIFY(signal!=silent);
            QVERIFY(signal.save(directory+"/visualizer-"+theme+"-signal.png"));
            visual.wave.clear(); visual.spectrum.clear(); visual.rms=0; visual.update(); QApplication::processEvents();
            QCOMPARE(visual.grab().toImage(),silent);
        }
        const auto previous=QApplication::palette();
        Console::Visualizer visual; visual.resize(300,500); visual.show();
        auto light=previous;light.setColor(QPalette::Window,QColor("#F5F5F5"));QApplication::setPalette(light);
        QApplication::processEvents();const auto lightPixel=visual.grab().toImage().pixelColor(2,2);
        auto dark=previous;dark.setColor(QPalette::Window,QColor("#202020"));QApplication::setPalette(dark);
        QApplication::processEvents();const auto darkPixel=visual.grab().toImage().pixelColor(2,2);
        QVERIFY(lightPixel.lightness()>200);QVERIFY(darkPixel.lightness()<80);
        QApplication::setPalette(previous);
    }
    void dialogs_data() {
        QTest::addColumn<QString>("language");
        QTest::newRow("English") << "en";
        QTest::newRow("Deutsch") << "de";
    }
    void dialogs() {
        QFETCH(QString, language);
        lang = language;
        QTranslator qtTranslations;
        if (lang == "de" && qtTranslations.load(QLocale("de"), "qtbase", "_",
                                                QLibraryInfo::path(QLibraryInfo::TranslationsPath)))
            QCoreApplication::installTranslator(&qtTranslations);
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());
        shots = qEnvironmentVariable("MUCKE_UI_SHOTS", temporary.filePath("shots"));
        QDir().mkpath(shots);
        const QString data = temporary.filePath("data"), cache = temporary.filePath("cache"),
                      recordings = temporary.filePath("recordings");
        QDir().mkpath(recordings);
        QFile audio(recordings + "/fixture.mp3");
        QVERIFY(audio.open(QIODevice::WriteOnly));
        audio.write(QByteArray(128, '\0'));
        audio.close();
        QFile index(recordings + "/index.json");
        QVERIFY(index.open(QIODevice::WriteOnly));
        index.write(
            R"({"version":1,"recordings":[{"id":"fixture","file":"fixture.mp3","station":"Fixture Jazz","sessionID":"session","ext":"mp3","start":"2026-10-28T12:00:00.000Z","end":"2026-10-28T12:02:00.000Z","receivedEnd":"2026-10-28T12:02:00.000Z","bytes":128,"active":false}],"currentBoundaries":[]})");
        index.close();
        LibraryStore store(data);
        QVERIFY(store.load());
        for (const auto &station : store.stations())
            QVERIFY(store.removeStation(station.id));
        auto settings = store.settings();
        settings["language"] = lang;
        settings["selectedTheme"] = "schlicht";
        QVERIFY(store.saveSettings(settings));
        Station station;
        station.id = newID();
        station.name = "Fixture Jazz";
        station.url = "https://radio.example/jazz";
        QVERIFY(store.saveStation(station));
        Track track;
        track.id = newID();
        track.stationID = station.id;
        track.station = station.name;
        track.raw = "Example Artist - Example Song";
        track.artist = "Example Artist";
        track.title = "Example Song";
        track.receivedAt = QDateTime::fromString("2026-10-28T12:00:00Z", Qt::ISODate);
        track.heardAt = track.receivedAt;
        store.receiveTrack(track);
        QVERIFY(store.bookmark(track));
        CatalogService catalog(cache);
        MediaEngine media(recordings, cache);
        MainWindow window(&store, &catalog, &media);
        window.show();
        window.resize(660, 720);
        QApplication::processEvents();
        QCOMPARE(window.width(), 660);
        capture(&window, "main-660");
        auto *historyPeriod = window.findChild<QComboBox *>("historyPeriod");
        QVERIFY(historyPeriod);
        QCOMPARE(historyPeriod->count(), 5);
        auto *from = window.findChild<QDateEdit *>("historyFrom"),
             *through = window.findChild<QDateEdit *>("historyTo");
        QVERIFY(from);
        QVERIFY(through);
        historyPeriod->setCurrentIndex(4);
        from->setDate(QDate(2026, 10, 28));
        through->setDate(QDate(2026, 10, 28));
        auto *historyRows = window.findChild<QTableView *>("history");
        QVERIFY(historyRows);
        QCOMPARE(historyRows->model()->rowCount(), 1);
        QVERIFY(historyRows->viewport()->height() >= historyRows->rowHeight(0));
        capture(&window, "history-custom-660");
        window.applyTheme("acid");
        capture(&window, "history-custom-acid-660");
        window.applyTheme("schlicht");
        QCOMPARE(window.width(), 660);
        from->setDate(QDate(2026, 10, 29));
        through->setDate(QDate(2026, 10, 29));
        QCOMPARE(historyRows->model()->rowCount(), 0);
        historyPeriod->setCurrentIndex(0);
        auto *stationTable = window.findChild<QTableView *>("stations");
        QVERIFY(stationTable);
        QCOMPARE(stationTable->model()->rowCount(), 1);
        stationTable->selectRow(0);
        auto *settingsButton = [&]() -> QPushButton * {
            for (auto *b : window.findChildren<QPushButton *>())
                if (b->toolTip() == label("Einstellungen", "Settings"))
                    return b;
            return nullptr;
        }();
        QVERIFY(settingsButton);
        modal([&] { settingsButton->click(); },
              [&](QDialog *dialog) {
                  QCOMPARE(dialog->windowTitle(), label("Einstellungen", "Settings"));
                  auto *languageControl = dialog->findChild<QComboBox *>("language");
                  QVERIFY(languageControl);
                  QCOMPARE(languageControl->currentData().toString(), lang);
                  QCOMPARE(languageControl->count(), 3);
                  auto *startup = dialog->findChild<QComboBox *>("startupMode");
                  QVERIFY(startup);
                  QCOMPARE(startup->count(), 3);
                  startup->setCurrentIndex(startup->findData("last"));
                  auto *tray = dialog->findChild<QCheckBox *>("closeToTray");
                  QVERIFY(tray);
                  QVERIFY(!tray->isChecked());
                  bool bufferLimits = false;
                  for (auto *label : dialog->findChildren<QLabel *>())
                      if (label->text().contains("32 MiB") && label->text().contains("10 GiB"))
                          bufferLimits = true;
                  QVERIFY(bufferLimits);
                  capture(dialog, "settings-general");
                  auto *pages = dialog->findChild<QTabWidget *>();
                  QVERIFY(pages);
                  pages->setCurrentIndex(1);
                  capture(dialog, "settings-quickslots");
                  pages->setCurrentIndex(2);
                  auto *preamp = dialog->findChild<QDoubleSpinBox *>("equalizerPreamp");
                  QVERIFY(preamp);
                  QCOMPARE(preamp->minimum(), -12.);
                  QCOMPARE(preamp->maximum(), 0.);
                  preamp->setValue(-3.);
                  auto *gain = dialog->findChild<QDoubleSpinBox *>("stationGain");
                  QVERIFY(gain);
                  QCOMPARE(gain->minimum(), -12.);
                  QCOMPARE(gain->maximum(), 12.);
                  auto *eqEnabled = dialog->findChild<QCheckBox *>("equalizerEnabled");
                  QVERIFY(eqEnabled);
                  eqEnabled->setChecked(true);
                  auto *preset = dialog->findChild<QComboBox *>("equalizerPreset");
                  QVERIFY(preset);
                  QCOMPARE(preset->count(), 5);
                  preset->setCurrentIndex(preset->findData(1));
                  auto *headroom = dialog->findChild<QLabel *>("equalizerHeadroom");
                  QVERIFY(headroom);
                  QVERIFY(headroom->text().contains("-6.0 dB"));
                  capture(dialog, "settings-audio-bass");
                  preset->setCurrentIndex(preset->findData(2));
                  capture(dialog, "settings-audio-speech");
                  preset->setCurrentIndex(preset->findData(3));
                  capture(dialog, "settings-audio-soft");
                  preset->setCurrentIndex(preset->findData(0));
                  preamp->setValue(-3.);
                  capture(dialog, "settings-audio");
                  accept(dialog);
              });
        QCOMPARE(store.settings()["autostart"].toString(), QString("last"));
        QCOMPARE(store.settings()["equalizerPreamp"].toDouble(), -3.);
        QVERIFY(!store.settings()["closeToTray"].toBool());
        auto *audioSettings = window.findChild<QPushButton *>("audioSettingsOpen");
        QVERIFY(audioSettings);
        modal([&] { audioSettings->click(); }, [&](QDialog *dialog) {
            auto *pages = dialog->findChild<QTabWidget *>();
            QVERIFY(pages);
            QCOMPARE(pages->tabText(pages->currentIndex()), QString("Audio"));
            dialog->reject();
        });
        auto *add = window.findChild<QPushButton *>("stationAdd");
        QVERIFY(add);
        modal([&] { add->click(); },
              [&](QDialog *dialog) {
                  QCOMPARE(dialog->windowTitle(), label("Sender hinzufügen", "Add station"));
                  auto *name = dialog->findChild<QLineEdit *>("stationName"),
                       *url = dialog->findChild<QLineEdit *>("stationURL");
                  QVERIFY(name);
                  QVERIFY(url);
                  name->setText("Fixture Electronic");
                  url->setText("https://radio.example/electronic");
                  auto *fav = dialog->findChild<QCheckBox *>("stationFavorite");
                  QVERIFY(fav);
                  fav->setChecked(true);
                  capture(dialog, "station-editor");
                  accept(dialog);
              });
        QCOMPARE(store.stations().size(), 2);
        bool favoriteSaved = false;
        for (auto s : store.stations())
            if (s.name == "Fixture Electronic")
                favoriteSaved = s.favorite;
        QVERIFY(favoriteSaved);
        stationTable->selectRow(1);
        QPushButton *editStation = nullptr;
        for (auto *button : window.findChildren<QPushButton *>())
            if (button->toolTip() == label("Sender bearbeiten", "Edit station"))
                editStation = button;
        QVERIFY(editStation);
        modal([&] { editStation->click(); },
              [&](QDialog *dialog) {
                  auto *position = dialog->findChild<QSpinBox *>("stationPosition");
                  QVERIFY(position);
                  position->setValue(1);
                  accept(dialog);
              });
        QCOMPARE(store.stations().first().name, QString("Fixture Electronic"));
        auto *groupsAction = action(&window, label("Gruppen …", "Groups …"));
        QVERIFY(groupsAction);
        modal([&] { groupsAction->trigger(); },
              [&](QDialog *dialog) {
                  auto *create = push(dialog, label("Neu", "New"));
                  QVERIFY(create);
                  modal([&] { create->click(); },
                        [&](QDialog *input) {
                            auto *name = input->findChild<QLineEdit *>();
                            QVERIFY(name);
                            name->setText("Fixture Group");
                            input->accept();
                        });
                  capture(dialog, "groups");
                  dialog->reject();
              });
        bool groupSaved = false;
        for (auto g : store.groups())
            if (g.name == "Fixture Group")
                groupSaved = true;
        QVERIFY(groupSaved);
        auto *catalogButton = window.findChild<QPushButton *>("catalogOpen");
        QVERIFY(catalogButton);
        modal([&] { catalogButton->click(); },
              [&](QDialog *dialog) {
                  QCOMPARE(dialog->objectName(), QString("catalogDialog"));
                  for (const auto &caption :
                       {label("Name", "Name"), label("Land (Code)", "Country (code)"),
                        label("Sprache", "Language"), label("Tag", "Tag"), QString("Codec")}) {
                      bool found = false;
                      for (auto *field : dialog->findChildren<QLineEdit *>())
                          if (field->accessibleName() == caption)
                              found = true;
                      QVERIFY(found);
                  }
                  capture(dialog, "catalog");
                  dialog->reject();
              });
        const QString exchange = temporary.filePath("exchange.json");
        QVERIFY(store.exportLibrary(exchange));
        station.name = "Local renamed station";
        QVERIFY(store.saveStation(station));
        auto *import = action(&window, label("Importieren …", "Import …"));
        QVERIFY(import);
        bool previewReached = false;
        QObject importGuard;
        modal([&] { import->trigger(); },
              [&](QDialog *dialog) {
                  auto *fileDialog = qobject_cast<QFileDialog *>(dialog);
                  QVERIFY(fileDialog);
                  QTimer::singleShot(0, &importGuard, [&] {
                      auto *preview = qobject_cast<QDialog *>(QApplication::activeModalWidget());
                      QVERIFY(preview);
                      QCOMPARE(preview->objectName(), QString("importPreview"));
                      previewReached = true;
                      auto *items = preview->findChild<QTableWidget *>();
                      QVERIFY(items);
                      QVERIFY(items->rowCount() >= 2);
                      for (int row = 0; row < items->rowCount(); ++row) {
                          if (items->item(row, 1)->text().contains("Local renamed station")) {
                              items->setCurrentCell(row, 3);
                              items->editItem(items->item(row, 3));
                              auto *choice = items->findChild<QComboBox *>("importChoice");
                              QVERIFY(choice);
                              choice->setCurrentIndex(choice->findData("incoming"));
                              QTest::keyClick(choice, Qt::Key_Tab);
                          }
                      }
                      capture(preview, "import-preview");
                      accept(preview, QDialogButtonBox::Ok);
                  });
                  fileDialog->selectFile(exchange);
                  QMetaObject::invokeMethod(fileDialog, "accept", Qt::DirectConnection);
              });
        QVERIFY(previewReached);
        QCOMPARE(store.station(station.id).name, QString("Fixture Jazz"));
        auto *genres = action(&window, label("Genrelisten …", "Genre collections …"));
        QVERIFY(genres);
        bool genrePreview = false;
        QObject genreGuard;
        modal([&] { genres->trigger(); },
              [&](QDialog *dialog) {
                  QCOMPARE(dialog->objectName(), QString("genreLists"));
                  auto *collections = dialog->findChild<QListWidget *>("genreCollections");
                  QVERIFY(collections);
                  QCOMPARE(collections->count(), 5);
                  for (int i = 0; i < collections->count(); ++i)
                      if (collections->item(i)->text() == "Chillout & Ambient")
                          collections->setCurrentRow(i);
                  capture(dialog, "genre-collections");
                  QTimer::singleShot(0, &genreGuard, [&] {
                      auto *preview = qobject_cast<QDialog *>(QApplication::activeModalWidget());
                      QVERIFY(preview);
                      QCOMPARE(preview->objectName(), QString("importPreview"));
                      auto *items = preview->findChild<QTableWidget *>();
                      QVERIFY(items);
                      QVERIFY(items->rowCount() >= 5);
                      bool publicStation = false;
                      for (int row = 0; row < items->rowCount(); ++row)
                          if (items->item(row, 2)->text().contains("SomaFM Groove Salad"))
                              publicStation = true;
                      QVERIFY(publicStation);
                      genrePreview = true;
                      capture(preview, "genre-import-preview");
                      preview->reject();
                  });
                  accept(dialog, QDialogButtonBox::Ok);
              });
        QVERIFY(genrePreview);
        QCOMPARE(store.stations().size(), 2);
        auto *tabs = window.findChild<QTabWidget *>("libraryTabs");
        QVERIFY(tabs);
        tabs->setCurrentIndex(1);
        auto *bookmarkSearch = window.findChild<QLineEdit *>("bookmarkSearch");
        QVERIFY(bookmarkSearch);
        auto *bookmarkTable = window.findChild<QTableView *>("bookmarks");
        QVERIFY(bookmarkTable);
        bookmarkSearch->setText("does not exist");
        QCOMPARE(bookmarkTable->model()->rowCount(), 0);
        bookmarkSearch->setText("Example Song");
        QCOMPARE(bookmarkTable->model()->rowCount(), 1);
        Track otherBookmark = track;
        otherBookmark.id = newID();
        otherBookmark.artist = "Other Artist";
        otherBookmark.title = "Another Song";
        otherBookmark.raw = "Other Artist - Another Song";
        QVERIFY(store.bookmark(otherBookmark));
        auto *exportButton = push(&window, label("Exportieren …", "Export …"));
        QVERIFY(exportButton);
        for (bool empty : {false, true}) {
            bookmarkSearch->setText(empty ? "No matching bookmark" : "Example Song");
            const QString destination = temporary.filePath(empty ? "empty-visible.csv" : "visible.csv");
            modal([&] { exportButton->click(); },
                  [&](QDialog *dialog) {
                      auto *file = qobject_cast<QFileDialog *>(dialog);
                      QVERIFY(file);
                      file->selectFile(destination);
                      QMetaObject::invokeMethod(file, "accept", Qt::DirectConnection);
                  });
            QFile exported(destination);
            QVERIFY(exported.open(QIODevice::ReadOnly));
            const QByteArray content = exported.readAll();
            QVERIFY(!content.contains("Other Artist"));
            QCOMPARE(content.contains("Example Artist"), !empty);
        }
        QVERIFY(store.removeBookmark(otherBookmark.id));
        bookmarkSearch->clear();
        capture(&window, "bookmarks-660");
        tabs->setCurrentIndex(0);
        auto *historyTable = window.findChild<QTableView *>("history");
        QVERIFY(historyTable);
        historyTable->selectRow(0);
        QCOMPARE(historyTable->selectionMode(), QAbstractItemView::ExtendedSelection);
        auto *audioExport = window.findChild<QPushButton *>("historyAudioExport");
        QVERIFY(audioExport);
        modal([&] { audioExport->click(); }, [&](QDialog *dialog) {
            QCOMPARE(dialog->objectName(), QString("songExportDialog"));
            auto *rows = dialog->findChild<QTableView *>("songExportTable");
            QVERIFY(rows);
            QCOMPARE(rows->model()->rowCount(), 1);
            QTRY_VERIFY_WITH_TIMEOUT(!rows->model()->index(0, 1).data().toString().isEmpty(), 5000);
            QVERIFY(!dialog->findChild<QPushButton *>("songPrepare")->isEnabled());
            capture(dialog, "song-export-no-audio");
            dialog->reject();
        });
        window.resize(660, 720);
        QApplication::processEvents();
        QCOMPARE(window.width(), 660);
        QCOMPARE(window.height(), 720);
        QVERIFY(historyTable->viewport()->height() >= historyTable->rowHeight(0));
        capture(&window, "history-audio-export-660");
        auto *trackActions = window.findChild<QPushButton *>("historyTrackActions");
        QVERIFY(trackActions);
        bool menuReached = false;
        {
            QObject menuGuard;
            QTimer::singleShot(2500, &menuGuard, [] {
                if (auto *menu = qobject_cast<QMenu *>(QApplication::activePopupWidget()))
                    menu->close();
            });
            QTimer::singleShot(0, &menuGuard, [&] {
                auto *menu = qobject_cast<QMenu *>(QApplication::activePopupWidget());
                QVERIFY(menu);
                menuReached = true;
                QAction *lyrics = nullptr;
                for (auto *item : menu->actions())
                    if (item->text() == label("Songtext …", "Lyrics …"))
                        lyrics = item;
                QVERIFY(lyrics);
                capture(menu, "track-actions");
                menu->close();
                modal([&] { lyrics->trigger(); },
                      [&](QDialog *dialog) {
                          QCOMPARE(dialog->objectName(), QString("lyricsDialog"));
                          capture(dialog, "lyrics");
                          dialog->reject();
                      });
            });
            trackActions->click();
        }
        QVERIFY(menuReached);
        tabs->setCurrentIndex(2);
        auto *recordingTable = window.findChild<QTableView *>("recordings");
        QVERIFY(recordingTable);
        QTRY_VERIFY_WITH_TIMEOUT(recordingTable->model()->rowCount() > 0, 5000);
        recordingTable->selectRow(0);
        capture(&window, "recordings-660");
        QVERIFY(action(&window, label("Quellcode und Lizenzen", "Source code and licenses")));
        QVERIFY(action(&window, label("Impressum", "Legal notice")));
        QVERIFY(action(&window, label("Datenschutz", "Privacy")));
        modal([&] { action(&window, label("Über Mucke, Baby!", "About Mucke, Baby!"))->trigger(); },
              [&](QDialog *dialog) { capture(dialog, "about"); dialog->accept(); });
        auto *clip = push(&window, label("Ausschnitt …", "Clip …"));
        QVERIFY(clip);
        modal([&] { clip->click(); },
              [&](QDialog *dialog) {
                  QCOMPARE(dialog->objectName(), QString("exportClip"));
                  auto *save = push(dialog, label("Speichern …", "Save …"));
                  QVERIFY(save);
                  QVERIFY(!save->isEnabled());
                  capture(dialog, "export-clip");
                  dialog->reject();
              });
        window.showMiniPlayer();
        QApplication::processEvents();
        auto *mini = window.findChild<QDialog *>("miniPlayer");
        QVERIFY(mini);
        QVERIFY(mini->isVisible());
        capture(mini, "mini");
        auto *miniStations = mini->findChild<QComboBox *>("miniStations");
        QVERIFY(miniStations);
        QCOMPARE(miniStations->count(), 3);
        auto disabledStation = store.stations().first();
        disabledStation.enabled = false;
        QVERIFY(store.saveStation(disabledStation));
        QCOMPARE(miniStations->count(), 2);
        disabledStation.enabled = true;
        QVERIFY(store.saveStation(disabledStation));
        QCOMPARE(miniStations->count(), 3);
        auto *top = mini->findChild<QAbstractButton *>("miniAlwaysOnTop");
        QVERIFY(top);
        QVERIFY(!top->isChecked());
        top->setChecked(true);
        QVERIFY(store.settings()["miniAlwaysOnTop"].toBool());
        QVERIFY(mini->windowFlags().testFlag(Qt::WindowStaysOnTopHint));
        top->setChecked(false);
        auto *miniVolume = mini->findChild<QSlider *>("miniVolume");
        QVERIFY(miniVolume);
        miniVolume->setValue(35);
        QTRY_COMPARE(window.findChild<QSlider *>("volume")->value(), 35);
        {
            QSignalBlocker backend(&media);
            backend.unblock();
            PlaybackSnapshot buffered;
            buffered.state = PlaybackState::Playing;
            buffered.stationID = station.id;
            buffered.stationName = station.name;
            buffered.heardTrack = track;
            buffered.volume = 35;
            buffered.timeshiftEnabled = true;
            buffered.timeshiftAvailable = true;
            buffered.bufferSeconds = 75;
            buffered.delaySeconds = 20;
            buffered.recordRequested = true;
            buffered.recordStatus = label("Aufnahme angefordert", "Recording requested");
            media.snapshotChanged(buffered);
            backend.reblock();
            QVERIFY(mini->findChild<QPushButton *>("miniPause")->isEnabled());
            QVERIFY(mini->findChild<QPushButton *>("miniBack15")->isEnabled());
            QVERIFY(mini->findChild<QPushButton *>("miniForward15")->isEnabled());
            QCOMPARE(mini->findChild<QSlider *>("miniDelay")->value(), 20);
            capture(mini, "mini-buffered");
            backend.unblock();
            buffered.state = PlaybackState::Paused;
            buffered.timeshiftPaused = true;
            media.snapshotChanged(buffered);
            backend.reblock();
            QCOMPARE(mini->findChild<QPushButton *>("miniPause")->text(), label("Fortsetzen", "Resume"));
            QCOMPARE(mini->findChild<QPushButton *>("miniPlay")->text(), label("Stopp", "Stop"));
            capture(mini, "mini-paused");
            backend.unblock();
            PlaybackSnapshot stopped;
            stopped.volume = 35;
            media.snapshotChanged(stopped);
            media.visualization({.8f, -.8f}, {.9f}, .7f);
            backend.reblock();
            QVERIFY(!mini->findChild<QPushButton *>("miniPause")->isEnabled());
            QVERIFY(!mini->findChild<QSlider *>("miniDelay")->isEnabled());
        }
        for (const auto &theme : {"schlicht","acid","retro","fanzine","stack","danish","midi"}) {
            window.applyTheme(theme); mini->resize(420,240); QApplication::processEvents();
            capture(mini,QString("mini-")+theme);
            mini->resize(360,240); QApplication::processEvents(); QCOMPARE(mini->width(),360);
        }
        mini->hide();
        window.showVisualizer();
        QApplication::processEvents();
        auto *full = window.findChild<QDialog *>("fullscreenVisualizer");
        QVERIFY(full);
        QVERIFY(full->isVisible());
        capture(full, "visualizer");
        full->hide();
        media.shutdown();
        const QString reloadDirectory = temporary.filePath("reloaded");
        QVERIFY(QDir().mkpath(reloadDirectory));
        for (const auto &file : QDir(data).entryList({"*.json"}, QDir::Files))
            QVERIFY(QFile::copy(data + "/" + file, reloadDirectory + "/" + file));
        LibraryStore reloaded(reloadDirectory);
        QVERIFY(reloaded.load());
        QCOMPARE(reloaded.stations().size(), 2);
        QCOMPARE(reloaded.settings()["autostart"].toString(), QString("last"));
    }
};
int main(int argc, char **argv) {
    QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
    QApplication application(argc, argv);
    QStandardPaths::setTestModeEnabled(true);
    UIFlowTest test;
    return QTest::qExec(&test, argc, argv);
}
#include "ui_flow_test.moc"
