#include "mainwindow.h"
#include "../data/catalogservice.h"
#include "../data/librarystore.h"
#include "../media/mediaengine.h"
#include "historyfilter_p.h"
#include "songtools_p.h"
#include "songexportdialog.h"
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QtWidgets>
#include <algorithm>
#include <cmath>

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
struct Colors {
    QColor bg, panel, stage, fg, muted, accent, secondary;
    QString font;
};
Colors colors(QString id) {
    if (id == "acid")
        return {"#1A1B1E", "#121315", "#0E0F11", "#E8EBE9",
                "#8A8F94", "#39FF14", "#00E5FF", "DejaVu Sans Mono"};
    if (id == "retro")
        return {"#1C1A17", "#23201B", "#1A1714", "#F5F0E1", "#C9A227", "#FF9F0A", "#C9A227", "DejaVu Serif"};
    if (id == "fanzine")
        return {"#ECEAE3", "#F4F2EC", "#F0EEE6", "#0D0D0D",
                "#6A6A6A", "#0D0D0D", "#B5231F", "DejaVu Sans Mono"};
    if (id == "stack")
        return {"#0A0A0A", "#141414", "#0D0D0D", "#F7F4EC", "#C8A03C", "#C8A03C", "#E8C766", "DejaVu Serif"};
    if (id == "danish")
        return {"#ECEAE6", "#F3F1EE", "#EFEDE9", "#1A1A1A", "#514C44", "#4C4842", "#B5894F", "DejaVu Sans"};
    if (id == "midi")
        return {"#050507", "#0A0A12", "#060608", "#E8E8FF",
                "#7A7AA0", "#FF2EC4", "#1EE6FF", "DejaVu Sans Mono"};
    bool dark = QApplication::palette().color(QPalette::Window).lightness() < 128;
    return dark ? Colors{"#202124", "#292B2E", "#18191B", "#F4F4F4",
                         "#B0B4BA", "#81B9FF", "#A8D5FF", QApplication::font().family()}
                : Colors{"#F3F4F6", "#FFFFFF", "#E9EDF3", "#20252D",
                         "#626B77", "#2868B2", "#6395CA", QApplication::font().family()};
}
class ActivityObserver final : public QObject {
  public:
    std::function<void()> changed;
    explicit ActivityObserver(QObject *parent) : QObject(parent) {}
    bool eventFilter(QObject *, QEvent *event) override {
        if ((event->type() == QEvent::Show || event->type() == QEvent::Hide ||
             event->type() == QEvent::WindowStateChange) &&
            changed)
            changed();
        return false;
    }
};
class Visualizer final : public QWidget {
  public:
    QString theme = "schlicht";
    QVector<float> wave, spectrum;
    float rms = 0;
    explicit Visualizer(QWidget *parent = nullptr) : QWidget(parent) {
        // Die vollstaendig deckende Flaeche braucht pro Bild keine erneute Elterntextur.
        setAttribute(Qt::WA_OpaquePaintEvent);
        setMinimumHeight(125);
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    }
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        auto c = colors(theme);
        p.fillRect(rect(), c.stage);
        p.setRenderHint(QPainter::Antialiasing);
        QRectF area = QRectF(rect()).adjusted(20, 20, -20, -20);
        QLinearGradient gradient(area.topLeft(), area.bottomRight());
        gradient.setColorAt(0, c.accent);
        gradient.setColorAt(1, c.secondary);
        p.setPen(QPen(QBrush(gradient), 2));
        if (theme == "retro" || theme == "stack") {
            for (int channel = 0; channel < 2; ++channel) {
                QPointF center(area.left() + area.width() * (channel ? .75 : .25), area.bottom());
                double radius = std::min(area.width() * .23, area.height() * .9);
                p.drawArc(QRectF(center.x() - radius, center.y() - radius, radius * 2, radius * 2), 25 * 16,
                          130 * 16);
                double angle =
                    (155 - std::clamp(std::sqrt(std::max(0., double(rms))), 0., 1.) * 130) * M_PI / 180;
                p.drawLine(center, center + QPointF(std::cos(angle) * radius, -std::sin(angle) * radius));
            }
        } else if (theme == "midi" || theme == "danish") {
            int count = 40;
            double step = area.width() / count;
            p.setPen(Qt::NoPen);
            p.setBrush(gradient);
            for (int i = 0; i < count; ++i) {
                float value =
                    spectrum.isEmpty()
                        ? 0
                        : spectrum[std::min(spectrum.size() - 1, qsizetype(i * spectrum.size() / count))];
                double h = std::clamp(double(value), 0., 1.) * area.height();
                p.drawRoundedRect(QRectF(area.left() + i * step, area.bottom() - std::max(2., h),
                                         std::max(1., step - 3), std::max(2., h)),
                                  2, 2);
            }
        } else {
            QPainterPath path;
            int count = std::min(512, int(wave.size()));
            for (int i = 0; i < std::max(2, count); ++i) {
                double x = area.left() + area.width() * i / std::max(1, count - 1);
                double y = area.center().y() - (count ? wave[i] : 0) * area.height() * .45;
                if (i == 0)
                    path.moveTo(x, y);
                else
                    path.lineTo(x, y);
            }
            p.drawPath(path);
        }
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
    QDialog *mini = nullptr, *full = nullptr;
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
    bool framePending = false, visualizationActive = false;
    QObject callbacks;
    ActivityObserver *windowActivity = nullptr, *fullActivity = nullptr;
    bool updating = false;
    Impl(MainWindow *window, LibraryStore *s, CatalogService *c, MediaEngine *m)
        : q(window), store(s), catalog(c), media(m) {
        auto language = store->settings()["language"].toString();
        if (language == "de" || language == "en")
            QLocale::setDefault(QLocale(language));
        q->setWindowTitle("Mucke, Baby!");
        q->resize(1080, 720);
        q->setMinimumSize(640, 500);
        auto *root = new QWidget;
        root->setObjectName("shell");
        q->setCentralWidget(root);
        auto *layout = new QVBoxLayout(root);
        layout->setContentsMargins(18, 16, 18, 16);
        layout->setSpacing(12);
        auto *heading = new QHBoxLayout;
        auto *brand = new QLabel("Mucke, Baby!");
        brand->setObjectName("brand");
        auto brandFont = brand->font();
        brandFont.setPointSize(21);
        brandFont.setBold(true);
        brand->setFont(brandFont);
        heading->addWidget(brand);
        heading->addStretch();
        themes = new QComboBox;
        themes->addItems(themeNames);
        themes->setAccessibleName(text("Theme", "Theme"));
        heading->addWidget(themes);
        button(text("Mini", "Mini"), heading, [this] { miniPlayer(); });
        auto *fullButton = button("", heading, [this] { fullScreen(); });
        fullScreenButton = fullButton;
        fullButton->setIcon(q->style()->standardIcon(QStyle::SP_TitleBarMaxButton));
        fullButton->setToolTip(text("Vollbild (F11)", "Full screen (F11)"));
        fullButton->setAccessibleName(fullButton->toolTip());
        auto *settingsButton = button("⚙", heading, [this] { settings(); });
        settingsButton->setToolTip(text("Einstellungen", "Settings"));
        settingsButton->setAccessibleName(settingsButton->toolTip());
        layout->addLayout(heading);
        auto *split = new QSplitter;
        layout->addWidget(split, 1);
        auto *left = new QWidget;
        auto *ll = new QVBoxLayout(left);
        ll->setContentsMargins(0, 0, 0, 0);
        search = new QLineEdit;
        search->setObjectName("stationSearch");
        search->setPlaceholderText(text("Sender suchen …", "Search stations …"));
        ll->addWidget(search);
        auto *filters = new QHBoxLayout;
        group = new QComboBox;
        favorites = new QCheckBox("★");
        favorites->setToolTip(text("Nur Favoriten", "Favorites only"));
        favorites->setAccessibleName(favorites->toolTip());
        filters->addWidget(group, 1);
        filters->addWidget(favorites);
        ll->addLayout(filters);
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
        auto *stationActions = new QHBoxLayout;
        button("+", stationActions, [this] { editStation({}); });
        auto *editButton = button("✎", stationActions, [this] { editStation(selectedID(stationView)); });
        editButton->setToolTip(text("Sender bearbeiten", "Edit station"));
        editButton->setAccessibleName(editButton->toolTip());
        button(text("Katalog", "Catalog"), stationActions, [this] { catalogDialog(); });
        ll->addLayout(stationActions);
        split->addWidget(left);
        auto *right = new QWidget;
        auto *rl = new QVBoxLayout(right);
        rl->setContentsMargins(4, 0, 0, 0);
        now = new QLabel(text("Bereit für Musik", "Ready for music"));
        now->setObjectName("nowPlaying");
        now->setTextFormat(Qt::PlainText);
        now->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::TextSelectableByKeyboard);
        now->setWordWrap(true);
        auto nf = now->font();
        nf.setPointSize(23);
        nf.setBold(true);
        now->setFont(nf);
        artist =
            new QLabel(text("Sender wählen und Wiedergabe starten.", "Choose a station and start playback."));
        artist->setTextFormat(Qt::PlainText);
        artist->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::TextSelectableByKeyboard);
        artist->setWordWrap(true);
        rl->addWidget(now);
        rl->addWidget(artist);
        visual = new Visualizer;
        visual->setMinimumHeight(90);
        rl->addWidget(visual, 1);
        status = new QLabel;
        status->setTextFormat(Qt::PlainText);
        status->setWordWrap(true);
        rl->addWidget(status);
        tabs = new QTabWidget;
        tabs->setObjectName("libraryTabs");
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
        auto *hf = new QHBoxLayout;
        historySearch = new QLineEdit;
        historySearch->setPlaceholderText(text("Titel / Künstler filtern", "Filter title / artist"));
        historyStation = new QComboBox;
        period = new QComboBox;
        period->addItems({text("Alle Zeiten", "All time"), text("Heute", "Today"), text("7 Tage", "7 days"),
                          text("30 Tage", "30 days"), text("Zeitraum …", "Custom dates …")});
        period->setObjectName("historyPeriod");
        hl->addWidget(historySearch);
        historySearch->setMinimumWidth(120);
        historyStation->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
        historyStation->setMinimumContentsLength(12);
        hf->addWidget(historyStation, 1);
        hf->addWidget(period);
        hl->addLayout(hf);
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
        hl->addWidget(historyView);
        auto *ha = new QHBoxLayout;
        button(text("Merken", "Bookmark"), ha, [this] {
            auto id = selectedID(historyView);
            for (auto t : store->history())
                if (t.id == id)
                    store->bookmark(t);
        });
        auto *audioExport = button(text("Audio exportieren …", "Export audio …"), ha, [this] { exportSongs(historyView, false); });
        audioExport->setObjectName("historyAudioExport");
        auto *historyActions = button("...", ha, [this] { trackMenu(historyView, false, QCursor::pos()); });
        historyActions->setObjectName("historyTrackActions");
        historyActions->setToolTip(
            text("Weitere Aktionen: Musiklinks, Songtext und Verlauf löschen", "More actions: music links, lyrics and clear history"));
        historyActions->setAccessibleName(historyActions->toolTip());
        historyView->setContextMenuPolicy(Qt::CustomContextMenu);
        QObject::connect(historyView, &QWidget::customContextMenuRequested, q, [this](QPoint position) {
            trackMenu(historyView, false, historyView->viewport()->mapToGlobal(position));
        });
        hl->addLayout(ha);
        tabs->addTab(historyPage, text("Verlauf", "History"));
        auto *bp = new QWidget;
        auto *bl = new QVBoxLayout(bp);
        bookmarkSearch = new QLineEdit;
        bookmarkSearch->setObjectName("bookmarkSearch");
        bookmarkSearch->setPlaceholderText(text("Merkliste durchsuchen …", "Search bookmarks …"));
        bl->addWidget(bookmarkSearch);
        QObject::connect(bookmarkSearch, &QLineEdit::textChanged, q, [this] { bookmarks(); });
        bookmarkView = table(bookmarkModel);
        bookmarkView->setObjectName("bookmarks");
        bl->addWidget(bookmarkView);
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
        rl->addWidget(tabs, 2);
        split->addWidget(right);
        split->setSizes({330, 700});
        auto *controls = new QHBoxLayout;
        play = button(text("▶ Spielen", "▶ Play"), controls, [this] { togglePlayback(); });
        pause = button(text("Pause", "Pause"), controls, [this] { media->togglePause(); });
        bookmark = button("☆", controls, [this] {
            if (!state.heardTrack.raw.isEmpty() || !state.heardTrack.title.isEmpty())
                store->bookmark(state.heardTrack);
        });
        bookmark->setToolTip(text("Aktuellen Titel merken (Strg+D)", "Bookmark current track (Ctrl+D)"));
        record = button(text("● Aufnahme", "● Record"), controls, [this] {
            if (!state.recordRequested &&
                !confirm(text("Aufnahme einschalten? Audio wird im Musikordner gespeichert. Unter 10 GiB "
                              "freiem Speicher stoppt die Aufnahme automatisch.",
                              "Enable recording? Audio is saved in your Music folder. Recording stops "
                              "automatically below 10 GiB of free space.")))
                return;
            bool enabled = !state.recordRequested;
            media->setRecordingEnabled(enabled);
            auto settings = store->settings();
            settings["recordingEnabled"] = enabled;
            store->saveSettings(settings);
        });
        controls->addStretch();
        controls->addWidget(new QLabel("♪"));
        volume = new QSlider(Qt::Horizontal);
        volume->setObjectName("volume");
        volume->setRange(0, 100);
        volume->setMaximumWidth(130);
        volume->setMinimumWidth(75);
        volume->setAccessibleName(text("Lautstärke", "Volume"));
        controls->addWidget(volume);
        layout->addLayout(controls);
        auto *buffer = new QHBoxLayout;
        bufferStatus = new QLabel;
        bufferStatus->setTextFormat(Qt::PlainText);
        delay = new QSlider(Qt::Horizontal);
        delay->setRange(0, 0);
        delay->setAccessibleName(text("Puffer-Verzögerung", "Buffer delay"));
        layout->addWidget(bufferStatus);
        buffer->addWidget(delay, 1);
        back15 = button("−15 s", buffer,
                        [this] { media->seekDelay(std::min(state.bufferSeconds, state.delaySeconds + 15)); });
        back15->setObjectName("back15");
        back15->setToolTip(text("15 Sekunden zurück", "Back 15 seconds"));
        forward15 =
            button("+15 s", buffer, [this] { media->seekDelay(std::max(0., state.delaySeconds - 15)); });
        forward15->setObjectName("forward15");
        forward15->setToolTip(text("15 Sekunden vor", "Forward 15 seconds"));
        button(text("Live", "Live"), buffer, [this] { media->goLive(); });
        button(text("Timer …", "Timer …"), buffer, [this] {
            bool ok;
            int minutes =
                QInputDialog::getInt(q, text("Einschlaftimer", "Sleep timer"),
                                     text("Minuten (0 = aus)", "Minutes (0 = off)"), 30, 0, 1440, 1, &ok);
            if (ok)
                media->setSleepTimer(minutes * 60);
        });
        layout->addLayout(buffer);
        recordStatus = new QLabel;
        recordStatus->setTextFormat(Qt::PlainText);
        recordStatus->setWordWrap(true);
        layout->addWidget(recordStatus);
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
        QObject::connect(search, &QLineEdit::textChanged, q, [this] { stations(); });
        QObject::connect(group, qOverload<int>(&QComboBox::currentIndexChanged), q, [this] {
            if (!updating)
                stations();
        });
        QObject::connect(favorites, &QCheckBox::toggled, q, [this] { stations(); });
        QObject::connect(stationView, &QTableView::doubleClicked, q, [this] { playSelected(); });
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
        shortcut("Space", [this] {
            if (!qobject_cast<QLineEdit *>(QApplication::focusWidget()) &&
                !qobject_cast<QAbstractSpinBox *>(QApplication::focusWidget()))
                play->click();
        });
        shortcut("Ctrl+D", [this] { bookmark->click(); });
        shortcut("Ctrl+F", [this] { search->setFocus(); });
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
            QTimer::singleShot(0, &callbacks, [this] { updateAnimation(); });
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
        bool visible =
            (q->isVisible() && !q->isMinimized()) || (full && full->isVisible() && !full->isMinimized());
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
        q->statusBar()->showMessage(e, 15000);
        status->setText(e);
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
        group->addItem(text("Alle Gruppen", "All groups"), "");
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
            if (!s.enabled)
                item->setForeground(colors(theme).muted);
            if (s.id == id)
                stationView->selectRow(stationModel->rowCount() - 1);
        }
    }
    void configureTrackColumns(QTableView *view) {
        view->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Fixed);
        view->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
        view->horizontalHeader()->setSectionResizeMode(2, QHeaderView::Fixed);
        view->setColumnWidth(0,
                             std::max(128, view->fontMetrics().horizontalAdvance("2026-10-28 13:00") + 14));
        view->setColumnWidth(2, 120);
        view->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    }
    void history() {
        historyModel->removeRows(0, historyModel->rowCount());
        auto list = store->history();
        for (auto it = list.crbegin(); it != list.crend(); ++it) {
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
            row(historyModel, {date.toLocalTime().toString("yyyy-MM-dd HH:mm"), trackName(t), t.station},
                t.id);
        }
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
        state = s;
        updateAnimation();
        updating = true;
        volume->setValue(s.volume);
        delay->setMaximum(int(s.bufferSeconds));
        if (!delay->isSliderDown())
            delay->setValue(int(s.delaySeconds));
        updating = false;
        bool playing = s.state == PlaybackState::Playing || s.state == PlaybackState::Buffering ||
                       s.state == PlaybackState::Resolving || s.state == PlaybackState::Paused;
        play->setText(playing ? text("■ Stoppen", "■ Stop") : text("▶ Spielen", "▶ Play"));
        pause->setEnabled(s.timeshiftAvailable || (s.previewActive && (s.state == PlaybackState::Playing ||
                                                                       s.state == PlaybackState::Paused)));
        pause->setText(s.timeshiftPaused || s.state == PlaybackState::Paused ? text("Fortsetzen", "Resume")
                                                                             : text("Pause", "Pause"));
        record->setText(s.recordRequested ? text("● Aufnahme aus", "● Stop recording")
                                          : text("● Aufnahme", "● Record"));
        now->setText(
            trackName(s.heardTrack).isEmpty()
                ? (s.stationName.isEmpty() ? text("Bereit für Musik", "Ready for music") : s.stationName)
                : trackName(s.heardTrack));
        artist->setText(s.stationName);
        QStringList states = {text("Gestoppt", "Stopped"),
                              text("Sender wird aufgelöst …", "Resolving station …"),
                              text("Verbindung / Puffer …", "Connecting / buffering …"),
                              text("Wiedergabe", "Playing"),
                              text("Pausiert", "Paused"),
                              text("Fehler", "Error")};
        status->setText(
            s.error.isEmpty()
                ? states[int(s.state)] + (s.previewActive ? text(" · Vorschau", " · Preview") : "") +
                      (s.sleepRemaining ? text(" · Timer ", " · Timer ") + duration(s.sleepRemaining) : "")
                : s.error);
        recordStatus->setText(s.recordStatus);
        bufferStatus->setText(text("Puffer ", "Buffer ") + duration(s.bufferSeconds) +
                              text(" · Verzögerung ", " · Delay ") + duration(s.delaySeconds));
        delay->setEnabled(s.timeshiftAvailable);
        back15->setEnabled(s.timeshiftAvailable && s.delaySeconds < s.bufferSeconds);
        forward15->setEnabled(s.timeshiftAvailable && s.delaySeconds > 0);
        if (miniTitle)
            miniTitle->setText(now->text() + "\n" + s.stationName);
        if (miniPlay) {
            miniPlay->setText(play->text());
            miniPause->setText(pause->text());
            miniPause->setEnabled(pause->isEnabled());
            miniRecord->setText(record->text());
            miniStatus->setText(status->text() +
                                (s.recordStatus.isEmpty() ? QString() : "\n" + s.recordStatus));
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
        QString css =
            QString(
                "QMainWindow,QDialog{background:%1;color:%4;} "
                "QWidget{color:%4;font-family:'%7';font-size:13px;} QLabel{background:transparent;} "
                "QTableView,QLineEdit,QComboBox,QSpinBox,QDoubleSpinBox,QDateEdit,QListWidget,QPlainTextEdit{"
                "background:%2;color:%4;"
                "border:1px solid %5;border-radius:5px;padding:5px;selection-background-color:%6;} "
                "QTableView{alternate-background-color:%1;} "
                "QPushButton,QToolButton{background:%2;color:%4;border:1px "
                "solid %5;border-radius:5px;padding:6px 10px;} QPushButton:hover{border-color:%6;} "
                "QPushButton:pressed{background:%3;} QPushButton:disabled{color:%5;} "
                "QTabWidget::pane{border:1px solid %5;} QTabBar::tab{background:%2;padding:8px 12px;} "
                "QTabBar::tab:selected{color:%6;border-bottom:2px solid %6;} "
                "QHeaderView::section{background:%2;color:%5;border:none;padding:7px;text-align:left;} "
                "QMenuBar,QMenu,QStatusBar{background:%1;color:%4;} "
                "QSlider::groove:horizontal{height:5px;background:%5;border-radius:2px;} "
                "QSlider::handle:horizontal{width:15px;margin:-5px 0;background:%6;border-radius:7px;} "
                "QCheckBox{spacing:6px;} QSplitter::handle{background:%1;width:10px;} "
                "QLabel#brand{font-size:24px;font-weight:700;} "
                "QLabel#nowPlaying{font-size:26px;font-weight:700;} QLabel#miniTitle{font-size:16px;} "
                "QLabel#fullTitle{font-size:24px;}")
                .arg(c.bg.name(), c.panel.name(), c.stage.name(), c.fg.name(), c.muted.name(),
                     c.accent.name(), c.font);
        const QHash<QString, QString> textures = {
            {"acid", "bg-concrete.png"}, {"retro", "bg-brushed.png"},   {"fanzine", "bg-newsprint.png"},
            {"stack", "bg-tolex.png"},   {"danish", "bg-aluminum.png"}, {"midi", "bg-cyber.png"}};
        const QString texture = ":/themes/" + id + "/" + textures.value(id);
        if (textures.contains(id) && QFile::exists(texture))
            css += QString("QWidget#shell{background-color:%1;background-image:url(%2);}")
                       .arg(c.bg.name(), texture);
        q->setStyleSheet(css);
        configureTrackColumns(historyView);
        configureTrackColumns(bookmarkView);
        recordingView->setColumnWidth(
            0, std::max(128, recordingView->fontMetrics().horizontalAdvance("2026-10-28 13:00") + 14));
        if (mini)
            mini->setStyleSheet(css);
        if (full)
            full->setStyleSheet(css);
        updating = true;
        themes->setCurrentIndex(themeIDs.indexOf(id));
        updating = false;
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
            q->statusBar()->showMessage(text("Bitte 1 bis 100 Titel auswählen.", "Select 1 to 100 tracks."), 5000);
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
                q->statusBar()->showMessage(text("Zuerst einen Titel auswählen.", "Select a track first."), 5000);
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
        QTemporaryDir temporary;
        if (!temporary.isValid()) {
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
        auto *prepare = button(text("Vorbereiten", "Prepare"), actions, [] {});
        auto *listen = button(text("Anhören", "Listen"), actions, [] {});
        listen->setEnabled(false);
        auto *save = button(text("Speichern …", "Save …"), actions, [] {});
        save->setEnabled(false);
        auto *close = button(text("Schließen", "Close"), actions, [&] { dialog.reject(); });
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
                temporary.filePath(job + ".m4a"));
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
            if (prepared.isEmpty())
                return;
            QString destination = QFileDialog::getSaveFileName(
                &dialog, text("Ausschnitt speichern", "Save clip"), "mucke-clip.m4a", "M4A (*.m4a)", nullptr,
                QFileDialog::DontConfirmOverwrite);
            if (destination.isEmpty())
                return;
            if (!destination.endsWith(".m4a", Qt::CaseInsensitive))
                destination += ".m4a";
            // QFile::copy überschreibt keine bestehende Datei; auch ein Rennen nach dem Dateidialog bleibt
            // sicher.
            if (!QFile::copy(prepared, destination)) {
                hint->setText(
                    text("Speichern fehlgeschlagen. Bitte einen neuen Dateinamen wählen; vorhandene Dateien "
                         "werden nicht überschrieben.",
                         "Saving failed. Choose a new filename; existing files are never overwritten."));
                return;
            }
            hint->setText(text("Gespeichert: ", "Saved: ") + destination);
        });
        dialog.exec();
        if (running)
            media->cancelExport(job);
        if (previewing)
            media->stopPreview();
        Q_UNUSED(close);
    }
    void settings() {
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
        if (state.state == PlaybackState::Playing || state.state == PlaybackState::Buffering ||
            state.state == PlaybackState::Resolving || state.state == PlaybackState::Paused) {
            media->stop();
            return;
        }
        const auto station = store->station(stationID);
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
            mini->resize(480, 350);
            mini->setMinimumWidth(440);
            auto *layout = new QVBoxLayout(mini);
            miniTitle = new QLabel;
            miniTitle->setTextFormat(Qt::PlainText);
            miniTitle->setObjectName("miniTitle");
            miniTitle->setWordWrap(true);
            layout->addWidget(miniTitle);
            miniStations = new QComboBox;
            miniStations->setObjectName("miniStations");
            miniStations->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
            miniStations->setMinimumContentsLength(16);
            miniStations->setAccessibleName(text("Sender", "Station"));
            layout->addWidget(miniStations);
            refreshMiniStations();
            QObject::connect(miniStations, qOverload<int>(&QComboBox::activated), mini, [this](int) {
                auto station = store->station(miniStations->currentData().toString());
                if (!station.id.isEmpty() && station.enabled)
                    media->play(station);
            });
            auto *actions = new QHBoxLayout;
            layout->addLayout(actions);
            miniPlay = button(play->text(), actions,
                              [this] { togglePlayback(miniStations->currentData().toString()); });
            miniPlay->setObjectName("miniPlay");
            miniPause = button(pause->text(), actions, [this] { media->togglePause(); });
            miniPause->setObjectName("miniPause");
            miniRecord = button(record->text(), actions, [this] { record->click(); });
            miniRecord->setObjectName("miniRecord");
            auto *save = button("☆", actions, [this] { bookmark->click(); });
            save->setToolTip(bookmark->toolTip());
            save->setAccessibleName(bookmark->toolTip());
            miniStatus = new QLabel;
            miniStatus->setTextFormat(Qt::PlainText);
            miniStatus->setObjectName("miniStatus");
            miniStatus->setWordWrap(true);
            layout->addWidget(miniStatus);
            auto *volumeRow = new QHBoxLayout;
            volumeRow->addWidget(new QLabel(text("Lautstärke", "Volume")));
            auto *vol = new QSlider(Qt::Horizontal);
            vol->setObjectName("miniVolume");
            vol->setRange(0, 100);
            vol->setValue(state.volume);
            vol->setAccessibleName(text("Lautstärke", "Volume"));
            volumeRow->addWidget(vol, 1);
            layout->addLayout(volumeRow);
            QObject::connect(vol, &QSlider::valueChanged, mini, [this](int n) { media->setVolume(n); });
            QObject::connect(media, &MediaEngine::snapshotChanged, mini, [vol](PlaybackSnapshot s) {
                QSignalBlocker blocker(vol);
                vol->setValue(s.volume);
            });
            miniBuffer = new QLabel;
            miniBuffer->setTextFormat(Qt::PlainText);
            miniBuffer->setWordWrap(true);
            layout->addWidget(miniBuffer);
            auto *bufferRow = new QHBoxLayout;
            layout->addLayout(bufferRow);
            miniBack = button("−15 s", bufferRow, [this] { back15->click(); });
            miniBack->setObjectName("miniBack15");
            miniDelay = new QSlider(Qt::Horizontal);
            miniDelay->setObjectName("miniDelay");
            miniDelay->setRange(0, 0);
            miniDelay->setAccessibleName(text("Puffer-Verzögerung", "Buffer delay"));
            bufferRow->addWidget(miniDelay, 1);
            QObject::connect(miniDelay, &QSlider::sliderReleased, mini,
                             [this] { media->seekDelay(miniDelay->value()); });
            miniForward = button("+15 s", bufferRow, [this] { forward15->click(); });
            miniForward->setObjectName("miniForward15");
            miniLive = button(text("Live", "Live"), bufferRow, [this] { media->goLive(); });
            miniLive->setObjectName("miniLive");
            auto *footer = new QHBoxLayout;
            layout->addLayout(footer);
            auto *onTop = new QCheckBox(text("Immer im Vordergrund", "Always on top"));
            onTop->setObjectName("miniAlwaysOnTop");
            onTop->setChecked(store->settings()["miniAlwaysOnTop"].toBool(false));
            footer->addWidget(onTop);
            footer->addStretch();
            QObject::connect(onTop, &QCheckBox::toggled, mini, [this](bool enabled) {
                auto settings = store->settings();
                settings["miniAlwaysOnTop"] = enabled;
                if (!store->saveSettings(settings))
                    return;
                bool visible = mini->isVisible();
                mini->setWindowFlag(Qt::WindowStaysOnTopHint, enabled);
                if (visible)
                    mini->show();
            });
            button(text("Hauptfenster", "Main window"), footer, [this] {
                q->showNormal();
                q->raise();
                mini->hide();
            });
            mini->setStyleSheet(q->styleSheet());
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
        row(stationModel, {"Radio Example · Jazz", "★"}, "fixture-jazz");
        row(stationModel, {"Radio Example · Electronic", ""}, "fixture-electronic");
        row(stationModel, {"Radio Example · Classical", ""}, "fixture-classical");
        row(historyModel, {"2026-10-28 13:00", "Example Artist — Afternoon Session", "Radio Example · Jazz"});
        now->setText("Afternoon Session");
        artist->setText("Example Artist · Radio Example");
        status->setText(text("Bereit für Wiedergabe", "Ready for playback"));
        recordStatus->clear();
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
                q->resize(width, 720);
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
