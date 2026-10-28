#include "mainwindow.h"
#include "consolewidgets.h"
#include "../buildinfo.h"
#include "../data/catalogservice.h"
#include "../data/librarystore.h"
#include "../media/mediaengine.h"
#include "historyfilter_p.h"
#include "songtools_p.h"
#include "songexportdialog.h"
#include "songexportfile_p.h"
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QThread>
#include <QtWidgets>
#include <algorithm>
#include <cmath>
#include <memory>

namespace Mucke {
namespace {
QString text(const char *de, const char *en) {
    return QLocale().language() == QLocale::German ? QString::fromUtf8(de) : QString::fromUtf8(en);
}
QString trackName(const Track &t) {
    return t.artist.isEmpty() ? (t.title.isEmpty() ? t.raw : t.title) : t.artist + " — " + t.title;
}
QString duration(double seconds) {
    int n = std::max(0, int(seconds));
    return QString("%1:%2").arg(n / 60).arg(n % 60, 2, 10, QChar('0'));
}
const QStringList themeIDs = {"schlicht", "acid", "retro", "fanzine", "stack", "danish", "midi"};
const QStringList themeNames = {"Standard",  "Acid Rave", "Retro",     "Fanzine",
                                "GuitarAmp", "Danish",    "Black MIDI"};
using Console::colors;
using Console::Surface;
using Console::SurfaceWidget;
using Console::Symbol;
using Console::Visualizer;
class ActivityObserver final : public QObject {
  public:
    std::function<void()> changed;
    explicit ActivityObserver(QObject *parent) : QObject(parent) {}
    bool eventFilter(QObject *, QEvent *event) override {
        if ((event->type() == QEvent::Show || event->type() == QEvent::Hide ||
             event->type() == QEvent::WindowStateChange || event->type() == QEvent::Resize) &&
            changed)
            changed();
        return false;
    }
};
QPushButton *button(QString label, QBoxLayout *layout, const std::function<void()> &action) {
    auto *b = new QPushButton(label);
    b->setMinimumHeight(32);
    layout->addWidget(b);
    QObject::connect(b, &QPushButton::clicked, b, action);
    return b;
}
QDialogButtonBox *dialogButtons(QDialogButtonBox::StandardButtons buttons) {
    auto *box = new QDialogButtonBox(buttons);
    const QList<QPair<QDialogButtonBox::StandardButton, QString>> captions = {
        {QDialogButtonBox::Save, text("Speichern", "Save")},
        {QDialogButtonBox::Cancel, text("Abbrechen", "Cancel")},
        {QDialogButtonBox::Close, text("Schließen", "Close")},
        {QDialogButtonBox::Ok, QString("OK")}};
    for (const auto &caption : captions)
        if (auto *button = box->button(caption.first))
            button->setText(caption.second);
    return box;
}
QTableView *table(QStandardItemModel *model) {
    auto *v = new QTableView;
    v->setModel(model);
    v->setSelectionBehavior(QAbstractItemView::SelectRows);
    v->setSelectionMode(QAbstractItemView::SingleSelection);
    v->setEditTriggers(QAbstractItemView::NoEditTriggers);
    v->setAlternatingRowColors(true);
    v->verticalHeader()->hide();
    v->horizontalHeader()->setStretchLastSection(false);
    v->horizontalHeader()->setDefaultAlignment(Qt::AlignLeft | Qt::AlignVCenter);
    v->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
    v->setShowGrid(false);
    return v;
}
void row(QStandardItemModel *m, QStringList values, QString id = {}) {
    QList<QStandardItem *> cells;
    for (auto value : values) {
        auto *item = new QStandardItem(value);
        item->setToolTip("<qt>" + value.toHtmlEscaped() + "</qt>");
        cells.append(item);
    }
    if (!cells.isEmpty())
        cells[0]->setData(id, Qt::UserRole);
    if (!cells.isEmpty())
        cells[0]->setAccessibleText(values.join(" · "));
    m->appendRow(cells);
}
QString selectedID(QTableView *v) {
    auto ix = v->currentIndex();
    return ix.isValid() ? v->model()->index(ix.row(), 0).data(Qt::UserRole).toString() : QString();
}
constexpr int ImportChoiceRole = Qt::UserRole + 1;
constexpr int ImportConflictRole = Qt::UserRole + 2;
QString importChoiceCaption(QString key) {
    if (key == "local")
        return text("Lokal behalten", "Keep local");
    if (key == "both")
        return text("Beide behalten", "Keep both");
    if (key == "skip")
        return text("Überspringen", "Skip");
    return text("Import", "Incoming");
}
class ImportChoiceDelegate final : public QStyledItemDelegate {
  public:
    explicit ImportChoiceDelegate(QObject *parent) : QStyledItemDelegate(parent) {}
    void paint(QPainter *painter, const QStyleOptionViewItem &option,
               const QModelIndex &index) const override {
        QStyleOptionComboBox combo;
        combo.rect =
            QRect(option.rect.left() + 4, option.rect.center().y() - 16, option.rect.width() - 8, 32);
        combo.state = option.state;
        combo.palette = option.palette;
        combo.currentText = index.data().toString();
        combo.subControls = QStyle::SC_All;
        combo.frame = true;
        QStyle *style = option.widget ? option.widget->style() : QApplication::style();
        style->drawComplexControl(QStyle::CC_ComboBox, &combo, painter, option.widget);
        style->drawControl(QStyle::CE_ComboBoxLabel, &combo, painter, option.widget);
    }
    QWidget *createEditor(QWidget *parent, const QStyleOptionViewItem &,
                          const QModelIndex &index) const override {
        auto *combo = new QComboBox(parent);
        combo->setObjectName("importChoice");
        for (const auto &key : {QString("incoming"), QString("local"), QString("both"), QString("skip")}) {
            if (key == "both" && !index.data(ImportConflictRole).toBool())
                continue;
            combo->addItem(importChoiceCaption(key), key);
        }
        return combo;
    }
    void setEditorData(QWidget *editor, const QModelIndex &index) const override {
        auto *combo = qobject_cast<QComboBox *>(editor);
        combo->setCurrentIndex(std::max(0, combo->findData(index.data(ImportChoiceRole))));
    }
    void setModelData(QWidget *editor, QAbstractItemModel *model, const QModelIndex &index) const override {
        auto *combo = qobject_cast<QComboBox *>(editor);
        model->setData(index, combo->currentData(), ImportChoiceRole);
        model->setData(index, combo->currentText(), Qt::DisplayRole);
    }
    void updateEditorGeometry(QWidget *editor, const QStyleOptionViewItem &option,
                              const QModelIndex &) const override {
        editor->setGeometry(
            QRect(option.rect.left() + 4, option.rect.center().y() - 16, option.rect.width() - 8, 32));
    }
};

class LyricsDialog final : public QDialog {
    QNetworkAccessManager network;
    QPointer<QNetworkReply> active;
    QPlainTextEdit *lyrics;
    QLabel *state;
    QVector<QPair<QString, QString>> queries;
    QByteArray bytes;
    int queryIndex = 0;
    bool timedOut = false;
    void next() {
        if (!isVisible())
            return;
        if (timedOut || queryIndex >= queries.size()) {
            state->setText(text("Kein Songtext gefunden. Die Websuche kann weitere Quellen zeigen.",
                                "No lyrics found. Web search may find other sources."));
            return;
        }
        const auto query = queries[queryIndex++];
        QNetworkRequest request(SongTools::lyricsURL(query.first, query.second));
        request.setHeader(QNetworkRequest::UserAgentHeader, "MuckeBabyLinux");
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
        request.setTransferTimeout(6000);
        bytes.clear();
        active = network.get(request);
        active->setReadBufferSize(65536);
        auto *reply = active.data();
        QObject::connect(reply, &QNetworkReply::readyRead, this, [this, reply] {
            bytes += reply->readAll();
            if (bytes.size() > 512 * 1024)
                reply->abort();
        });
        QObject::connect(reply, &QNetworkReply::finished, this, [this, reply] {
            bytes += reply->readAll();
            const bool ok = reply->error() == QNetworkReply::NoError &&
                            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200 &&
                            bytes.size() <= 512 * 1024;
            const QString result =
                ok ? QJsonDocument::fromJson(bytes).object()["lyrics"].toString().trimmed() : QString();
            active = nullptr;
            reply->deleteLater();
            if (!result.isEmpty()) {
                lyrics->setPlainText(result);
                state->setText(text("Quelle: lyrics.ovh", "Source: lyrics.ovh"));
            } else
                next();
        });
    }

  public:
    explicit LyricsDialog(const Track &track, QWidget *parent) : QDialog(parent) {
        setObjectName("lyricsDialog");
        setWindowTitle(text("Songtext", "Lyrics"));
        resize(520, 590);
        auto *layout = new QVBoxLayout(this);
        auto *heading = new QLabel(trackName(track));
        heading->setTextFormat(Qt::PlainText);
        heading->setWordWrap(true);
        layout->addWidget(heading);
        state =
            new QLabel(text("Songtext wird bei lyrics.ovh gesucht …", "Searching lyrics.ovh for lyrics …"));
        state->setWordWrap(true);
        layout->addWidget(state);
        lyrics = new QPlainTextEdit;
        lyrics->setReadOnly(true);
        layout->addWidget(lyrics, 1);
        auto *actions = new QHBoxLayout;
        layout->addLayout(actions);
        button(text("Im Web suchen", "Search the web"), actions,
               [track] { QDesktopServices::openUrl(SongTools::lyricsSearchURL(track)); });
        button(text("Schließen", "Close"), actions, [this] { reject(); });
        queries = SongTools::lyricsQueries(track);
        QTimer::singleShot(0, this, [this] { next(); });
        QTimer::singleShot(20000, this, [this] {
            timedOut = true;
            if (active)
                active->abort();
        });
    }
    ~LyricsDialog() override {
        if (active) {
            active->disconnect(this);
            active->abort();
        }
    }
};

} // namespace
class MainWindow::Impl {
  public:
    MainWindow *q;
    LibraryStore *store;
    CatalogService *catalog;
    MediaEngine *media;
    QLineEdit *search, *historySearch, *bookmarkSearch;
    QComboBox *group, *historyStation, *period, *themes;
    QCheckBox *favorites;
    QDateEdit *historyFrom, *historyTo;
    QWidget *historyDates;
    QTableView *stationView, *historyView, *bookmarkView, *recordingView;
    QStandardItemModel *stationModel, *historyModel, *bookmarkModel, *recordingModel;
    QTabWidget *tabs;
    QLabel *now, *artist, *status, *recordStatus, *bufferStatus;
    QPushButton *play, *pause, *record, *bookmark;
    QPushButton *fullScreenButton = nullptr;
    QSlider *volume, *delay;
    QPushButton *back15, *forward15;
    Visualizer *visual;
    Console::Columns *columns;
    SurfaceWidget *headerSurface, *stationSurface, *historySurface, *footerSurface;
    QWidget *bufferControls;
    QLabel *stationCount, *historyCount, *historyHeading, *runtime;
    Console::VolumeKnob *volumeKnob;
    Console::ItemDelegate *stationDelegate, *historyDelegate, *bookmarkDelegate;
    QHash<QPushButton *, Symbol> iconButtons;
    QPushButton *historyToggle, *liveButton;
    QPushButton *iconButton(Symbol symbol, QString tooltip, QBoxLayout *layout,
                            const std::function<void()> &action, QString name = {}) {
        auto *control = button("", layout, action);
        control->setFixedSize(28, 28);
        control->setProperty("consoleButton", true);
        control->setToolTip(tooltip);
        control->setAccessibleName(tooltip);
        control->setObjectName(name);
        iconButtons.insert(control, symbol);
        return control;
    }

    QDialog *mini = nullptr, *full = nullptr;
    SurfaceWidget *miniSurface = nullptr;
    QWidget *miniBufferControls = nullptr;
    QLabel *miniTitle = nullptr;
    QPushButton *miniPlay = nullptr, *miniPause = nullptr, *miniRecord = nullptr, *miniBack = nullptr,
                *miniForward = nullptr, *miniLive = nullptr;
    QLabel *miniStatus = nullptr, *miniBuffer = nullptr;
    QComboBox *miniStations = nullptr;
    QSlider *miniDelay = nullptr;
    Visualizer *fullVisual = nullptr;
    QComboBox *fullThemes = nullptr;
    PlaybackSnapshot state;
    QString theme = "schlicht";
    QTimer animation;
    QTimer noticeTimer;
    QString notice;
    QTimer runtimeTimer;
    QElapsedTimer playbackClock;
    QString clockStation;
    bool framePending = false, visualizationActive = false;
    QObject callbacks;
    ActivityObserver *windowActivity = nullptr, *fullActivity = nullptr;
    bool updating = false;
    QPushButton *actionButton(Symbol symbol, QString label, QBoxLayout *layout,
                              const std::function<void()> &action, QString name = {}) {
        auto *control = new Console::ActionButton(label);
        layout->addWidget(control);
        control->setProperty("consoleButton", true);
        control->setObjectName(name);
        control->setToolTip(label);
        control->setAccessibleName(label);
        iconButtons.insert(control, symbol);
        QObject::connect(control, &QPushButton::clicked, control, action);
        return control;
    }
    Impl(MainWindow *window, LibraryStore *s, CatalogService *c, MediaEngine *m)
        : q(window), store(s), catalog(c), media(m) {
        Console::initializeFonts();
        auto language = store->settings()["language"].toString();
        if (language == "de" || language == "en")
            QLocale::setDefault(QLocale(language));
        q->setWindowTitle("Mucke, Baby!");
        q->resize(940, 620);
        q->setMinimumSize(620, 420);
        auto *root = new QWidget;
        root->setObjectName("shell");
        q->setCentralWidget(root);
        auto *layout = new QVBoxLayout(root);
        layout->setContentsMargins(0, 0, 0, 0);
        layout->setSpacing(1);
        headerSurface = new SurfaceWidget(Surface::Header);
        headerSurface->setObjectName("consoleHeader");
        auto *heading = new QHBoxLayout(headerSurface);
        heading->setContentsMargins(14, 0, 14, 0);
        heading->setSpacing(8);
        auto *brand = new QLabel("Mucke, Baby!");
        brand->setObjectName("brand");
        heading->addWidget(brand);
        auto *version = new QLabel(QString("v%1").arg(MUCKE_VERSION));
        version->setObjectName("version");
        heading->addWidget(version);
        heading->addStretch();
        play = button(text("▶ Abspielen", "▶ Play"), heading, [this] { togglePlayback(); });
        play->setObjectName("mainPlay");
        play->setProperty("consoleButton", true);
        play->setMinimumHeight(26);
        auto *divider = new QFrame;
        divider->setFrameShape(QFrame::VLine);
        divider->setFixedHeight(20);
        heading->addWidget(divider);
        iconButton(
            Symbol::Search, text("Senderkatalog", "Station catalog"), heading, [this] { catalogDialog(); },
            "catalogOpen");
        iconButton(
            Symbol::Add, text("Sender hinzufügen", "Add station"), heading, [this] { editStation({}); },
            "stationAdd");
        iconButton(
            Symbol::Edit, text("Sender bearbeiten", "Edit station"), heading,
            [this] { editStation(selectedID(stationView)); }, "stationEdit");
        iconButton(
            Symbol::Settings, text("Einstellungen", "Settings"), heading, [this] { settings(); },
            "settingsOpen");
        iconButton(Symbol::Audio, text("Audioeinstellungen", "Audio settings"), heading,
                   [this] { settings(2); }, "audioSettingsOpen");
        historyToggle = iconButton(Symbol::History, text("Verlauf ein-/ausblenden", "Show or hide history"),
                                   heading, [this] { columns->showHistory(!columns->hasHistory()); });
        themes = new QComboBox(root);
        themes->addItems(themeNames);
        themes->hide();
        themes->setAccessibleName(text("Theme", "Theme"));
        auto *themeButton = iconButton(Symbol::Palette, text("Theme wählen", "Choose theme"), heading, [] {});
        auto *themeMenu = new QMenu(themeButton);
        for (int i = 0; i < themeIDs.size(); ++i)
            themeMenu->addAction(themeNames[i], q, [this, i] { themes->setCurrentIndex(i); });
        themeButton->setMenu(themeMenu);
        auto *moreButton = iconButton(Symbol::More, text("Weitere Aktionen", "More actions"), heading, [] {});
        auto *mainMenu = new QMenu(moreButton);
        moreButton->setMenu(mainMenu);
        mainMenu->addAction(text("Miniplayer", "Mini player"), q, [this] { miniPlayer(); });
        auto *fullButton = new QPushButton(q);
        fullButton->hide();
        fullScreenButton = fullButton;
        mainMenu->addAction(text("Vollbild-Visualizer", "Fullscreen visualizer"), q,
                            [this] { fullScreen(); });
        mainMenu->addSeparator();
        layout->addWidget(headerSurface);
        stationSurface = new SurfaceWidget(Surface::Panel);
        stationSurface->setObjectName("stationPanel");
        auto *left = stationSurface;
        auto *ll = new QVBoxLayout(left);
        ll->setContentsMargins(0, 0, 0, 0);
        ll->setSpacing(0);
        auto *stationHeading = new QHBoxLayout;
        stationHeading->setContentsMargins(12, 5, 10, 5);
        auto *stationsCaption = new QLabel("STATIONS");
        stationsCaption->setObjectName("sectionHeading");
        stationHeading->addWidget(stationsCaption);
        stationHeading->addStretch();
        iconButton(Symbol::List, text("Sender auswählen", "Choose station"), stationHeading, [this] {
            search->setFocus();
            search->selectAll();
        });
        iconButton(Symbol::Folder, text("Sendergruppen", "Station groups"), stationHeading,
                   [this] { groupsDialog(); });
        ll->addLayout(stationHeading);
        auto *stationFilters = new QWidget;
        stationFilters->setObjectName("stationFilters");
        auto *filterLayout = new QVBoxLayout(stationFilters);
        filterLayout->setContentsMargins(12, 8, 12, 6);
        filterLayout->setSpacing(6);
        search = new QLineEdit;
        search->setObjectName("stationSearch");
        search->setPlaceholderText(text("Sender suchen …", "Search stations …"));
        search->setFixedHeight(30);
        filterLayout->addWidget(search);
        auto *filters = new QHBoxLayout;
        group = new QComboBox;
        favorites = new QCheckBox("★");
        favorites->setToolTip(text("Nur Favoriten", "Favorites only"));
        favorites->setAccessibleName(favorites->toolTip());
        group->setMaximumWidth(180);
        filters->addWidget(group);
        filters->addWidget(favorites);
        filters->addStretch();
        filterLayout->addLayout(filters);
        stationCount = new QLabel;
        stationCount->setObjectName("resultCount");
        filterLayout->addWidget(stationCount);
        ll->addWidget(stationFilters);
        stationModel = new QStandardItemModel(q);
        stationModel->setHorizontalHeaderLabels({text("Sender", "Station"), "★"});
        stationView = table(stationModel);
        stationView->setObjectName("stations");
        stationView->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
        stationView->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Fixed);
        stationView->horizontalHeader()->setMinimumSectionSize(24);
        stationView->setColumnWidth(1, 28);
        stationView->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        ll->addWidget(stationView, 1);
        stationView->horizontalHeader()->hide();
        stationView->setColumnHidden(1, true);
        stationView->setFrameShape(QFrame::NoFrame);
        stationView->setAlternatingRowColors(false);
        stationDelegate = new Console::ItemDelegate(Console::ItemDelegate::Kind::Station, stationView);
        stationView->setItemDelegate(stationDelegate);
        historySurface = new SurfaceWidget(Surface::History);
        historySurface->setObjectName("historyPanel");
        auto *right = historySurface;
        auto *rl = new QVBoxLayout(right);
        rl->setContentsMargins(0, 0, 0, 0);
        rl->setSpacing(0);
        auto *rightHeading = new QHBoxLayout;
        rightHeading->setContentsMargins(10, 5, 8, 5);
        historyHeading = new QLabel(text("Verlauf", "History"));
        historyHeading->setObjectName("historyHeading");
        rightHeading->addWidget(historyHeading);
        rightHeading->addStretch();
        iconButton(Symbol::Waveform, text("Aufnahmebibliothek", "Recording library"), rightHeading,
                   [this] { tabs->setCurrentIndex(2); });
        auto *libraryPicker =
            iconButton(Symbol::More, text("Bibliothek anzeigen", "Show library"), rightHeading, [] {});
        auto *libraryMenu = new QMenu(libraryPicker);
        libraryPicker->setMenu(libraryMenu);
        for (const auto &entry :
             {qMakePair(text("Verlauf", "History"), 0), qMakePair(text("Merkliste", "Bookmarks"), 1),
              qMakePair(text("Aufnahmen", "Recordings"), 2)})
            libraryMenu->addAction(entry.first, q,
                                   [this, index = entry.second] { tabs->setCurrentIndex(index); });
        iconButton(Symbol::History, text("Verlauf ausblenden", "Hide history"), rightHeading,
                   [this] { columns->showHistory(false); });
        rl->addLayout(rightHeading);
        tabs = new QTabWidget;
        tabs->setObjectName("libraryTabs");
        tabs->tabBar()->hide();
        QObject::connect(tabs, &QTabWidget::currentChanged, q, [this](int index) {
            historyHeading->setText(index == 1        ? text("Merkliste", "Bookmarks")
                                    : index == 2      ? text("Aufnahmen", "Recordings")
                                    : theme == "midi" ? "PLAYBACK_HISTORY"
                                                      : text("Verlauf", "History"));
        });
        historyModel = new QStandardItemModel(q);
        bookmarkModel = new QStandardItemModel(q);
        recordingModel = new QStandardItemModel(q);
        historyModel->setHorizontalHeaderLabels(
            {text("Zeit", "Time"), text("Titel", "Track"), text("Sender", "Station")});
        bookmarkModel->setHorizontalHeaderLabels(
            {text("Gespeichert", "Saved"), text("Titel", "Track"), text("Sender", "Station")});
        recordingModel->setHorizontalHeaderLabels({text("Beginn", "Start"), text("Sender", "Station"),
                                                   text("Dauer", "Duration"), text("Größe", "Size")});
        auto *historyPage = new QWidget;
        auto *hl = new QVBoxLayout(historyPage);
        hl->setContentsMargins(10, 8, 10, 0);
        hl->setSpacing(6);
        auto *hf = new QHBoxLayout;
        historySearch = new QLineEdit;
        historySearch->setPlaceholderText(text("Titel / Künstler filtern", "Filter title / artist"));
        historyStation = new QComboBox;
        period = new QComboBox;
        period->addItems({text("Alle Zeiten", "All time"), text("Heute", "Today"), text("7 Tage", "7 days"),
                          text("30 Tage", "30 days"), text("Zeitraum …", "Custom dates …")});
        period->setObjectName("historyPeriod");
        historySearch->setFixedHeight(30);
        hl->addWidget(historySearch);
        historySearch->setMinimumWidth(120);
        historyStation->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
        historyStation->setMinimumContentsLength(12);
        hf->addWidget(historyStation, 1);
        hf->addWidget(period);
        hl->addLayout(hf);
        historyCount = new QLabel;
        historyCount->setObjectName("resultCount");
        hl->addWidget(historyCount);
        historyDates = new QWidget;
        auto *dateLayout = new QHBoxLayout(historyDates);
        dateLayout->setContentsMargins(0, 0, 0, 0);
        historyFrom = new QDateEdit(QDate::currentDate().addDays(-6));
        historyTo = new QDateEdit(QDate::currentDate());
        historyFrom->setObjectName("historyFrom");
        historyTo->setObjectName("historyTo");
        for (auto *date : {historyFrom, historyTo}) {
            date->setDisplayFormat("yyyy-MM-dd");
            date->setCalendarPopup(true);
        }
        dateLayout->addWidget(new QLabel(text("Von", "From")));
        dateLayout->addWidget(historyFrom, 1);
        dateLayout->addWidget(new QLabel(text("Bis", "Through")));
        dateLayout->addWidget(historyTo, 1);
        historyDates->hide();
        hl->addWidget(historyDates);
        QObject::connect(historyFrom, &QDateEdit::dateChanged, q, [this](QDate date) {
            if (historyTo->date() < date)
                historyTo->setDate(date);
            history();
        });
        QObject::connect(historyTo, &QDateEdit::dateChanged, q, [this](QDate date) {
            if (historyFrom->date() > date)
                historyFrom->setDate(date);
            history();
        });
        historyView = table(historyModel);
        historyView->setObjectName("history");
        historyView->setMinimumHeight(90);
        historyView->setSelectionMode(QAbstractItemView::ExtendedSelection);
        historyView->horizontalHeader()->hide();
        historyView->setColumnHidden(1, true);
        historyView->setColumnHidden(2, true);
        historyView->setFrameShape(QFrame::NoFrame);
        historyView->setAlternatingRowColors(false);
        historyDelegate = new Console::ItemDelegate(Console::ItemDelegate::Kind::Track, historyView);
        historyView->setItemDelegate(historyDelegate);
        hl->addWidget(historyView, 1);
        auto *ha = new QHBoxLayout;
        ha->setSpacing(4);
        ha->setContentsMargins(0, 4, 0, 5);
        actionButton(Symbol::Music, "Music", ha, [this] {
            for (const auto &track : store->history())
                if (track.id == selectedID(historyView))
                    QDesktopServices::openUrl(SongTools::appleMusicURL(track));
        });
        actionButton(Symbol::Spotify, "Spotify", ha, [this] {
            for (const auto &track : store->history())
                if (track.id == selectedID(historyView))
                    QDesktopServices::openUrl(SongTools::spotifyURL(track));
        });
        actionButton(Symbol::Lyrics, "Lyrics", ha, [this] {
            for (const auto &track : store->history())
                if (track.id == selectedID(historyView)) {
                    LyricsDialog dialog(track, q);
                    dialog.exec();
                }
        });
        auto *audioExport = actionButton(
            Symbol::Export, "Export", ha, [this] { exportSongs(historyView, false); }, "historyAudioExport");
        Q_UNUSED(audioExport);
        auto *historyActions = iconButton(
            Symbol::More, text("Weitere Titelaktionen", "More track actions"), ha,
            [this] { trackMenu(historyView, false, QCursor::pos()); }, "historyTrackActions");
        Q_UNUSED(historyActions);
        ha->addStretch();
        historyView->setContextMenuPolicy(Qt::CustomContextMenu);
        QObject::connect(historyView, &QWidget::customContextMenuRequested, q, [this](QPoint position) {
            trackMenu(historyView, false, historyView->viewport()->mapToGlobal(position));
        });
        auto *historyActionsBar = new QWidget;
        historyActionsBar->setObjectName("historyActionsBar");
        historyActionsBar->setLayout(ha);
        hl->addWidget(historyActionsBar);
        tabs->addTab(historyPage, text("Verlauf", "History"));
        auto *bp = new QWidget;
        auto *bl = new QVBoxLayout(bp);
        bl->setContentsMargins(10, 8, 10, 6);
        bookmarkSearch = new QLineEdit;
        bookmarkSearch->setObjectName("bookmarkSearch");
        bookmarkSearch->setPlaceholderText(text("Merkliste durchsuchen …", "Search bookmarks …"));
        bl->addWidget(bookmarkSearch);
        QObject::connect(bookmarkSearch, &QLineEdit::textChanged, q, [this] { bookmarks(); });
        bookmarkView = table(bookmarkModel);
        bookmarkView->setObjectName("bookmarks");
        bookmarkView->horizontalHeader()->hide();
        bookmarkView->setColumnHidden(1, true);
        bookmarkView->setColumnHidden(2, true);
        bookmarkView->setFrameShape(QFrame::NoFrame);
        bookmarkView->setAlternatingRowColors(false);
        bookmarkDelegate = new Console::ItemDelegate(Console::ItemDelegate::Kind::Track, bookmarkView);
        bookmarkView->setItemDelegate(bookmarkDelegate);
        bl->addWidget(bookmarkView, 1);
        auto *ba = new QHBoxLayout;
        button(text("Entfernen", "Remove"), ba, [this] {
            auto id = selectedID(bookmarkView);
            if (!id.isEmpty())
                store->removeBookmark(id);
        });
        button(text("Exportieren …", "Export …"), ba, [this] { exportBookmarks(); });
        button(text("Erkennungsdaten", "Recognition details"), ba, [this] { recognition(); });
        auto *bookmarkActions = button("...", ba, [this] { trackMenu(bookmarkView, true, QCursor::pos()); });
        bookmarkActions->setObjectName("bookmarkTrackActions");
        bookmarkActions->setToolTip(
            text("Titelaktionen: Musiklinks und Songtext", "Track actions: music links and lyrics"));
        bookmarkActions->setAccessibleName(bookmarkActions->toolTip());
        bookmarkView->setContextMenuPolicy(Qt::CustomContextMenu);
        QObject::connect(bookmarkView, &QWidget::customContextMenuRequested, q, [this](QPoint position) {
            trackMenu(bookmarkView, true, bookmarkView->viewport()->mapToGlobal(position));
        });
        bl->addLayout(ba);
        tabs->addTab(bp, text("Merkliste", "Bookmarks"));
        auto *rp = new QWidget;
        auto *rpl = new QVBoxLayout(rp);
        rpl->setContentsMargins(10, 8, 10, 6);
        recordingView = table(recordingModel);
        recordingView->setObjectName("recordings");
        recordingView->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Fixed);
        recordingView->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
        recordingView->horizontalHeader()->setSectionResizeMode(2, QHeaderView::Fixed);
        recordingView->horizontalHeader()->setSectionResizeMode(3, QHeaderView::Fixed);
        recordingView->setColumnWidth(2, 64);
        recordingView->setColumnWidth(3, 80);
        recordingView->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        rpl->addWidget(recordingView);
        auto *ra = new QHBoxLayout;
        button(text("Anhören", "Listen"), ra, [this] {
            auto id = selectedID(recordingView);
            if (!id.isEmpty() && allowPreview())
                media->previewRecording(id);
        });
        auto *stopPreview = button("■", ra, [this] { media->stopPreview(); });
        stopPreview->setToolTip(text("Vorschau stoppen", "Stop preview"));
        stopPreview->setAccessibleName(stopPreview->toolTip());
        button(text("Ausschnitt …", "Clip …"), ra, [this] { exportClip(); });
        button(text("Löschen …", "Delete …"), ra, [this] {
            auto id = selectedID(recordingView);
            for (auto r : media->recordings())
                if (r.id == id) {
                    if (r.active) {
                        error(text("Die aktive Aufnahme kann nicht gelöscht werden.",
                                   "The active recording cannot be deleted."));
                        return;
                    }
                    if (confirm(text("Diese Aufnahmedatei dauerhaft löschen? Der Verlauf bleibt erhalten.",
                                     "Permanently delete this recording file? History is kept.")))
                        media->removeRecording(id);
                }
        });
        rpl->addLayout(ra);
        tabs->addTab(rp, text("Aufnahmen", "Recordings"));
        rl->addWidget(tabs, 1);
        visual = new Visualizer;
        visual->setObjectName("mainVisualizer");
        columns = new Console::Columns(left, visual, right);
        columns->setObjectName("consoleBody");
        layout->addWidget(columns, 1);
        bufferControls = new QWidget;
        bufferControls->setObjectName("bufferControls");
        auto *bufferLayout = new QVBoxLayout(bufferControls);
        bufferLayout->setContentsMargins(12, 5, 12, 6);
        bufferLayout->setSpacing(5);
        auto *buffer = new QHBoxLayout;
        buffer->setSpacing(7);
        pause = button(text("Pause", "Pause"), buffer, [this] { media->togglePause(); });
        pause->setProperty("consoleButton", true);
        pause->setMinimumHeight(24);
        back15 = iconButton(
            Symbol::Back, text("15 Sekunden zurück", "Back 15 seconds"), buffer,
            [this] { media->seekDelay(std::min(state.bufferSeconds, state.delaySeconds + 15)); }, "back15");
        forward15 = iconButton(
            Symbol::Forward, text("15 Sekunden vor", "Forward 15 seconds"), buffer,
            [this] { media->seekDelay(std::max(0., state.delaySeconds - 15)); }, "forward15");
        buffer->addStretch();
        liveButton = button("Live", buffer, [this] { media->goLive(); });
        liveButton->setProperty("consoleButton", true);
        liveButton->setMinimumHeight(24);
        bufferLayout->addLayout(buffer);
        delay = new QSlider(Qt::Horizontal);
        delay->setRange(0, 0);
        delay->setAccessibleName(text("Puffer-Verzögerung", "Buffer delay"));
        bufferLayout->addWidget(delay);
        bufferStatus = new QLabel;
        bufferStatus->setObjectName("bufferStatus");
        bufferStatus->setTextFormat(Qt::PlainText);
        bufferLayout->addWidget(bufferStatus);
        layout->addWidget(bufferControls);
        bufferControls->hide();
        footerSurface = new SurfaceWidget(Surface::Footer);
        footerSurface->setObjectName("consoleFooter");
        auto *footer = new QHBoxLayout(footerSurface);
        footer->setContentsMargins(16, 9, 12, 9);
        footer->setSpacing(9);
        auto *playingWidget = new QWidget;
        auto *playingText = new QVBoxLayout(playingWidget);
        playingText->setSpacing(1);
        playingText->setContentsMargins(0, 0, 0, 0);
        playingText->setSizeConstraint(QLayout::SetFixedSize);
        artist = new QLabel(text("Kein Sender", "No station"));
        artist->setObjectName("stationCaption");
        now = new QLabel(text("Bereit für Musik", "Ready for music"));
        now->setObjectName("nowPlaying");
        for (auto *label : {artist, now}) {
            label->setTextFormat(Qt::PlainText);
            label->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::TextSelectableByKeyboard);
            label->setMinimumWidth(0);
        }
        now->setWordWrap(false);
        playingText->addWidget(artist);
        playingText->addWidget(now);
        status = new QLabel;
        status->setObjectName("playbackStatus");
        status->setTextFormat(Qt::PlainText);
        status->setWordWrap(false);
        status->hide();
        playingText->addWidget(status);
        auto *titleScroll = new QScrollArea;
        titleScroll->setObjectName("nowPlayingScroll");
        titleScroll->setFrameShape(QFrame::NoFrame);
        titleScroll->setMinimumWidth(0);
        titleScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        titleScroll->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        titleScroll->setWidget(playingWidget);
        titleScroll->setAlignment(Qt::AlignVCenter | Qt::AlignLeft);
        titleScroll->setAutoFillBackground(false);
        titleScroll->viewport()->setAutoFillBackground(false);
        titleScroll->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
        footer->addWidget(titleScroll, 1);
        iconButton(Symbol::Recognition, text("Musikerkennung unter Linux", "Music recognition on Linux"), footer,
                   [this] { recognition(); });
        bookmark = iconButton(Symbol::Heart,
                              text("Aktuellen Titel merken (Strg+D)", "Bookmark current track (Ctrl+D)"),
                              footer, [this] {
                                  if (!state.heardTrack.raw.isEmpty() || !state.heardTrack.title.isEmpty())
                                      store->bookmark(state.heardTrack);
                              });
        iconButton(Symbol::Bookmarks, text("Merkliste öffnen", "Open bookmarks"), footer, [this] {
            columns->showHistory(true);
            tabs->setCurrentIndex(1);
        });
        record = button(text("Aufnahme", "Record"), footer, [this] {
            if (!state.recordRequested &&
                !confirm(text(
                    "Aufnahme einschalten? Audio wird im Musikordner gespeichert. Unter 10 GiB freiem Speicher stoppt die Aufnahme automatisch.",
                    "Enable recording? Audio is saved in your Music folder. Recording stops automatically below 10 GiB of free space.")))
                return;
            const bool enabled = !state.recordRequested;
            media->setRecordingEnabled(enabled);
            auto settings = store->settings();
            settings["recordingEnabled"] = enabled;
            store->saveSettings(settings);
        });
        record->setObjectName("recordControl");
        record->setProperty("consoleButton", true);
        recordStatus = new QLabel(q);
        recordStatus->hide();
        iconButton(Symbol::Timer, text("Einschlaftimer", "Sleep timer"), footer, [this] {
            bool ok;
            const int minutes =
                QInputDialog::getInt(q, text("Einschlaftimer", "Sleep timer"),
                                     text("Minuten (0 = aus)", "Minutes (0 = off)"), 30, 0, 1440, 1, &ok);
            if (ok)
                media->setSleepTimer(minutes * 60);
        });
        runtime = new QLabel;
        runtime->setObjectName("runtime");
        footer->addWidget(runtime);
        volume = new QSlider(Qt::Horizontal);
        volume->setObjectName("volume");
        volume->setRange(0, 100);
        volume->setFixedWidth(96);
        volume->setAccessibleName(text("Lautstärke", "Volume"));
        footer->addWidget(volume);
        volumeKnob = new Console::VolumeKnob;
        volumeKnob->setObjectName("volumeKnob");
        volumeKnob->setAccessibleName(text("Lautstärke", "Volume"));
        footer->addWidget(volumeKnob);
        QObject::connect(volumeKnob, &QSlider::valueChanged, q,
                         [this](int value) { volume->setValue(value); });
        layout->addWidget(footerSurface);
        auto *file = q->menuBar()->addMenu(text("Bibliothek", "Library"));
        file->addAction(text("Importieren …", "Import …"), q, [this] { importLibrary(); });
        file->addAction(text("Genrelisten …", "Genre collections …"), q, [this] { genreLists(); });
        file->addAction(text("Exportieren …", "Export …"), q, [this] {
            auto path = QFileDialog::getSaveFileName(q, text("Bibliothek exportieren", "Export library"),
                                                     "mucke-library.json", "JSON (*.json)");
            if (!path.isEmpty())
                store->exportLibrary(path);
        });
        file->addAction(text("Gruppen …", "Groups …"), q, [this] { groupsDialog(); });
        file->addAction(text("Musikerkennung unter Linux", "Music recognition on Linux"), q,
                        [this] { recognition(); });
        file->addAction(text("Aufnahmeordner öffnen", "Open recording folder"), q, [this] {
            QDesktopServices::openUrl(QUrl::fromLocalFile(media->recordingsDirectory()));
        });
        auto *help = q->menuBar()->addMenu(text("Hilfe", "Help"));
        help->addAction(text("Über Mucke, Baby!", "About Mucke, Baby!"), q, [this] {
            QMessageBox::about(
                q, text("Über Mucke, Baby!", "About Mucke, Baby!"),
                QString("Mucke, Baby! %1\n\n").arg(MUCKE_VERSION) +
                    text(
                        "Natives Internetradio mit Qt 6 und libVLC.\nEigener Quellcode unter MIT-Lizenz.",
                        "Native internet radio with Qt 6 and libVLC.\nProject source code is licensed under MIT."));
        });
        help->addAction(text("Quellcode und Lizenzen", "Source code and licenses"), q, [] {
            QDesktopServices::openUrl(
                QUrl("https://github.com/DanielMuellerIR/mucke_baby/blob/master/THIRD-PARTY.md"));
        });
        help->addSeparator();
        help->addAction(text("Impressum", "Legal notice"), q,
                        [] { QDesktopServices::openUrl(QUrl("https://dm0.de/impressum.html")); });
        help->addAction(text("Datenschutz", "Privacy"), q,
                        [] { QDesktopServices::openUrl(QUrl("https://dm0.de/datenschutz.html")); });
        mainMenu->addMenu(file);
        mainMenu->addMenu(help);
        q->menuBar()->hide();
        q->statusBar()->hide();
        QObject::connect(search, &QLineEdit::textChanged, q, [this] { stations(); });
        QObject::connect(group, qOverload<int>(&QComboBox::currentIndexChanged), q, [this] {
            if (!updating)
                stations();
        });
        QObject::connect(favorites, &QCheckBox::toggled, q, [this] { stations(); });
        QObject::connect(stationView, &QTableView::clicked, q, [this](QModelIndex index) {
            togglePlayback(index.siblingAtColumn(0).data(Qt::UserRole).toString());
        });
        QObject::connect(volume, &QSlider::valueChanged, q, [this](int n) {
            if (!updating)
                media->setVolume(n);
        });
        QObject::connect(delay, &QSlider::sliderReleased, q, [this] { media->seekDelay(delay->value()); });
        QObject::connect(themes, qOverload<int>(&QComboBox::currentIndexChanged), q, [this](int n) {
            if (n >= 0 && !updating) {
                applyTheme(themeIDs[n]);
                auto settings = store->settings();
                settings["selectedTheme"] = theme;
                store->saveSettings(settings);
            }
        });
        QObject::connect(historySearch, &QLineEdit::textChanged, q, [this] { history(); });
        QObject::connect(historyStation, qOverload<int>(&QComboBox::currentIndexChanged), q, [this] {
            if (!updating)
                history();
        });
        QObject::connect(period, qOverload<int>(&QComboBox::currentIndexChanged), q, [this](int index) {
            historyDates->setVisible(index == 4);
            history();
        });
        QObject::connect(store, &LibraryStore::libraryChanged, q, [this] { library(); });
        QObject::connect(store, &LibraryStore::historyChanged, q, [this] { history(); });
        QObject::connect(store, &LibraryStore::bookmarksChanged, q, [this] { bookmarks(); });
        QObject::connect(media, &MediaEngine::snapshotChanged, q,
                         [this](PlaybackSnapshot s) { snapshot(s); });
        QObject::connect(media, &MediaEngine::recordingsChanged, q, [this] { recordings(); });
        QObject::connect(
            media, &MediaEngine::visualization, q, [this](QVector<float> w, QVector<float> s, float r) {
                if (state.state != PlaybackState::Playing || !animation.isActive())
                    return;
                auto *canvas =
                    fullVisual && fullVisual->isVisible() && !full->isMinimized() ? fullVisual : visual;
                canvas->wave = w;
                canvas->spectrum = s;
                canvas->rms = r;
                framePending = true;
            });
        QObject::connect(media, &MediaEngine::error, q, [this](QString e) { error(e); });
        QObject::connect(store, &LibraryStore::error, q, [this](QString e) { error(e); });
        auto shortcut = [this](QString key, std::function<void()> fn) {
            auto *s = new QShortcut(QKeySequence(key), q);
            QObject::connect(s, &QShortcut::activated, q, fn);
        };
        auto *space = new QShortcut(QKeySequence(Qt::Key_Space), q);
        QObject::connect(space, &QShortcut::activated, q, [this] {
            auto *focus = QApplication::focusWidget();
            if (focus == stationView || (focus && stationView->isAncestorOf(focus)))
                togglePlayback(selectedID(stationView));
            else
                play->click();
        });
        auto allowSpace = [space](QWidget *focus) {
            space->setEnabled(!qobject_cast<QLineEdit *>(focus) && !qobject_cast<QAbstractSpinBox *>(focus) &&
                              !qobject_cast<QComboBox *>(focus) && !qobject_cast<QAbstractButton *>(focus));
        };
        QObject::connect(qApp, &QApplication::focusChanged, space,
                         [allowSpace](QWidget *, QWidget *focus) { allowSpace(focus); });
        allowSpace(QApplication::focusWidget());
        for (auto key : {Qt::Key_Return, Qt::Key_Enter}) {
            auto *activateStation = new QShortcut(QKeySequence(key), stationView);
            activateStation->setContext(Qt::WidgetWithChildrenShortcut);
            QObject::connect(activateStation, &QShortcut::activated, q,
                             [this] { togglePlayback(selectedID(stationView)); });
        }
        noticeTimer.setSingleShot(true);
        QObject::connect(&noticeTimer, &QTimer::timeout, q, [this] {
            notice.clear();
            snapshot(state);
        });
        runtimeTimer.setInterval(1000);
        QObject::connect(&runtimeTimer, &QTimer::timeout, q, [this] {
            if (playbackClock.isValid())
                runtime->setText(duration(playbackClock.elapsed() / 1000.));
        });
        shortcut("Ctrl+D", [this] { bookmark->click(); });
        shortcut("Ctrl+F", [this] { search->setFocus(); });
        shortcut("Ctrl+Shift+T",
                 [this] { themes->setCurrentIndex((themeIDs.indexOf(theme) + 1) % themeIDs.size()); });
        shortcut("Ctrl+M", [this] { miniPlayer(); });
        shortcut("F11", [this] { fullScreen(); });
        for (int i = 0; i < 5; ++i)
            shortcut(QString("Alt+%1").arg(i + 1), [this, i] {
                auto ids = store->settings()["quickSlots"].toArray();
                if (i < ids.size()) {
                    auto s = store->station(ids[i].toString());
                    if (!s.id.isEmpty())
                        media->play(s);
                }
            });
        animation.setInterval(40);
        QObject::connect(&animation, &QTimer::timeout, q, [this] {
            if (!framePending)
                return;
            framePending = false;
            if (fullVisual && fullVisual->isVisible() && !full->isMinimized())
                fullVisual->update();
            else if (visual->isVisible())
                visual->update();
        });
        windowActivity = new ActivityObserver(q);
        windowActivity->changed = [this] {
            QTimer::singleShot(0, &callbacks, [this] {
                updateAnimation();
                configureTrackColumns(historyView);
                configureTrackColumns(bookmarkView);
            });
        };
        q->installEventFilter(windowActivity);
        library();
        history();
        bookmarks();
        recordings();
        applyTheme(store->settings()["selectedTheme"].toString("schlicht"));
        snapshot(media->snapshot());
    }
    void updateAnimation() {
        bool visible = (q->isVisible() && !q->isMinimized() && visual->isVisible()) ||
                       (full && full->isVisible() && !full->isMinimized());
        bool active = visible && state.state == PlaybackState::Playing;
        if (active != visualizationActive) {
            visualizationActive = active;
            media->setVisualizationActive(active);
        }
        if (active && !animation.isActive())
            animation.start();
        else if (!active) {
            animation.stop();
            framePending = false;
            visual->wave.clear();
            visual->spectrum.clear();
            visual->rms = 0;
            if (fullVisual) {
                fullVisual->wave.clear();
                fullVisual->spectrum.clear();
                fullVisual->rms = 0;
            }
            visual->update();
            if (fullVisual)
                fullVisual->update();
        }
    }
    ~Impl() {
        animation.stop();
        // Sichtbarkeitsereignisse des Fensters treten auch nach dem Impl-Destruktor auf.
        if (windowActivity) {
            q->removeEventFilter(windowActivity);
            delete windowActivity;
        }
        if (fullActivity) {
            full->removeEventFilter(fullActivity);
            delete fullActivity;
        }
        media->setVisualizationActive(false);
        delete mini;
        delete full;
    }
    void error(QString e) {
        notice = e;
        noticeTimer.start(15000);
        status->setText(e);
        status->show();
    }
    bool confirm(QString question) {
        return QMessageBox::question(q, text("Bitte bestätigen", "Please confirm"), question,
                                     QMessageBox::Yes | QMessageBox::No, QMessageBox::No) == QMessageBox::Yes;
    }
    bool allowPreview() {
        return state.state == PlaybackState::Stopped || state.previewActive ||
               confirm(text("Vorschau beendet die aktuelle Live-Wiedergabe. Fortfahren?",
                            "Preview ends current live playback. Continue?"));
    }
    void playSelected() {
        auto s = store->station(selectedID(stationView));
        if (s.id.isEmpty()) {
            if (stationModel->rowCount()) {
                stationView->selectRow(0);
                s = store->station(selectedID(stationView));
            }
        }
        if (!s.id.isEmpty() && s.enabled)
            media->play(s);
    }
    void library() {
        QString gid = group->currentData().toString(), sid = historyStation->currentData().toString();
        updating = true;
        group->clear();
        group->addItem(text("Alle Sender", "All stations"), "");
        for (auto g : store->groups())
            group->addItem(g.name, g.id);
        group->setCurrentIndex(std::max(0, group->findData(gid)));
        historyStation->clear();
        historyStation->addItem(text("Alle Sender", "All stations"), "");
        for (auto s : store->stations())
            historyStation->addItem(s.name, s.id);
        historyStation->setCurrentIndex(std::max(0, historyStation->findData(sid)));
        updating = false;
        refreshMiniStations();
        stations();
        history();
    }
    void stations() {
        QString id = selectedID(stationView);
        stationModel->removeRows(0, stationModel->rowCount());
        QStringList allowed;
        bool filter = !group->currentData().toString().isEmpty();
        for (auto g : store->groups())
            if (g.id == group->currentData().toString())
                allowed = g.stationIDs;
        for (auto s : store->stations()) {
            if (filter && !allowed.contains(s.id))
                continue;
            if (favorites->isChecked() && !s.favorite)
                continue;
            if (!s.name.contains(search->text(), Qt::CaseInsensitive) &&
                !s.url.contains(search->text(), Qt::CaseInsensitive))
                continue;
            row(stationModel,
                {s.name + (s.enabled ? QString() : text(" (deaktiviert)", " (disabled)")),
                 s.favorite ? "★" : ""},
                s.id);
            auto *item = stationModel->item(stationModel->rowCount() - 1);
            item->setToolTip(s.url);
            item->setData(s.favorite, Console::FavoriteRole);
            const bool active = s.id == state.stationID;
            item->setData(active && state.state != PlaybackState::Stopped, Console::ActiveRole);
            item->setData(active ? trackName(state.heardTrack) : QString(), Console::SubtitleRole);
            if (!s.enabled)
                item->setForeground(colors(theme).muted);
            if (s.id == id)
                stationView->selectRow(stationModel->rowCount() - 1);
        }
        stationView->resizeRowsToContents();
        stationCount->setText(text("%1 von %2 Sendern", "%1 of %2 stations")
                                  .arg(stationModel->rowCount())
                                  .arg(store->stations().size()));
    }
    void configureTrackColumns(QTableView *view) {
        view->setColumnHidden(1, true);
        view->setColumnHidden(2, true);
        view->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
        view->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        view->resizeRowsToContents();
    }
    void history() {
        historyModel->removeRows(0, historyModel->rowCount());
        auto list = store->history();
        for (auto it = list.cbegin(); it != list.cend(); ++it) {
            auto t = *it;
            auto date = t.heardAt.isValid() ? t.heardAt : t.receivedAt;
            const int preset = period->currentIndex();
            const QDate first =
                preset == 4 ? historyFrom->date() : HistoryFilter::presetStart(preset, QDate::currentDate());
            const QDate last = preset == 4 ? historyTo->date() : QDate::currentDate();
            if (preset && !HistoryFilter::overlaps(t, first, last, QDateTime::currentDateTimeUtc()))
                continue;
            if (!historyStation->currentData().toString().isEmpty() &&
                t.stationID != historyStation->currentData().toString())
                continue;
            if (!(trackName(t) + t.station).contains(historySearch->text(), Qt::CaseInsensitive))
                continue;
            const QString end = t.endedAt.isValid() ? t.endedAt.toLocalTime().toString("HH:mm:ss") : "…";
            row(historyModel,
                {date.toLocalTime().toString("yyyy-MM-dd · HH:mm:ss") + " – " + end, trackName(t), t.station},
                t.id);
            historyModel->item(historyModel->rowCount() - 1)
                ->setData(t.id == state.heardTrack.id, Console::ActiveRole);
        }
        historyCount->setText(
            text("%1 von %2 Titeln", "%1 of %2 tracks").arg(historyModel->rowCount()).arg(list.size()));
        configureTrackColumns(historyView);
    }
    void bookmarks() {
        bookmarkModel->removeRows(0, bookmarkModel->rowCount());
        auto list = store->bookmarks();
        for (auto it = list.crbegin(); it != list.crend(); ++it) {
            if (!(trackName(*it) + " " + it->station).contains(bookmarkSearch->text(), Qt::CaseInsensitive))
                continue;
            row(bookmarkModel,
                {it->savedAt.toLocalTime().toString("yyyy-MM-dd HH:mm"), trackName(*it), it->station},
                it->id);
        }
        configureTrackColumns(bookmarkView);
    }
    void recordings() {
        recordingModel->removeRows(0, recordingModel->rowCount());
        for (auto r : media->recordings())
            row(recordingModel,
                {r.start.toLocalTime().toString("yyyy-MM-dd HH:mm"),
                 r.station + (r.active ? text(" ● aktiv", " ● active") : ""),
                 duration(r.start.secsTo(r.end.isValid() ? r.end : QDateTime::currentDateTimeUtc())),
                 QString::number(r.bytes / 1048576., 'f', 1) + " MiB"},
                r.id);
        recordingView->resizeColumnToContents(0);
    }
    void snapshot(PlaybackSnapshot s) {
        const bool trackChanged = state.stationID != s.stationID || state.heardTrack.id != s.heardTrack.id ||
                                  state.heardTrack.raw != s.heardTrack.raw || state.state != s.state;
        if (clockStation != s.stationID || s.state == PlaybackState::Stopped || s.state == PlaybackState::Error) {
            playbackClock.invalidate(); runtimeTimer.stop(); clockStation = s.stationID;
        }
        if (s.state == PlaybackState::Playing && !playbackClock.isValid()) {
            playbackClock.start(); runtimeTimer.start();
        }
        state = s;
        if (trackChanged) {
            for (int i = 0; i < stationModel->rowCount(); ++i) {
                auto *item = stationModel->item(i);
                const bool current = item->data(Qt::UserRole).toString() == s.stationID;
                item->setData(current && s.state != PlaybackState::Stopped, Console::ActiveRole);
                item->setData(current ? trackName(s.heardTrack) : QString(), Console::SubtitleRole);
            }
            stationView->resizeRowsToContents();
            for (int i = 0; i < historyModel->rowCount(); ++i)
                historyModel->item(i)->setData(historyModel->item(i)->data(Qt::UserRole).toString() ==
                                                   s.heardTrack.id,
                                               Console::ActiveRole);
        }
        updateAnimation();
        updating = true;
        volume->setValue(s.volume);
        {
            QSignalBlocker block(volumeKnob);
            volumeKnob->setValue(s.volume);
            volumeKnob->update();
        }
        delay->setMaximum(int(s.bufferSeconds));
        if (!delay->isSliderDown())
            delay->setValue(int(s.delaySeconds));
        updating = false;
        bool playing = s.state == PlaybackState::Playing || s.state == PlaybackState::Buffering ||
                       s.state == PlaybackState::Resolving || s.state == PlaybackState::Paused;
        play->setText(playing ? text("Stopp", "Stop") : text("Abspielen", "Play"));
        play->setIcon(Console::icon(playing ? Symbol::Stop : Symbol::Play,
                                    theme == "stack" ? QColor("#1A1203") : colors(theme).accent, 12));
        pause->setEnabled(s.timeshiftAvailable || (s.previewActive && (s.state == PlaybackState::Playing ||
                                                                       s.state == PlaybackState::Paused)));
        pause->setText(s.timeshiftPaused || s.state == PlaybackState::Paused ? text("Fortsetzen", "Resume")
                                                                             : text("Pause", "Pause"));
        record->setText(s.recordActive      ? text("Aufnahme läuft", "Recording")
                        : s.recordRequested ? text("Aufnahme wartet", "Waiting")
                                            : text("Aufnahme", "Record"));
        record->setIcon(
            Console::icon(Symbol::Record, s.recordRequested ? QColor("#E0241B") : colors(theme).muted, 14));
        record->setToolTip(s.recordStatus + "\n" +
                           (s.recordRequested ? text("Aufnahme ausschalten", "Disable recording")
                                              : text("Aufnahme einschalten", "Enable recording")));
        now->setText(
            trackName(s.heardTrack).isEmpty()
                ? (s.stationName.isEmpty() ? text("Bereit für Musik", "Ready for music") : s.stationName)
                : trackName(s.heardTrack));
        now->setToolTip(now->text());
        artist->setText(s.stationName.isEmpty() ? text("Kein Sender", "No station") : s.stationName);
        runtime->setText(playbackClock.isValid() ? duration(playbackClock.elapsed() / 1000.) : QString());
        QStringList states = {text("Gestoppt", "Stopped"),
                              text("Sender wird aufgelöst …", "Resolving station …"),
                              text("Verbindung / Puffer …", "Connecting / buffering …"),
                              text("Wiedergabe", "Playing"),
                              text("Pausiert", "Paused"),
                              text("Fehler", "Error")};
        const bool recordingWaiting = s.recordRequested && !s.recordActive && !s.recordStatus.isEmpty();
        QString playbackStatus =
            !notice.isEmpty() ? notice
            : s.error.isEmpty()
                ? states[int(s.state)] + (s.previewActive ? text(" · Vorschau", " · Preview") : "") +
                      (s.sleepRemaining ? text(" · Timer ", " · Timer ") + duration(s.sleepRemaining) : "")
                : s.error;
        if (recordingWaiting)
            playbackStatus += " · " + s.recordStatus;
        status->setText(playbackStatus);
        status->setToolTip(playbackStatus);
        status->setVisible(!notice.isEmpty() || !s.error.isEmpty() || s.sleepRemaining > 0 ||
                           recordingWaiting || s.state == PlaybackState::Resolving ||
                           s.state == PlaybackState::Buffering);
        const bool buffered = s.timeshiftEnabled || s.timeshiftAvailable;
        bufferControls->setVisible(buffered || s.previewActive);
        for (auto *control : QList<QWidget *>{back15, forward15, liveButton, delay, bufferStatus})
            control->setVisible(buffered);
        liveButton->setEnabled(s.timeshiftEnabled || s.timeshiftAvailable);
        recordStatus->setText(s.recordStatus);
        bufferStatus->setText(text("Puffer ", "Buffer ") + duration(s.bufferSeconds) +
                              text(" · Verzögerung ", " · Delay ") + duration(s.delaySeconds));
        delay->setEnabled(s.timeshiftAvailable);
        back15->setEnabled(s.timeshiftAvailable && s.delaySeconds < s.bufferSeconds);
        forward15->setEnabled(s.timeshiftAvailable && s.delaySeconds > 0);
        if (miniTitle)
            miniTitle->setText(now->text());
        if (miniPlay) {
            miniPlay->setText(play->text());
            miniPlay->setIcon(play->icon());
            miniPause->setText(pause->text());
            miniPause->setEnabled(pause->isEnabled());
            miniRecord->setText(record->text());
            miniRecord->setIcon(record->icon());
            miniRecord->setToolTip(record->toolTip());
            miniBufferControls->setVisible(buffered || s.previewActive);
            for (auto *control : QList<QWidget *>{miniBack, miniForward, miniDelay, miniLive, miniBuffer})
                control->setVisible(buffered);
            miniStatus->setText(status->text());
            miniBuffer->setText(bufferStatus->text());
            miniDelay->setEnabled(s.timeshiftAvailable);
            miniBack->setEnabled(back15->isEnabled());
            miniForward->setEnabled(forward15->isEnabled());
            miniLive->setEnabled(s.timeshiftEnabled || s.timeshiftAvailable);
            QSignalBlocker sliderBlock(miniDelay), stationBlock(miniStations);
            miniDelay->setMaximum(int(s.bufferSeconds));
            if (!miniDelay->isSliderDown())
                miniDelay->setValue(int(s.delaySeconds));
            miniStations->setCurrentIndex(std::max(0, miniStations->findData(s.stationID)));
        }
    }
    void applyTheme(QString id) {
        if (!themeIDs.contains(id))
            id = "schlicht";
        theme = id;
        auto c = colors(id);
        QPixmap icon(24, 24);
        icon.fill(Qt::transparent);
        {
            QPainter painter(&icon);
            painter.setRenderHint(QPainter::Antialiasing);
            painter.setPen(QPen(c.fg, 1.8));
            painter.drawRect(QRectF(4, 5, 16, 14));
            painter.drawLine(QPointF(4, 8), QPointF(20, 8));
        }
        fullScreenButton->setIcon(QIcon(icon));
        visual->theme = id;
        if (fullVisual)
            fullVisual->theme = id;
        if (fullThemes) {
            QSignalBlocker block(fullThemes);
            fullThemes->setCurrentIndex(themeIDs.indexOf(id));
        }
        const QString input = id == "retro"      ? "#302B22"
                              : id == "schlicht" ? (c.panel.lightness() < 128 ? "#2B2B2B" : "#EDEDED")
                                                 : c.bg.name();
        QString css =
            QString(
                "QMainWindow,QDialog{background:%1;color:%4;} QWidget{color:%4;font-family:'%7';font-size:12px;} "
                "QLabel{background:transparent;} QWidget#shell{background:%8;} QScrollArea#nowPlayingScroll,QScrollArea#nowPlayingScroll>QWidget>QWidget{background:transparent;border:none;} "
                "QWidget#historyActionsBar{background:%2;border-top:1px solid %8;} "
                "QTableView{background:transparent;border:none;outline:0;selection-background-color:%3;} "
                "QTableView::item{border:none;} QTabWidget::pane{border:none;background:transparent;} "
                "QTabWidget>QWidget{background:transparent;} "
                "QLineEdit,QComboBox,QSpinBox,QDoubleSpinBox,QDateEdit,QListWidget,QPlainTextEdit{background:%9;color:%4;border:1px solid transparent;border-radius:5px;padding:5px;selection-background-color:%6;} "
                "QComboBox::drop-down{border:0;width:16px;background:transparent;} QComboBox::down-arrow{width:8px;height:8px;} "
                "QWidget#stationPanel QComboBox,QWidget#historyPanel QComboBox{background:transparent;padding:2px 4px;} "
                "QWidget#stationPanel QCheckBox::indicator{width:0;height:0;} QWidget#stationPanel QCheckBox{color:%5;} QWidget#stationPanel QCheckBox:checked{color:%6;} "
                "QLineEdit:focus,QComboBox:focus,QSpinBox:focus,QDoubleSpinBox:focus,QDateEdit:focus{border-color:%6;} "
                "QPushButton,QToolButton{background:%2;color:%4;border:1px solid %8;border-radius:5px;padding:5px 8px;} "
                "QPushButton:hover,QToolButton:hover{background:%9;border-color:%5;} QPushButton:pressed{background:%3;} QPushButton:disabled{color:%5;} "
                "QPushButton[consoleButton=\"true\"]{background:transparent;border:0;border-radius:4px;padding:0 3px;} "
                "QPushButton[consoleButton=\"true\"]:hover{background:%9;} QPushButton::menu-indicator{image:none;width:0;} "
                "QHeaderView::section{background:%2;color:%5;border:none;padding:7px;text-align:left;} "
                "QMenu{background:%2;color:%4;border:1px solid %8;padding:5px;} QMenu::item{padding:6px 16px;} QMenu::item:selected{background:%9;} "
                "QSlider::groove:horizontal{height:4px;background:%8;border-radius:2px;} "
                "QSlider::handle:horizontal{width:18px;height:18px;margin:-7px 0;background:%4;border-radius:9px;} "
                "QSlider::sub-page:horizontal{background:%6;border-radius:2px;} "
                "QScrollBar:vertical{width:7px;background:transparent;} QScrollBar::handle:vertical{background:%8;border-radius:3px;min-height:24px;} "
                "QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical{height:0;} "
                "QPushButton#mainPlay{font-size:11px;font-weight:600;color:%6;} "
                "QLabel#brand{font-family:'%10';font-size:18px;font-weight:700;} QLabel#version{font-size:10px;color:%5;} "
                "QLabel#sectionHeading{font-size:11px;font-weight:600;color:%5;} QLabel#historyHeading{font-size:12px;font-weight:600;color:%5;} "
                "QLabel#resultCount{font-size:10px;color:%5;} QLabel#stationCaption{font-size:11px;color:%5;} "
                "QLabel#nowPlaying{font-size:16px;font-weight:600;} QLabel#runtime,QLabel#bufferStatus{font-size:11px;color:%5;} "
                "QLabel#playbackStatus{font-size:10px;color:%5;} QLabel#miniTitle{font-size:16px;font-weight:600;} QLabel#miniStatus,QLabel#miniVolumeValue{font-size:11px;color:%5;} QComboBox#miniStations{background:transparent;font-weight:600;} QLabel#fullTitle{font-size:24px;} "
                "QCheckBox{spacing:4px;}")
                .arg(c.bg.name(), c.panel.name(), c.stage.name(), c.fg.name(), c.muted.name(),
                     c.accent.name(), c.font, c.divider.name(), input, c.titleFont);
        if (id == "fanzine")
            css +=
                "QWidget{font-size:13px;} QLabel#brand{font-size:22px;} QLabel#nowPlaying{font-size:18px;} QLabel#sectionHeading,QLabel#historyHeading{font-size:12px;}";
        if (id == "stack")
            css += "QWidget#consoleHeader QLabel,QWidget#consoleHeader QPushButton{color:#1A1203;}";
        if (id == "retro")
            css +=
                "QWidget#historyActionsBar{background:#EEE3C7;} QWidget#historyPanel QLabel{color:#5C4A38;} QWidget#historyPanel QLineEdit,QWidget#historyPanel QComboBox{background:#E3D7BC;color:#2A2018;}";
        for (auto *surface : {headerSurface, stationSurface, historySurface, footerSurface}) {
            surface->theme = id;
            surface->update();
        }
        headerSurface->setFixedHeight(id == "stack" || id == "retro" ? 52 : 38);
        footerSurface->setMinimumHeight(66);
        stationDelegate->theme = id;
        historyDelegate->theme = id;
        bookmarkDelegate->theme = id;
        for (auto it = iconButtons.cbegin(); it != iconButtons.cend(); ++it) {
            const QColor ink = headerSurface->isAncestorOf(it.key()) && id == "stack"    ? QColor("#2A1E05")
                               : historySurface->isAncestorOf(it.key()) && id == "retro" ? QColor("#6B5432")
                                                                                         : c.muted;
            it.key()->setIcon(Console::icon(it.value(), ink));
            if (auto *action = dynamic_cast<Console::ActionButton *>(it.key())) {
                action->ink = ink;
                action->update();
            }
        }
        const bool knob = id == "stack" || id == "retro";
        volume->setVisible(!knob);
        volumeKnob->setVisible(knob);
        volumeKnob->tint = c.accent;
        volumeKnob->update();
        historyHeading->setText(tabs->currentIndex() == 1   ? text("Merkliste", "Bookmarks")
                                : tabs->currentIndex() == 2 ? text("Aufnahmen", "Recordings")
                                : id == "midi"              ? "PLAYBACK_HISTORY"
                                                            : text("Verlauf", "History"));
        columns->setStyleSheet(QString("Mucke--Console--Columns{background:%1;}").arg(c.divider.name()));
        q->setStyleSheet(css);
        if (tabs->currentIndex() == 0 && id != "schlicht")
            historyHeading->setText(historyHeading->text().toUpper());
        for (auto *edit : {search, historySearch}) {
            if (edit->actions().isEmpty())
                edit->addAction(Console::icon(Symbol::Search, c.muted, 14), QLineEdit::LeadingPosition);
            else
                edit->actions().first()->setIcon(Console::icon(Symbol::Search, c.muted, 14));
        }
        for (auto *label :
             {q->findChild<QLabel *>("brand"), q->findChild<QLabel *>("sectionHeading"), historyHeading}) {
            auto titleFont = label->font();
            titleFont.setLetterSpacing(QFont::AbsoluteSpacing, id == "acid" ? 1 : id == "midi" ? .6 : 0);
            label->setFont(titleFont);
        }
        configureTrackColumns(historyView);
        configureTrackColumns(bookmarkView);
        recordingView->setColumnWidth(
            0, std::max(128, recordingView->fontMetrics().horizontalAdvance("2026-10-28 13:00") + 14));
        if (mini) {
            mini->setStyleSheet(css);
            miniSurface->theme = id;
            miniSurface->update();
        }
        if (full)
            full->setStyleSheet(css);
        updating = true;
        themes->setCurrentIndex(themeIDs.indexOf(id));
        updating = false;
        stationView->viewport()->update();
        historyView->viewport()->update();
        bookmarkView->viewport()->update();
        visual->update();
    }
    void editStation(QString id) {
        Station station = store->station(id);
        bool fresh = id.isEmpty();
        if (fresh)
            station.id = newID();
        QDialog dialog(q);
        dialog.setObjectName("stationEditor");
        dialog.setWindowTitle(fresh ? text("Sender hinzufügen", "Add station")
                                    : text("Sender bearbeiten", "Edit station"));
        dialog.resize(510, 460);
        auto *layout = new QVBoxLayout(&dialog);
        auto *form = new QFormLayout;
        auto *name = new QLineEdit(station.name), *url = new QLineEdit(station.url),
             *rbid = new QLineEdit(station.radioBrowserID);
        name->setObjectName("stationName");
        url->setObjectName("stationURL");
        rbid->setObjectName("stationRadioBrowserID");
        auto *enabled = new QCheckBox;
        enabled->setObjectName("stationEnabled");
        enabled->setChecked(station.enabled);
        auto *favorite = new QCheckBox;
        favorite->setObjectName("stationFavorite");
        favorite->setChecked(station.favorite);
        form->addRow(text("Name", "Name"), name);
        form->addRow(text("Stream-URL", "Stream URL"), url);
        form->addRow("Radio Browser ID", rbid);
        form->addRow(text("Aktiviert", "Enabled"), enabled);
        form->addRow(text("Favorit", "Favorite"), favorite);
        auto *position = new QSpinBox;
        position->setObjectName("stationPosition");
        position->setRange(1, std::max(1, int(store->stations().size()) + (fresh ? 1 : 0)));
        int pos = 1;
        for (auto s : store->stations()) {
            if (s.id == id)
                break;
            ++pos;
        }
        position->setValue(fresh ? position->maximum() : pos);
        form->addRow(text("Position", "Position"), position);
        layout->addLayout(form);
        auto *groups = new QListWidget;
        for (auto g : store->groups()) {
            auto *item = new QListWidgetItem(g.name, groups);
            item->setData(Qt::UserRole, g.id);
            item->setFlags(item->flags() | Qt::ItemIsUserCheckable);
            item->setCheckState(g.stationIDs.contains(station.id) ? Qt::Checked : Qt::Unchecked);
        }
        layout->addWidget(new QLabel(text("Gruppen", "Groups")));
        layout->addWidget(groups);
        auto *repair = new QPushButton(text("URL im Katalog prüfen", "Check URL in catalog"));
        repair->setEnabled(!rbid->text().isEmpty());
        layout->addWidget(repair);
        QObject::connect(rbid, &QLineEdit::textChanged, &dialog,
                         [repair](QString s) { repair->setEnabled(!s.trimmed().isEmpty()); });
        QObject::connect(repair, &QPushButton::clicked, &dialog, [this, rbid, repair] {
            repair->setEnabled(false);
            catalog->lookupStation(rbid->text().trimmed());
        });
        QObject::connect(catalog, &CatalogService::repairCandidate, &dialog,
                         [&, url, rbid, repair](QString found, QString proposed) {
                             repair->setEnabled(true);
                             if (found == rbid->text().trimmed() &&
                                 QMessageBox::question(&dialog, text("URL ersetzen?", "Replace URL?"),
                                                       proposed) == QMessageBox::Yes)
                                 url->setText(proposed);
                         });
        QObject::connect(catalog, &CatalogService::error, &dialog,
                         [repair](QString) { repair->setEnabled(true); });
        auto *buttons = dialogButtons(QDialogButtonBox::Save | QDialogButtonBox::Cancel);
        if (!fresh) {
            auto *remove = buttons->addButton(text("Sender löschen …", "Delete station …"),
                                              QDialogButtonBox::DestructiveRole);
            QObject::connect(remove, &QPushButton::clicked, &dialog, [&, id] {
                if (confirm(text("Sender löschen? Verlauf und Aufnahmen bleiben erhalten.",
                                 "Delete station? History and recordings are kept.")) &&
                    store->removeStation(id))
                    dialog.reject();
            });
        }
        layout->addWidget(buttons);
        QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
        QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, [&, this] {
            QString reason;
            if (name->text().trimmed().isEmpty() || !validStreamURL(url->text().trimmed(), &reason)) {
                QMessageBox::warning(&dialog, text("Eingabe prüfen", "Check input"),
                                     reason.isEmpty() ? text("Name und gültige HTTP(S)-URL angeben.",
                                                             "Enter a name and valid HTTP(S) URL.")
                                                      : reason);
                return;
            }
            station.name = name->text().trimmed();
            station.url = url->text().trimmed();
            station.radioBrowserID = rbid->text().trimmed();
            station.enabled = enabled->isChecked();
            station.favorite = favorite->isChecked();
            if (!store->saveStation(station))
                return;
            QStringList order;
            for (auto s : store->stations())
                if (s.id != station.id)
                    order.append(s.id);
            order.insert(std::min(position->value() - 1, int(order.size())), station.id);
            store->setStationOrder(order);
            for (auto g : store->groups()) {
                for (int i = 0; i < groups->count(); ++i)
                    if (groups->item(i)->data(Qt::UserRole).toString() == g.id) {
                        g.stationIDs.removeAll(station.id);
                        if (groups->item(i)->checkState() == Qt::Checked)
                            g.stationIDs.append(station.id);
                        store->saveGroup(g);
                    }
            }
            dialog.accept();
        });
        dialog.exec();
    }
    void groupsDialog() {
        QDialog dialog(q);
        dialog.setObjectName("groupsDialog");
        dialog.setWindowTitle(text("Gruppen verwalten", "Manage groups"));
        dialog.resize(460, 400);
        auto *layout = new QVBoxLayout(&dialog);
        auto *list = new QListWidget;
        layout->addWidget(list);
        auto reload = [&] {
            list->clear();
            for (auto g : store->groups()) {
                auto *i = new QListWidgetItem(g.name, list);
                i->setData(Qt::UserRole, g.id);
            }
        };
        reload();
        auto *actions = new QHBoxLayout;
        button(text("Neu", "New"), actions, [&, this] {
            bool ok;
            auto name = QInputDialog::getText(&dialog, text("Gruppe", "Group"), text("Name", "Name"),
                                              QLineEdit::Normal, {}, &ok);
            if (ok && !name.trimmed().isEmpty()) {
                store->saveGroup({newID(), name.trimmed(), {}});
                reload();
            }
        });
        button(text("Umbenennen", "Rename"), actions, [&, this] {
            if (!list->currentItem())
                return;
            QString id = list->currentItem()->data(Qt::UserRole).toString();
            for (auto g : store->groups())
                if (g.id == id) {
                    bool ok;
                    auto name = QInputDialog::getText(&dialog, text("Gruppe", "Group"), text("Name", "Name"),
                                                      QLineEdit::Normal, g.name, &ok);
                    if (ok && !name.trimmed().isEmpty()) {
                        g.name = name.trimmed();
                        store->saveGroup(g);
                        reload();
                    }
                    break;
                }
        });
        button(text("Löschen", "Delete"), actions, [&, this] {
            if (list->currentItem() && confirm(text("Gruppe löschen? Sender bleiben erhalten.",
                                                    "Delete group? Stations are kept."))) {
                store->removeGroup(list->currentItem()->data(Qt::UserRole).toString());
                reload();
            }
        });
        layout->addLayout(actions);
        auto *close = dialogButtons(QDialogButtonBox::Close);
        layout->addWidget(close);
        QObject::connect(close, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
        dialog.exec();
    }
    void catalogDialog() {
        QDialog dialog(q);
        dialog.setObjectName("catalogDialog");
        dialog.setWindowTitle(text("Senderkatalog · Radio Browser", "Station catalog · Radio Browser"));
        dialog.resize(860, 620);
        auto *layout = new QVBoxLayout(&dialog);
        auto *form = new QGridLayout;
        QStringList labels = {text("Name", "Name"), text("Land (Code)", "Country (code)"),
                              text("Sprache", "Language"), text("Tag", "Tag"), "Codec"};
        QVector<QLineEdit *> inputs;
        for (int i = 0; i < labels.size(); ++i) {
            auto *edit = new QLineEdit;
            edit->setPlaceholderText(labels[i]);
            edit->setAccessibleName(labels[i]);
            inputs.append(edit);
            form->addWidget(edit, i / 3, i % 3);
        }
        auto *bitrate = new QSpinBox;
        bitrate->setRange(0, 10000);
        bitrate->setSuffix(" kbps");
        bitrate->setSpecialValueText(text("Jede Bitrate", "Any bitrate"));
        form->addWidget(bitrate, 1, 2);
        auto *order = new QComboBox;
        order->addItem(text("Beliebtheit", "Popularity"), "clickcount");
        order->addItem(text("Name", "Name"), "name");
        order->addItem(text("Bitrate", "Bitrate"), "bitrate");
        form->addWidget(order, 2, 0);
        layout->addLayout(form);
        auto *model = new QStandardItemModel(&dialog);
        model->setHorizontalHeaderLabels({text("Sender", "Station"), text("Stream", "Stream")});
        auto *view = table(model);
        layout->addWidget(view, 1);
        auto *info = new QLabel(text("Nach Sendern suchen. Vorschau ersetzt die Live-Wiedergabe.",
                                     "Search stations. Preview replaces live playback."));
        info->setWordWrap(true);
        layout->addWidget(info);
        QVector<Station> results;
        int page = 0;
        bool more = false;
        bool catalogPreviewStarted = false;
        auto search = [&, this](int next) {
            page = next;
            QJsonObject filters;
            QStringList keys = {"name", "countrycode", "language", "tag", "codec"};
            for (int i = 0; i < inputs.size(); ++i)
                if (!inputs[i]->text().trimmed().isEmpty())
                    filters[keys[i]] = inputs[i]->text().trimmed();
            filters["bitrateMin"] = bitrate->value();
            filters["order"] = order->currentData().toString();
            filters["reverse"] = order->currentData().toString() != "name";
            info->setText(text("Suche …", "Searching …"));
            catalog->search(filters, page);
        };
        auto *actions = new QHBoxLayout;
        button(text("Suchen", "Search"), actions, [&] { search(0); });
        auto *previous = button(text("Zurück", "Previous"), actions, [&] { search(std::max(0, page - 1)); });
        auto *next = button(text("Weiter", "Next"), actions, [&] {
            if (more)
                search(page + 1);
        });
        previous->setEnabled(false);
        next->setEnabled(false);
        actions->addStretch();
        button(text("Vorschau", "Preview"), actions, [&, this] {
            int r = view->currentIndex().row();
            if (r >= 0 && r < results.size() && allowPreview()) {
                media->previewStation(results[r]);
                catalogPreviewStarted = true;
            }
        });
        button(text("Hinzufügen", "Add"), actions, [&, this] {
            int r = view->currentIndex().row();
            if (r < 0 || r >= results.size())
                return;
            auto s = results[r];
            bool duplicate = false;
            for (auto existing : store->stations())
                if (normalizedStreamURL(existing.url) == normalizedStreamURL(s.url))
                    duplicate = true;
            if (duplicate) {
                info->setText(
                    text("Sender ist bereits in der Bibliothek.", "Station is already in your library."));
                return;
            }
            s.id = newID();
            if (store->saveStation(s))
                info->setText(text("Sender hinzugefügt.", "Station added."));
        });
        layout->addLayout(actions);
        QObject::connect(catalog, &CatalogService::results, &dialog,
                         [&](QVector<Station> found, bool hasMore, QDateTime cached) {
                             results = found;
                             more = hasMore;
                             model->removeRows(0, model->rowCount());
                             for (auto s : found)
                                 row(model, {s.name, s.url}, s.id);
                             previous->setEnabled(page > 0);
                             next->setEnabled(more);
                             info->setText(
                                 QString::number(found.size()) +
                                 text(" Sender · Seite ", " stations · page ") + QString::number(page + 1) +
                                 (cached.isValid() ? text(" · Cache: ", " · Cached: ") +
                                                         cached.toLocalTime().toString("yyyy-MM-dd HH:mm")
                                                   : ""));
                         });
        QObject::connect(catalog, &CatalogService::error, &dialog, [info](QString e) { info->setText(e); });
        dialog.exec();
        catalog->cancel();
        if (catalogPreviewStarted)
            media->stopPreview();
    }
    void genreLists() {
        QFile manifest(":/genre-lists/manifest.json");
        if (!manifest.open(QIODevice::ReadOnly)) {
            error(text("Genrelisten sind nicht verfügbar.", "Genre collections are unavailable."));
            return;
        }
        const auto entries = QJsonDocument::fromJson(manifest.read(1024 * 1024)).array();
        QDialog dialog(q);
        dialog.setObjectName("genreLists");
        dialog.setWindowTitle(text("Kuratierte Genrelisten", "Curated genre collections"));
        dialog.resize(480, 380);
        auto *layout = new QVBoxLayout(&dialog);
        auto *hint = new QLabel(text(
            "Öffentliche Senderlisten. Vor dem Import können neue Einträge und Konflikte geprüft werden.",
            "Public station collections. You can review new entries and conflicts before importing."));
        hint->setWordWrap(true);
        layout->addWidget(hint);
        auto *list = new QListWidget;
        list->setObjectName("genreCollections");
        layout->addWidget(list, 1);
        for (const auto &value : entries) {
            const auto entry = value.toObject();
            QString name = entry["name"].toString();
            if (entry["id"].toString() == "oerr")
                name = text("Öffentlich-rechtlich (DE)", "Public-service radio (DE)");
            auto *item = new QListWidgetItem(name, list);
            item->setData(Qt::UserRole, entry);
        }
        if (list->count())
            list->setCurrentRow(0);
        auto *buttons = dialogButtons(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
        buttons->button(QDialogButtonBox::Ok)->setText(text("Import prüfen …", "Review import …"));
        layout->addWidget(buttons);
        QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
        QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
        if (dialog.exec() != QDialog::Accepted || !list->currentItem())
            return;
        const auto entry = list->currentItem()->data(Qt::UserRole).toJsonObject();
        const QString filename = entry["file"].toString();
        if (!QRegularExpression("^[a-z0-9-]+\\.json$").match(filename).hasMatch())
            return;
        QFile source(":/genre-lists/" + filename);
        if (!source.open(QIODevice::ReadOnly)) {
            error(
                text("Die Genreliste konnte nicht geladen werden.", "Could not load the genre collection."));
            return;
        }
        const auto incoming = QJsonDocument::fromJson(source.read(1024 * 1024)).array();
        QJsonArray stations, ids;
        for (const auto &value : incoming) {
            auto station = value.toObject();
            const QString url = station["url"].toString();
            if (!validStreamURL(url))
                continue;
            QString id;
            for (const auto &existing : store->stations())
                if (normalizedStreamURL(existing.url) == normalizedStreamURL(url)) {
                    id = existing.id;
                    break;
                }
            if (id.isEmpty())
                id = newID();
            station["id"] = id;
            station["enabled"] = true;
            station["favorite"] = false;
            stations.append(station);
            ids.append(id);
        }
        QString groupID;
        const QString name = entry["name"].toString();
        for (const auto &group : store->groups())
            if (group.name == name)
                groupID = group.id;
        if (groupID.isEmpty())
            groupID = newID();
        QJsonObject exchange{
            {"format", "mucke-baby-library"},
            {"formatVersion", 1},
            {"exportedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
            {"stations", stations},
            {"groups", QJsonArray{QJsonObject{{"id", groupID}, {"name", name}, {"stationIDs", ids}}}},
            {"bookmarks", QJsonArray{}}};
        QTemporaryFile temporary;
        if (!temporary.open()) {
            error(text("Temporäre Importdatei konnte nicht angelegt werden.",
                       "Could not create temporary import file."));
            return;
        }
        temporary.write(QJsonDocument(exchange).toJson());
        temporary.flush();
        importLibrary(temporary.fileName());
    }
    void importLibrary(QString path = {}) {
        if (path.isEmpty())
            path = QFileDialog::getOpenFileName(q, text("Bibliothek importieren", "Import library"), {},
                                                "JSON (*.json)");
        if (path.isEmpty())
            return;
        auto preview = store->previewImport(path);
        auto items = preview["items"].toArray();
        if (items.isEmpty()) {
            store->discardImport(preview);
            error(text("Keine importierbaren Einträge gefunden.", "No importable entries found."));
            return;
        }
        QDialog dialog(q);
        dialog.setObjectName("importPreview");
        dialog.setWindowTitle(text("Import prüfen", "Review import"));
        dialog.resize(830, 540);
        auto *layout = new QVBoxLayout(&dialog);
        auto counts = preview["counts"].toObject();
        auto *label = new QLabel(QString("%1 %2 · %3 %4 · %5 %6")
                                     .arg(counts["new"].toInt())
                                     .arg(text("neu", "new"))
                                     .arg(counts["unchanged"].toInt())
                                     .arg(text("unverändert", "unchanged"))
                                     .arg(counts["conflict"].toInt())
                                     .arg(text("Konflikte", "conflicts")));
        layout->addWidget(label);
        auto *table = new QTableWidget(items.size(), 4);
        table->setHorizontalHeaderLabels({text("Typ / Status", "Type / status"), text("Lokal", "Local"),
                                          text("Import", "Incoming"), text("Übernehmen", "Choice")});
        table->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
        table->setEditTriggers(QAbstractItemView::DoubleClicked | QAbstractItemView::SelectedClicked |
                               QAbstractItemView::EditKeyPressed);
        table->setItemDelegateForColumn(3, new ImportChoiceDelegate(table));
        table->verticalHeader()->setSectionResizeMode(QHeaderView::Fixed);
        table->verticalHeader()->setDefaultSectionSize(100);
        const QHash<QString, QString> kinds = {{"station", text("Sender", "Station")},
                                               {"group", text("Gruppe", "Group")},
                                               {"bookmark", text("Merkeintrag", "Bookmark")}};
        const QHash<QString, QString> states = {{"new", text("Neu", "New")},
                                                {"unchanged", text("Unverändert", "Unchanged")},
                                                {"conflict", text("Konflikt", "Conflict")}};
        for (int i = 0; i < items.size(); ++i) {
            auto item = items[i].toObject();
            table->setItem(
                i, 0,
                new QTableWidgetItem(kinds.value(item["kind"].toString(), item["kind"].toString()) + " / " +
                                     states.value(item["status"].toString(), item["status"].toString())));
            table->setItem(i, 1, new QTableWidgetItem(item["local"].toObject()["text"].toString()));
            table->setItem(i, 2, new QTableWidgetItem(item["incoming"].toObject()["text"].toString()));
            for (int column = 0; column < 3; ++column)
                table->item(i, column)->setToolTip(table->item(i, column)->text());
            for (int column = 0; column < 3; ++column)
                table->item(i, column)->setFlags(table->item(i, column)->flags() & ~Qt::ItemIsEditable);
            const QString key = item["defaultChoice"].toString("incoming");
            auto *choice = new QTableWidgetItem(importChoiceCaption(key));
            choice->setData(ImportChoiceRole, key);
            choice->setData(ImportConflictRole, item["status"].toString() == "conflict");
            table->setItem(i, 3, choice);
        }
        layout->addWidget(table, 1);
        auto *buttons = dialogButtons(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
        layout->addWidget(buttons);
        QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
        QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
        if (dialog.exec() == QDialog::Accepted) {
            QJsonObject selected;
            for (int i = 0; i < items.size(); ++i)
                selected[items[i].toObject()["key"].toString()] =
                    table->item(i, 3)->data(ImportChoiceRole).toString();
            store->applyImport(preview, selected);
        }
        store->discardImport(preview);
    }
    void exportBookmarks() {
        QString filter;
        auto path = QFileDialog::getSaveFileName(q, text("Merkliste exportieren", "Export bookmarks"),
                                                 "mucke-bookmarks.csv", "CSV (*.csv);;Text (*.txt)", &filter);
        if (!path.isEmpty()) {
            QStringList visibleIDs;
            visibleIDs.reserve(bookmarkModel->rowCount());
            for (int row = 0; row < bookmarkModel->rowCount(); ++row)
                visibleIDs.append(bookmarkModel->item(row, 0)->data(Qt::UserRole).toString());
            store->exportBookmarks(path, filter.startsWith("CSV"), &visibleIDs);
        }
    }
    void exportSongs(QTableView *view, bool fromBookmarks) {
        const auto selected = view->selectionModel()->selectedRows();
        if (selected.isEmpty() || selected.size() > 100) {
            error(text("Bitte 1 bis 100 Titel auswählen.", "Select 1 to 100 tracks."));
            return;
        }
        const auto library = fromBookmarks ? store->bookmarks() : store->history();
        QHash<QString, Track> byID;
        for (const auto &track : library)
            byID.insert(track.id, track);
        auto rows = selected;
        std::sort(rows.begin(), rows.end(), [](const QModelIndex &a, const QModelIndex &b) { return a.row() < b.row(); });
        QVector<Track> tracks;
        for (const auto &index : rows) {
            const auto found = byID.constFind(index.data(Qt::UserRole).toString());
            if (found != byID.cend())
                tracks.append(found.value());
        }
        if (!tracks.isEmpty())
            showSongExportDialog(std::move(tracks), media, q);
    }
    void trackMenu(QTableView *view, bool fromBookmarks, QPoint position) {
        Track track;
        const auto candidates = fromBookmarks ? store->bookmarks() : store->history();
        for (const auto &candidate : candidates)
            if (candidate.id == selectedID(view))
                track = candidate;
        QMenu menu(q);
        if (!fromBookmarks) {
            auto *clear = menu.addAction(text("Verlauf löschen …", "Clear history …"), q, [this] {
                if (confirm(text("Gesamten Verlauf löschen? Aufnahmen und Merkliste bleiben erhalten.",
                                 "Clear all history? Recordings and bookmarks are kept.")))
                    store->clearHistory();
            });
            clear->setEnabled(!candidates.isEmpty());
            menu.addSeparator();
        }
        if (track.id.isEmpty()) {
            if (fromBookmarks)
                error(text("Zuerst einen Titel auswählen.", "Select a track first."));
            else
                menu.exec(position);
            return;
        }
        menu.addAction(text("Audio exportieren …", "Export audio …"), q,
                       [this, view, fromBookmarks] { exportSongs(view, fromBookmarks); });
        menu.addSeparator();
        menu.addAction(text("In Apple Music suchen", "Search Apple Music"), q,
                       [track] { QDesktopServices::openUrl(SongTools::appleMusicURL(track)); });
        menu.addAction(text("In Spotify suchen", "Search Spotify"), q,
                       [track] { QDesktopServices::openUrl(SongTools::spotifyURL(track)); });
        menu.addSeparator();
        menu.addAction(text("Songtext …", "Lyrics …"), q, [this, track] {
            LyricsDialog dialog(track, q);
            dialog.exec();
        });
        menu.exec(position);
    }
    void recognition() {
        QString details = text("ShazamKit steht unter Linux nicht zur Verfügung. Live-Erkennung ist hier "
                               "nicht verfügbar. Importierte Erkennungsdaten bleiben erhalten.",
                               "ShazamKit is not available on Linux. Live recognition is unavailable here. "
                               "Imported recognition data is retained.");
        for (auto t : store->bookmarks())
            if (t.id == selectedID(bookmarkView) && !t.recognition.is_null())
                details += "\n\n" + QString::fromStdString(t.recognition.dump(2));
        QMessageBox::information(q, text("Erkennung / Herkunft", "Recognition / provenance"), details);
    }
    void exportClip() {
        const QString id = selectedID(recordingView);
        Recording recording;
        for (const auto &candidate : media->recordings())
            if (candidate.id == id)
                recording = candidate;
        if (recording.id.isEmpty())
            return;
        QDialog dialog(q);
        dialog.setObjectName("exportClip");
        dialog.setWindowTitle(text("Aufnahmeausschnitt exportieren", "Export recording clip"));
        dialog.resize(510, 470);
        auto temporary = std::make_shared<QTemporaryDir>();
        if (!temporary->isValid()) {
            error(text("Temporärer Exportordner nicht verfügbar.", "Temporary export folder unavailable."));
            return;
        }
        auto *layout = new QVBoxLayout(&dialog);
        auto *form = new QFormLayout;
        auto spin = [&](double maximum, double value) {
            auto *s = new QDoubleSpinBox;
            s->setRange(0, maximum);
            s->setDecimals(1);
            s->setValue(value);
            s->setSuffix(" s");
            return s;
        };
        const double total = std::max<qint64>(
            0, recording.start.secsTo(recording.end.isValid() ? recording.end
                                                              : QDateTime::currentDateTimeUtc()));
        auto *start = spin(total, 0), *length = spin(total, std::min(total, 180.)), *fadeIn = spin(30, 0),
             *fadeOut = spin(30, 0);
        auto *title = new QLineEdit, *artistEdit = new QLineEdit, *album = new QLineEdit(recording.station);
        form->addRow(text("Start ab Aufnahmebeginn", "Start from recording beginning"), start);
        form->addRow(text("Dauer", "Duration"), length);
        form->addRow(text("Einblenden", "Fade in"), fadeIn);
        form->addRow(text("Ausblenden", "Fade out"), fadeOut);
        form->addRow(text("Titel", "Title"), title);
        form->addRow(text("Künstler", "Artist"), artistEdit);
        form->addRow(text("Album", "Album"), album);
        layout->addLayout(form);
        auto *hint = new QLabel(
            text("Ausschnitt als M4A (AAC) vorbereiten, anhören und dieselbe Datei speichern. Die Aufnahme "
                 "bleibt erhalten.",
                 "Prepare an M4A (AAC) clip, listen, and save the same file. The recording is kept."));
        hint->setWordWrap(true);
        layout->addWidget(hint);
        auto *progress = new QProgressBar;
        progress->setRange(0, 0);
        progress->hide();
        layout->addWidget(progress);
        auto *actions = new QHBoxLayout;
        layout->addLayout(actions);
        QString job, prepared;
        bool running = false, previewing = false;
        QThread *saveWorker = nullptr;
        auto saveCancelled = std::make_shared<std::atomic_bool>(false);
        auto *prepare = button(text("Vorbereiten", "Prepare"), actions, [] {});
        auto *listen = button(text("Anhören", "Listen"), actions, [] {});
        listen->setEnabled(false);
        auto *save = button(text("Speichern …", "Save …"), actions, [] {});
        save->setEnabled(false);
        auto *close = button(text("Schließen", "Close"), actions, [&] { dialog.reject(); });
        auto setSaving = [&](bool saving) {
            for (auto *field : {start, length, fadeIn, fadeOut})
                field->setEnabled(!saving);
            for (auto *field : {title, artistEdit, album})
                field->setEnabled(!saving);
            prepare->setEnabled(!saving);
            listen->setEnabled(!saving && !prepared.isEmpty());
            save->setEnabled(saving || !prepared.isEmpty());
            save->setText(saving ? text("Abbrechen", "Cancel") : text("Speichern …", "Save …"));
            progress->setVisible(saving);
        };
        auto invalidate = [&] {
            if (running) {
                media->cancelExport(job);
                running = false;
                job.clear();
                progress->hide();
                prepare->setEnabled(true);
            }
            if (previewing) {
                media->stopPreview();
                previewing = false;
            }
            prepared.clear();
            listen->setEnabled(false);
            save->setEnabled(false);
            hint->setText(text("Einstellungen geändert. Bitte erneut vorbereiten.",
                               "Settings changed. Please prepare again."));
        };
        for (auto *field : {start, length, fadeIn, fadeOut})
            QObject::connect(field, qOverload<double>(&QDoubleSpinBox::valueChanged), &dialog,
                             [&](double) { invalidate(); });
        for (auto *field : {title, artistEdit, album})
            QObject::connect(field, &QLineEdit::textChanged, &dialog, [&](QString) { invalidate(); });
        QObject::connect(prepare, &QPushButton::clicked, &dialog, [&] {
            if (length->value() <= 0 || start->value() + length->value() > total + .1 ||
                fadeIn->value() + fadeOut->value() > length->value()) {
                hint->setText(text("Ausschnitt und Blenden müssen innerhalb der Aufnahme liegen.",
                                   "The clip and fades must fit within the recording."));
                return;
            }
            invalidate();
            job = newID();
            running = true;
            prepare->setEnabled(false);
            progress->show();
            hint->setText(text("Ausschnitt wird vorbereitet …", "Preparing clip …"));
            media->exportClip(
                job, id, start->value(), length->value(), fadeIn->value(), fadeOut->value(),
                {{"title", title->text()}, {"artist", artistEdit->text()}, {"album", album->text()}},
                temporary->filePath(job + ".m4a"));
        });
        QObject::connect(
            media, &MediaEngine::exportFinished, &dialog,
            [&](QString finished, QString path, QString failure) {
                if (finished != job)
                    return;
                running = false;
                progress->hide();
                prepare->setEnabled(true);
                if (!failure.isEmpty()) {
                    hint->setText(failure);
                    return;
                }
                if (!QFileInfo(path).isFile()) {
                    hint->setText(text("Die Exportdatei fehlt.", "The exported file is missing."));
                    return;
                }
                prepared = path;
                listen->setEnabled(true);
                save->setEnabled(true);
                hint->setText(text("Vorbereitet. Vorschau und Speichern verwenden dieselben Audiodaten.",
                                   "Prepared. Preview and save use the same audio data."));
            });
        QObject::connect(listen, &QPushButton::clicked, &dialog, [&] {
            if (!prepared.isEmpty() && allowPreview()) {
                media->previewFile(prepared);
                previewing = true;
            }
        });
        QObject::connect(save, &QPushButton::clicked, &dialog, [&] {
            if (saveWorker) {
                saveCancelled->store(true);
                return;
            }
            if (prepared.isEmpty())
                return;
            QString destination = QFileDialog::getSaveFileName(
                &dialog, text("Ausschnitt speichern", "Save clip"), "mucke-clip.m4a", "M4A (*.m4a)", nullptr,
                QFileDialog::DontConfirmOverwrite);
            if (destination.isEmpty())
                return;
            if (!destination.endsWith(".m4a", Qt::CaseInsensitive))
                destination += ".m4a";
            const QString source = prepared;
            const QFileInfo target(destination);
            saveCancelled->store(false);
            auto result = std::make_shared<SongExportFile::PublishResult>();
            saveWorker = QThread::create([source, target, result, saveCancelled, temporary] {
                *result = SongExportFile::publishExact(source, target.absolutePath(),
                                                       target.completeBaseName(), *saveCancelled);
            });
            QObject::connect(saveWorker, &QThread::finished, &dialog, [&, result] {
                saveWorker = nullptr;
                setSaving(false);
                hint->setText(result->cancelled ? text("Speichern abgebrochen.", "Saving cancelled.")
                              : result->path.isEmpty()
                                  ? text("Speichern fehlgeschlagen: ", "Saving failed: ") + result->error
                                  : text("Gespeichert: ", "Saved: ") + result->path);
            });
            QObject::connect(saveWorker, &QThread::finished, saveWorker, &QObject::deleteLater);
            setSaving(true);
            hint->setText(text("Ausschnitt wird gespeichert …", "Saving clip …"));
            saveWorker->start();
        });
        dialog.exec();
        saveCancelled->store(true);
        if (running)
            media->cancelExport(job);
        if (previewing)
            media->stopPreview();
        Q_UNUSED(close);
    }
    void settings(int initialPage = 0) {
        auto original = store->settings();
        QDialog dialog(q);
        dialog.setObjectName("settingsDialog");
        dialog.setWindowTitle(text("Einstellungen", "Settings"));
        dialog.resize(620, 650);
        auto *layout = new QVBoxLayout(&dialog);
        auto *pages = new QTabWidget;
        layout->addWidget(pages);
        auto *general = new QWidget;
        auto *form = new QFormLayout(general);
        auto *language = new QComboBox;
        language->setObjectName("language");
        language->addItem(text("Systemsprache", "System language"), "system");
        language->addItem("Deutsch", "de");
        language->addItem("English", "en");
        language->setCurrentIndex(std::max(0, language->findData(original["language"].toString("system"))));
        form->addRow(text("Sprache (nach Neustart)", "Language (after restart)"), language);
        auto *autostart = new QComboBox;
        autostart->setObjectName("startupMode");
        autostart->addItem(text("Nicht abspielen", "Do not play"), "none");
        autostart->addItem(text("Letzten Sender spielen", "Play last station"), "last");
        autostart->addItem(text("Gewählten Sender spielen", "Play selected station"), "selected");
        autostart->setCurrentIndex(std::max(0, autostart->findData(original["autostart"].toString("none"))));
        form->addRow(text("Beim App-Start", "On app startup"), autostart);
        auto stationCombo = [this](QString id) {
            auto *combo = new QComboBox;
            combo->addItem(text("Nicht belegt", "Unassigned"), "");
            for (auto s : store->stations())
                if (s.enabled)
                    combo->addItem(s.name, s.id);
            combo->setCurrentIndex(std::max(0, combo->findData(id)));
            return combo;
        };
        auto *selected = stationCombo(original["selectedStationID"].toString());
        form->addRow(text("Startsender", "Startup station"), selected);
        auto *tray = new QCheckBox(
            text("Beim Schließen im Infobereich weiterlaufen", "Keep running in tray when closing"));
        tray->setObjectName("closeToTray");
        tray->setChecked(original["closeToTray"].toBool(false));
        form->addRow(tray);
        auto *timeshift =
            new QCheckBox(text("Temporären Audiopuffer aktivieren", "Enable temporary audio buffer"));
        timeshift->setObjectName("timeshiftEnabled");
        timeshift->setChecked(state.timeshiftEnabled);
        form->addRow(timeshift);
        auto *bufferHint = new QLabel(bufferExplanation());
        bufferHint->setWordWrap(true);
        form->addRow(bufferHint);
        pages->addTab(general, text("Allgemein", "General"));
        auto *quick = new QWidget;
        auto *qf = new QFormLayout(quick);
        QVector<QComboBox *> quickSlotControls;
        auto quickIDs = original["quickSlots"].toArray();
        for (int i = 0; i < 5; ++i) {
            auto *c = stationCombo(i < quickIDs.size() ? quickIDs[i].toString() : QString());
            quickSlotControls.append(c);
            qf->addRow(QString("Alt+%1").arg(i + 1), c);
        }
        pages->addTab(quick, text("Schnelltasten", "Quick slots"));
        auto *audio = new QWidget;
        auto *af = new QVBoxLayout(audio);
        auto *eqEnabled = new QCheckBox(text("Equalizer aktivieren", "Enable equalizer"));
        eqEnabled->setChecked(original["equalizerEnabled"].toBool());
        eqEnabled->setObjectName("equalizerEnabled");
        af->addWidget(eqEnabled);
        auto *preset = new QComboBox;
        preset->setObjectName("equalizerPreset");
        preset->addItem(text("Eigene Einstellung", "Custom"), -1);
        preset->addItem(text("Neutral", "Flat"), 0);
        preset->addItem(text("Mehr Bass", "More bass"), 1);
        preset->addItem(text("Sprachbetonung", "Speech"), 2);
        preset->addItem(text("Sanfte Höhen", "Soft highs"), 3);
        af->addWidget(preset);
        auto *bandsLayout = new QHBoxLayout;
        QVector<QSlider *> bands;
        auto values = original["equalizerBands"].toArray();
        QStringList frequencies = {"31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"};
        for (int i = 0; i < 10; ++i) {
            auto *column = new QVBoxLayout;
            auto *db = new QLabel;
            db->setAlignment(Qt::AlignCenter);
            auto *slider = new QSlider(Qt::Vertical);
            slider->setRange(-12, 12);
            slider->setValue(i < values.size() ? qRound(values[i].toDouble()) : 0);
            slider->setMinimumHeight(150);
            slider->setAccessibleName(frequencies[i] + " Hz");
            db->setText(QString::number(slider->value()) + " dB");
            QObject::connect(slider, &QSlider::valueChanged, &dialog,
                             [db](int n) { db->setText(QString::number(n) + " dB"); });
            column->addWidget(db);
            column->addWidget(slider, 1, Qt::AlignHCenter);
            auto *label = new QLabel(frequencies[i]);
            label->setAlignment(Qt::AlignCenter);
            column->addWidget(label);
            bandsLayout->addLayout(column);
            bands.append(slider);
        }
        af->addLayout(bandsLayout);
        auto *audioForm = new QFormLayout;
        auto *preamp = new QDoubleSpinBox;
        preamp->setObjectName("equalizerPreamp");
        preamp->setRange(-12, 0);
        preamp->setSuffix(" dB");
        preamp->setValue(original["equalizerPreamp"].toDouble());
        audioForm->addRow(text("Vorverstärkung", "Preamp"), preamp);
        auto *headroom = new QLabel;
        headroom->setObjectName("equalizerHeadroom");
        headroom->setWordWrap(true);
        audioForm->addRow(headroom);
        auto updateHeadroom = [&] {
            double boost = 0;
            for (auto *band : bands)
                boost = std::max(boost, double(band->value()));
            if (!eqEnabled->isChecked()) {
                headroom->setText(text("Equalizer ausgeschaltet; neutraler Audiopfad.",
                                       "Equalizer off; neutral audio path."));
                return;
            }
            headroom->setText(text("Wirksame Vorverstärkung: ", "Effective preamp: ") +
                              QString::number(std::min(preamp->value(), -boost), 'f', 1) + " dB" +
                              text(" · Pegelreserve.", " · Headroom."));
        };
        bool applyingPreset = false;
        QObject::connect(preamp, qOverload<double>(&QDoubleSpinBox::valueChanged), &dialog,
                         [&](double) { updateHeadroom(); });
        for (auto *band : bands)
            QObject::connect(band, &QSlider::valueChanged, &dialog, [&](int) {
                if (!applyingPreset) {
                    QSignalBlocker block(preset);
                    preset->setCurrentIndex(0);
                }
                updateHeadroom();
            });
        QObject::connect(preset, qOverload<int>(&QComboBox::currentIndexChanged), &dialog, [&](int index) {
            const QVector<QVector<int>> values = {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
                                                  {6, 5, 3, 1, 0, 0, 0, 0, 0, 0},
                                                  {-6, -4, -2, 0, 2, 3, 3, 1, -2, -4},
                                                  {0, 0, 0, 0, 0, 0, -1, -3, -5, -6}};
            int id = preset->itemData(index).toInt();
            if (id < 0 || id >= values.size())
                return;
            applyingPreset = true;
            preamp->setValue(0);
            for (int i = 0; i < bands.size(); ++i)
                bands[i]->setValue(values[id][i]);
            applyingPreset = false;
            updateHeadroom();
        });
        auto updateEqualizerEnabled = [&] {
            preset->setEnabled(eqEnabled->isChecked());
            preamp->setEnabled(eqEnabled->isChecked());
            for (auto *band : bands)
                band->setEnabled(eqEnabled->isChecked());
            updateHeadroom();
        };
        QObject::connect(eqEnabled, &QCheckBox::toggled, &dialog, [&](bool) { updateEqualizerEnabled(); });
        updateEqualizerEnabled();
        auto *gainStation = stationCombo(state.stationID);
        auto *gain = new QDoubleSpinBox;
        gain->setObjectName("stationGain");
        gain->setRange(-12, 12);
        gain->setSuffix(" dB");
        QJsonObject gains = original["stationGains"].toObject();
        auto gainUpdate = [&] {
            QSignalBlocker blocker(gain);
            gain->setValue(gains[gainStation->currentData().toString()].toDouble());
        };
        gainUpdate();
        QObject::connect(gainStation, qOverload<int>(&QComboBox::currentIndexChanged), &dialog,
                         [&] { gainUpdate(); });
        QObject::connect(gain, qOverload<double>(&QDoubleSpinBox::valueChanged), &dialog, [&](double n) {
            if (!gainStation->currentData().toString().isEmpty())
                gains[gainStation->currentData().toString()] = n;
        });
        audioForm->addRow(text("Senderpegel", "Station gain"), gainStation);
        audioForm->addRow(text("Anpassung", "Adjustment"), gain);
        af->addLayout(audioForm);
        auto *reset = new QPushButton(text("Equalizer neutral", "Reset equalizer"));
        af->addWidget(reset);
        QObject::connect(reset, &QPushButton::clicked, &dialog, [&] {
            preset->setCurrentIndex(preset->findData(0));
            preamp->setValue(0);
        });
        af->addStretch();
        pages->addTab(audio, "Audio");
        pages->setCurrentIndex(initialPage);
        auto *buttons = dialogButtons(QDialogButtonBox::Save | QDialogButtonBox::Cancel);
        layout->addWidget(buttons);
        QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
        QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, [&, this] {
            if (timeshift->isChecked() && !state.timeshiftEnabled &&
                !confirm(
                    text("Temporären Audiopuffer aktivieren?\n\n", "Enable temporary audio buffer?\n\n") +
                    bufferExplanation()))
                return;
            auto settings = store->settings();
            settings["language"] = language->currentData().toString();
            settings["autostart"] = autostart->currentData().toString();
            settings["selectedStationID"] = selected->currentData().toString();
            settings["closeToTray"] = tray->isChecked();
            settings["timeshiftEnabled"] = timeshift->isChecked();
            QJsonArray ids, eq;
            QVector<double> eqValues;
            for (auto *s : quickSlotControls) {
                const QString id = s->currentData().toString();
                ids.append(id.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(id));
            }
            for (auto *b : bands) {
                eq.append(b->value());
                eqValues.append(b->value());
            }
            settings["quickSlots"] = ids;
            settings["equalizerEnabled"] = eqEnabled->isChecked();
            settings["equalizerBands"] = eq;
            settings["equalizerPreamp"] = preamp->value();
            settings["stationGains"] = gains;
            if (!store->saveSettings(settings))
                return;
            media->setTimeshiftEnabled(timeshift->isChecked());
            media->setEqualizer(eqEnabled->isChecked(), eqValues, preamp->value());
            for (auto it = gains.begin(); it != gains.end(); ++it)
                media->setStationGain(it.key(), it.value().toDouble());
            dialog.accept();
        });
        dialog.exec();
    }
    QString bufferExplanation() const {
        return text(
            "Der temporäre Audiopuffer hält höchstens 5 Minuten und 32 MiB. Unter 10 GiB freiem "
            "Speicher wird er gestoppt. Alte Segmente werden automatisch entfernt; Senderwechsel, "
            "Ausschalten und Beenden löschen den Puffer. Läuft eine Pause aus dem verfügbaren "
            "Puffer, stoppt die verzögerte Wiedergabe. Mit „Live“ fortsetzen. Aufnahmen bleiben davon "
            "getrennt.",
            "The temporary audio buffer keeps at most 5 minutes and 32 MiB. It stops below 10 GiB of "
            "free space. Old segments are removed automatically; changing station, disabling the "
            "buffer, and quitting clear it. If a pause outlasts the available buffer, delayed playback "
            "stops. Choose Live to resume. Recordings are separate.");
    }
    void togglePlayback(QString stationID = {}) {
        const bool current = stationID.isEmpty() || stationID == state.stationID;
        if (current && (state.state == PlaybackState::Playing || state.state == PlaybackState::Buffering ||
                        state.state == PlaybackState::Resolving || state.state == PlaybackState::Paused)) {
            media->stop();
            return;
        }
        const auto station = store->station(stationID.isEmpty() ? state.stationID : stationID);
        if (!station.id.isEmpty() && station.enabled)
            media->play(station);
        else
            playSelected();
    }
    void refreshMiniStations() {
        if (!miniStations)
            return;
        QSignalBlocker blocker(miniStations);
        const QString selected = miniStations->currentData().toString();
        miniStations->clear();
        miniStations->addItem(text("Sender auswählen …", "Choose station …"), QString());
        for (const auto &station : store->stations())
            if (station.enabled)
                miniStations->addItem(station.name, station.id);
        miniStations->setCurrentIndex(
            std::max(0, miniStations->findData(state.stationID.isEmpty() ? selected : state.stationID)));
    }
    void miniPlayer() {
        if (!mini) {
            mini = new QDialog(q, Qt::Window | (store->settings()["miniAlwaysOnTop"].toBool(false)
                                                    ? Qt::WindowStaysOnTopHint
                                                    : Qt::WindowFlags()));
            mini->setObjectName("miniPlayer");
            mini->setWindowTitle("Mucke, Baby! · Mini");
            mini->resize(420, 240);
            mini->setMinimumWidth(360);
            auto *outer = new QVBoxLayout(mini);
            outer->setContentsMargins(0, 0, 0, 0);
            miniSurface = new SurfaceWidget(Surface::Window);
            miniSurface->theme = theme;
            outer->addWidget(miniSurface);
            auto *layout = new QVBoxLayout(miniSurface);
            layout->setContentsMargins(16, 16, 16, 16);
            layout->setSpacing(12);
            auto *header = new QHBoxLayout;
            header->setSpacing(8);
            layout->addLayout(header);
            miniStations = new QComboBox;
            miniStations->setObjectName("miniStations");
            miniStations->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
            miniStations->setMinimumContentsLength(12);
            miniStations->setAccessibleName(text("Sender", "Station"));
            header->addWidget(miniStations, 1);
            refreshMiniStations();
            QObject::connect(miniStations, qOverload<int>(&QComboBox::activated), mini, [this](int) {
                const auto station = store->station(miniStations->currentData().toString());
                if (!station.id.isEmpty() && station.enabled)
                    media->play(station);
            });
            iconButton(Symbol::Audio, text("Audioeinstellungen", "Audio settings"), header,
                       [this] { settings(2); });
            auto *onTop = iconButton(
                Symbol::Pin, text("Immer im Vordergrund", "Always on top"), header, [] {}, "miniAlwaysOnTop");
            onTop->setCheckable(true);
            onTop->setChecked(store->settings()["miniAlwaysOnTop"].toBool(false));
            QObject::connect(onTop, &QPushButton::toggled, mini, [this](bool enabled) {
                auto settings = store->settings();
                settings["miniAlwaysOnTop"] = enabled;
                if (!store->saveSettings(settings))
                    return;
                const bool visible = mini->isVisible();
                mini->setWindowFlag(Qt::WindowStaysOnTopHint, enabled);
                if (visible)
                    mini->show();
            });
            iconButton(Symbol::Mini, text("Hauptfenster anzeigen", "Show main window"), header, [this] {
                q->showNormal();
                q->raise();
                mini->hide();
            });
            miniTitle = new QLabel;
            miniTitle->setTextFormat(Qt::PlainText);
            miniTitle->setObjectName("miniTitle");
            miniTitle->setWordWrap(true);
            miniTitle->setMinimumHeight(40);
            miniTitle->setMinimumWidth(0);
            miniTitle->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::TextSelectableByKeyboard);
            layout->addWidget(miniTitle);
            miniStatus = new QLabel;
            miniStatus->setTextFormat(Qt::PlainText);
            miniStatus->setObjectName("miniStatus");
            miniStatus->setWordWrap(true);
            layout->addWidget(miniStatus);
            auto *transport = new QHBoxLayout;
            transport->setSpacing(10);
            layout->addLayout(transport);
            miniPlay = button(play->text(), transport,
                              [this] { togglePlayback(miniStations->currentData().toString()); });
            miniPlay->setObjectName("miniPlay");
            miniPlay->setProperty("consoleButton", true);
            miniPlay->setMinimumWidth(65);
            auto *vol = new QSlider(Qt::Horizontal);
            vol->setObjectName("miniVolume");
            vol->setRange(0, 100);
            vol->setValue(state.volume);
            vol->setAccessibleName(text("Lautstärke", "Volume"));
            transport->addWidget(vol, 1);
            auto *percentage = new QLabel(QString::number(state.volume) + " %");
            percentage->setObjectName("miniVolumeValue");
            transport->addWidget(percentage);
            QObject::connect(vol, &QSlider::valueChanged, mini,
                             [this](int value) { media->setVolume(value); });
            QObject::connect(media, &MediaEngine::snapshotChanged, mini,
                             [vol, percentage](PlaybackSnapshot state) {
                                 QSignalBlocker block(vol);
                                 vol->setValue(state.volume);
                                 percentage->setText(QString::number(state.volume) + " %");
                             });
            iconButton(Symbol::Heart, bookmark->toolTip(), transport, [this] { bookmark->click(); });
            miniBufferControls = new QWidget;
            auto *bufferLayout = new QVBoxLayout(miniBufferControls);
            bufferLayout->setContentsMargins(0, 0, 0, 0);
            bufferLayout->setSpacing(5);
            layout->addWidget(miniBufferControls);
            auto *bufferRow = new QHBoxLayout;
            bufferRow->setSpacing(6);
            bufferLayout->addLayout(bufferRow);
            miniPause = button(pause->text(), bufferRow, [this] { media->togglePause(); });
            miniPause->setObjectName("miniPause");
            miniPause->setProperty("consoleButton", true);
            miniBack = iconButton(
                Symbol::Back, text("15 Sekunden zurück", "Back 15 seconds"), bufferRow,
                [this] { back15->click(); }, "miniBack15");
            miniForward = iconButton(
                Symbol::Forward, text("15 Sekunden vor", "Forward 15 seconds"), bufferRow,
                [this] { forward15->click(); }, "miniForward15");
            bufferRow->addStretch();
            miniLive = button("Live", bufferRow, [this] { media->goLive(); });
            miniLive->setObjectName("miniLive");
            miniLive->setProperty("consoleButton", true);
            miniDelay = new QSlider(Qt::Horizontal);
            miniDelay->setObjectName("miniDelay");
            miniDelay->setRange(0, 0);
            miniDelay->setAccessibleName(text("Puffer-Verzögerung", "Buffer delay"));
            bufferLayout->addWidget(miniDelay);
            QObject::connect(miniDelay, &QSlider::sliderReleased, mini,
                             [this] { media->seekDelay(miniDelay->value()); });
            miniBuffer = new QLabel;
            miniBuffer->setTextFormat(Qt::PlainText);
            miniBuffer->setWordWrap(true);
            miniBuffer->setObjectName("bufferStatus");
            bufferLayout->addWidget(miniBuffer);
            auto *recordingRow = new QHBoxLayout;
            layout->addLayout(recordingRow);
            miniRecord = button(record->text(), recordingRow, [this] { record->click(); });
            miniRecord->setObjectName("miniRecord");
            miniRecord->setProperty("consoleButton", true);
            recordingRow->addStretch();
            iconButton(Symbol::Recognition, text("Musikerkennung unter Linux", "Music recognition on Linux"),
                       recordingRow, [this] { recognition(); });
            mini->setStyleSheet(q->styleSheet());
            applyTheme(theme);
        }
        snapshot(state);
        mini->show();
        mini->raise();
    }
    void fullScreen() {
        if (!full) {
            full = new QDialog(q, Qt::Window);
            fullActivity = new ActivityObserver(full);
            fullActivity->changed = [this] {
                QTimer::singleShot(0, &callbacks, [this] { updateAnimation(); });
            };
            full->installEventFilter(fullActivity);
            full->setObjectName("fullscreenVisualizer");
            full->setWindowTitle("Mucke, Baby! · Visualizer");
            auto *layout = new QVBoxLayout(full);
            auto *label = new QLabel;
            label->setObjectName("fullTitle");
            label->setTextFormat(Qt::PlainText);
            auto f = label->font();
            f.setPointSize(24);
            label->setFont(f);
            label->setAlignment(Qt::AlignCenter);
            label->setWordWrap(true);
            layout->addWidget(label);
            fullVisual = new Visualizer;
            fullVisual->theme = theme;
            layout->addWidget(fullVisual, 1);
            auto *actions = new QHBoxLayout;
            auto *themePicker = new QComboBox;
            fullThemes = themePicker;
            themePicker->addItems(themeNames);
            themePicker->setCurrentIndex(themeIDs.indexOf(theme));
            actions->addWidget(themePicker);
            QObject::connect(themePicker, qOverload<int>(&QComboBox::currentIndexChanged), full,
                             [this](int n) { themes->setCurrentIndex(n); });
            button(text("Wiedergabe / Stop", "Play / stop"), actions, [this] { play->click(); });
            button(text("Schließen (Esc)", "Close (Esc)"), actions, [this] { full->hide(); });
            layout->addLayout(actions);
            QObject::connect(media, &MediaEngine::snapshotChanged, full, [label](PlaybackSnapshot s) {
                label->setText(trackName(s.heardTrack) + "\n" + s.stationName);
            });
            label->setText(now->text() + "\n" + state.stationName);
            full->setStyleSheet(q->styleSheet());
        }
        fullVisual->theme = theme;
        full->showFullScreen();
    }
    void capture(QString directory) {
        QDir().mkpath(directory);
        const QString previous = theme;
        const QSize previousSize = q->size();
        const QPalette previousPalette = QApplication::palette();
        const int explicitWidth = qEnvironmentVariableIntValue("MUCKE_SHOT_W");
        const QList<int> widths = explicitWidth > 0 ? QList<int>{explicitWidth} : QList<int>{940, 660};
        // Screenshots zeigen ausschließlich flüchtige Beispieldaten, niemals persönliche Sender oder Titel.
        for (auto *model : {stationModel, historyModel, bookmarkModel, recordingModel})
            model->removeRows(0, model->rowCount());
        const QStringList exampleStations = {
            "Radio Example · Jazz", "Electronic Sessions",  "Classical Radio", "Independent FM",
            "World Radio",          "Nightshift",           "Example News",    "Ambient Waves",
            "Acoustic Sessions",    "Radio Example · Soul", "Community Radio", "Instrumental FM",
            "Example Music",        "Concert Radio",        "Late Night Jazz"};
        for (int i = 0; i < exampleStations.size(); ++i) {
            row(stationModel, {exampleStations[i], i == 0 ? "★" : ""}, QString("fixture-%1").arg(i));
            auto *item = stationModel->item(i);
            item->setData(i == 0, Console::FavoriteRole);
            item->setData(i == 0, Console::ActiveRole);
            if (i == 0)
                item->setData("Example Artist – Afternoon Session", Console::SubtitleRole);
        }
        const QStringList titles = {"Example Artist – Afternoon Session",
                                    "The Ensemble – A Quiet Place (Live Session)",
                                    "Example Quartet – After the Rain",
                                    "The Night Orchestra – Another Way Home",
                                    "Example Artist – Evening Lights (Extended Version)",
                                    "Studio Trio – Open Skies",
                                    "Example Artist – Morning Movement",
                                    "Example Artist – The Last Song"};
        for (int i = 0; i < titles.size(); ++i)
            row(historyModel,
                {QString("2026-10-28 · 13:%1:00 – 13:%2:00")
                     .arg(i * 4, 2, 10, QChar('0'))
                     .arg(i * 4 + 4, 2, 10, QChar('0')),
                 titles[i], "Radio Example · Jazz"},
                QString("track-%1").arg(i));
        stationCount->setText(text("15 von 15 Sendern", "15 of 15 stations"));
        historyCount->setText(text("8 von 8 Titeln", "8 of 8 tracks"));
        stationView->resizeRowsToContents();
        now->setText("Example Artist – Afternoon Session");
        artist->setText("Radio Example · Jazz");
        status->hide();
        recordStatus->clear();
        bufferControls->hide();
        QStringList captures = themeIDs;
        captures.prepend("schlicht-dark");
        captures.prepend("schlicht-light");
        configureTrackColumns(historyView);
        for (const auto &id : captures) {
            QApplication::setPalette(previousPalette);
            if (id.startsWith("schlicht-")) {
                QPalette palette = previousPalette;
                palette.setColor(QPalette::Window,
                                 id.endsWith("dark") ? QColor("#202124") : QColor("#F3F4F6"));
                QApplication::setPalette(palette);
            }
            applyTheme(id.startsWith("schlicht-") ? "schlicht" : id);
            for (int width : widths) {
                q->resize(width, 620);
                QApplication::processEvents();
                q->grab().save(directory + "/" + id + "-" + QString::number(width) + ".png");
            }
        }
        QApplication::setPalette(previousPalette);
        applyTheme(previous);
        q->resize(previousSize);
        library();
        history();
        bookmarks();
        recordings();
        snapshot(media->snapshot());
    }
};
MainWindow::MainWindow(LibraryStore *s, CatalogService *c, MediaEngine *m, QWidget *parent)
    : QMainWindow(parent), d(std::make_unique<Impl>(this, s, c, m)) {}
MainWindow::~MainWindow() = default;
void MainWindow::showMiniPlayer() { d->miniPlayer(); }
void MainWindow::showVisualizer() { d->fullScreen(); }
void MainWindow::applyTheme(QString id) { d->applyTheme(id); }
void MainWindow::captureScreenshots(QString directory) { d->capture(directory); }
} // namespace Mucke
