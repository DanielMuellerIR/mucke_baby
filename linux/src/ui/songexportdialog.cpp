#include "songexportdialog.h"
#include "songexportfile_p.h"
#include "../media/mediaengine.h"
#include <QtWidgets>
#include <algorithm>
#include <functional>
#include <memory>

namespace Mucke {
namespace {
QString text(const char *de, const char *en) {
    return QString::fromUtf8(QLocale().language() == QLocale::German ? de : en);
}
QString timeValue(double value) { return QLocale().toString(value, 'f', 2) + " s"; }
QString statusText(SongAudioStatus status) {
    switch (status) {
    case SongAudioStatus::Available: return text("Schnittvorschlag", "Cut proposal");
    case SongAudioStatus::Partial: return text("Unvollständig", "Partial");
    case SongAudioStatus::Approximate: return text("Ungefähr", "Approximate");
    case SongAudioStatus::MissingBoundaries: return text("Schnittgrenzen fehlen", "Missing boundaries");
    case SongAudioStatus::MissingFile: return text("Aufnahmedatei fehlt", "Recording file missing");
    case SongAudioStatus::ActiveRecording: return text("Zuerst Aufnahme beenden", "Stop recording first");
    case SongAudioStatus::Unsupported: return text("Format nicht unterstützt", "Unsupported format");
    case SongAudioStatus::Failed: return text("Analyse fehlgeschlagen", "Analysis failed");
    }
    return {};
}
bool canRender(const SongExportProposal &p) {
    return p.status == SongAudioStatus::Available || p.status == SongAudioStatus::Partial ||
           p.status == SongAudioStatus::Approximate;
}
bool needsConsent(const SongExportProposal &p) {
    return p.status != SongAudioStatus::Available || p.partialStart || p.partialEnd;
}
struct ExportRow {
    Track track;
    SongExportProposal proposal;
    QString state, prepared, saved, error;
    double start = 0, end = 0, fadeIn = 0, fadeOut = 0;
    bool analyzed = false;
};
class ExportModel final : public QAbstractTableModel {
  public:
    QVector<ExportRow> rows;
    explicit ExportModel(QVector<Track> tracks, QObject *parent) : QAbstractTableModel(parent) {
        for (auto &track : tracks) {
            ExportRow row;
            row.track = std::move(track);
            row.state = text("Wird untersucht …", "Analyzing …");
            rows.append(std::move(row));
        }
    }
    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : int(rows.size()); }
    int columnCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : 4; }
    QVariant headerData(int section, Qt::Orientation orientation, int role) const override {
        if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
            return {};
        const QStringList captions = {text("Titel", "Track"), text("Audio", "Audio"),
                                      text("Vorgang", "Operation"), text("Ergebnis / Fehler", "Result / error")};
        return captions.value(section);
    }
    QVariant data(const QModelIndex &index, int role) const override {
        if (!index.isValid() || index.row() >= rows.size())
            return {};
        const auto &r = rows[index.row()];
        const QString name = r.track.artist.isEmpty() ? (r.track.title.isEmpty() ? r.track.raw : r.track.title)
                                                       : r.track.artist + " — " + r.track.title;
        if (role == Qt::ToolTipRole)
            return name + "\n" + r.proposal.explanation + "\n" + r.saved + "\n" + r.error;
        if (role != Qt::DisplayRole)
            return {};
        switch (index.column()) {
        case 0: return name;
        case 1: return r.analyzed ? statusText(r.proposal.status) : QString();
        case 2: return r.state;
        case 3: return r.error.isEmpty() ? r.saved : r.error;
        }
        return {};
    }
    void changed(int row) { emit dataChanged(index(row, 0), index(row, 3)); }
};
class SongExportDialog final : public QDialog {
    QPointer<MediaEngine> media;
    ExportModel *model;
    QTableView *view;
    QLabel *details, *message;
    QDoubleSpinBox *start, *end, *fadeIn, *fadeOut;
    QCheckBox *consent;
    QPushButton *prepare, *prepareAll, *listen, *stopListen, *save, *saveAll, *cancel;
    QProgressBar *progress;
    QTemporaryDir temporary;
    QString requestID = newID(), jobID, expectedPath;
    QVector<int> queue, saveQueue;
    int currentRow = -1, previewRow = -1;
    bool analyzing = true, ownsPreview = false, previewStarting = false, loading = false, saving = false, closing = false;
    bool rendering = false, cancellingExport = false;
    QString saveDirectory;
    std::shared_ptr<std::atomic_bool> saveCancelled;

    int selected() const { return view->currentIndex().isValid() ? view->currentIndex().row() : -1; }
    bool permitted(const ExportRow &row) const {
        return row.analyzed && canRender(row.proposal) && (!needsConsent(row.proposal) || consent->isChecked());
    }
    void stopOwnPreview() {
        if (ownsPreview && media)
            media->stopPreview();
        ownsPreview = false;
        previewStarting = false;
        previewRow = -1;
    }
    void cleanup() {
        if (closing)
            return;
        closing = true;
        if (saveCancelled)
            saveCancelled->store(true);
        if (media) {
            media->cancelSongPreparation(requestID);
            if (!jobID.isEmpty())
                media->cancelExport(jobID);
            stopOwnPreview();
        }
    }
    void updateActions() {
        const int i = selected();
        const bool idle = !analyzing && !rendering && jobID.isEmpty() && !saving && media && temporary.isValid();
        const bool usable = i >= 0 && permitted(model->rows[i]);
        bool any = false, anyPrepared = false;
        for (const auto &row : model->rows) {
            any |= permitted(row);
            anyPrepared |= permitted(row) && !row.prepared.isEmpty();
        }
        prepare->setEnabled(idle && usable);
        prepareAll->setEnabled(idle && any);
        listen->setEnabled(idle && usable && !model->rows[i].prepared.isEmpty());
        stopListen->setEnabled(ownsPreview);
        save->setEnabled(idle && usable && !model->rows[i].prepared.isEmpty());
        saveAll->setEnabled(idle && anyPrepared);
        consent->setEnabled(idle);
        cancel->setEnabled(analyzing || rendering || saving);
        for (auto *field : {start, end, fadeIn, fadeOut})
            field->setEnabled(idle && usable);
    }
    void loadSelection() {
        const int i = selected();
        loading = true;
        if (i >= 0) {
            const auto &r = model->rows[i];
            const auto &p = r.proposal;
            const bool valid = r.analyzed && canRender(p) && SongExportFile::validRange(p, 0, 0, 0, 0);
            start->setRange(valid ? p.audioStart - p.suggestedStart : 0,
                            valid ? p.audioEnd - p.suggestedStart : 0);
            end->setRange(valid ? p.audioStart - p.suggestedEnd : 0,
                          valid ? p.audioEnd - p.suggestedEnd : 0);
            start->setValue(r.start);
            end->setValue(r.end);
            fadeIn->setValue(r.fadeIn);
            fadeOut->setValue(r.fadeOut);
            QString info = p.explanation;
            if (valid) {
                info += "\n" + text("Vorschlag: ", "Proposal: ") + timeValue(p.suggestedStart) + " – " + timeValue(p.suggestedEnd);
                info += "\n" + text("Startintervall: ", "Start interval: ") + timeValue(p.startLower) + " – " + timeValue(p.startUpper);
                info += text("; Endintervall: ", "; end interval: ") + timeValue(p.endLower) + " – " + timeValue(p.endUpper);
                if (p.partialStart || p.partialEnd)
                    info += "\n" + text("Die Aufnahme enthält den Titel nur teilweise.", "The recording contains only part of this track.");
            }
            if (p.status == SongAudioStatus::ActiveRecording)
                info += "\n" + text("Bitte die Aufnahme bewusst beenden und den Dialog neu öffnen. Die Wiedergabe wird hier nicht gestoppt.",
                                     "Stop the recording yourself, then reopen this dialog. Playback is not stopped here.");
            details->setText(info);
        }
        loading = false;
        updateActions();
    }
    void settingsChanged() {
        const int i = selected();
        if (loading || i < 0)
            return;
        auto &r = model->rows[i];
        r.start = start->value(); r.end = end->value(); r.fadeIn = fadeIn->value(); r.fadeOut = fadeOut->value();
        if (previewRow == i)
            stopOwnPreview();
        if (!r.prepared.isEmpty())
            QFile::remove(r.prepared);
        r.prepared.clear();
        r.saved.clear();
        r.error.clear();
        r.state = text("Einstellungen geändert", "Settings changed");
        model->changed(i);
        updateActions();
    }
    void nextRender() {
        if (!rendering)
            return;
        if (queue.isEmpty() || !media) {
            rendering = false;
            currentRow = -1;
            progress->hide();
            updateActions();
            return;
        }
        currentRow = queue.takeFirst();
        auto &r = model->rows[currentRow];
        r.error.clear();
        if (!permitted(r) || !SongExportFile::validRange(r.proposal, r.start, r.end, r.fadeIn, r.fadeOut)) {
            r.error = text("Schnitt oder Blenden liegen außerhalb des verfügbaren Audios.", "Cut or fades exceed the available audio.");
            r.state = text("Übersprungen", "Skipped");
            model->changed(currentRow);
            QTimer::singleShot(0, this, [this] { nextRender(); });
            return;
        }
        if (!r.prepared.isEmpty())
            QFile::remove(r.prepared);
        r.prepared.clear();
        r.saved.clear();
        jobID = newID();
        expectedPath = temporary.filePath(jobID + ".m4a");
        r.state = text("M4A wird vorbereitet …", "Preparing M4A …");
        model->changed(currentRow);
        progress->setRange(0, 0);
        progress->show();
        updateActions();
        media->exportPreparedSong(jobID, r.proposal, r.start, r.end, r.fadeIn, r.fadeOut, expectedPath);
    }
    void render(bool all) {
        if (rendering || saving || analyzing || !media)
            return;
        rendering = true;
        stopOwnPreview();
        queue.clear();
        for (int i = 0; i < model->rows.size(); ++i)
            if ((all || i == selected()) && permitted(model->rows[i])) {
                queue.append(i);
                model->rows[i].state = text("Wartet", "Queued");
                model->changed(i);
            }
        nextRender();
    }
    void nextSave() {
        if (saveQueue.isEmpty() || closing) {
            saving = false;
            progress->hide();
            updateActions();
            return;
        }
        const int i = saveQueue.takeFirst();
        auto &r = model->rows[i];
        if (!permitted(r) || r.prepared.isEmpty()) {
            QTimer::singleShot(0, this, [this] { nextSave(); });
            return;
        }
        r.state = text("Wird gespeichert …", "Saving …");
        model->changed(i);
        const QString source = r.prepared, directory = saveDirectory, base = SongExportFile::safeBase(r.track);
        auto result = std::make_shared<SongExportFile::PublishResult>();
        auto cancelled = saveCancelled;
        auto *worker = QThread::create([source, directory, base, result, cancelled] {
            *result = SongExportFile::publishExact(source, directory, base, *cancelled);
        });
        connect(worker, &QThread::finished, this, [this, i, result] {
            auto &row = model->rows[i];
            row.error = result->error;
            row.saved = result->path;
            row.state = result->cancelled ? text("Abgebrochen", "Cancelled") :
                        result->path.isEmpty() ? text("Speichern fehlgeschlagen", "Saving failed") : text("Gespeichert", "Saved");
            model->changed(i);
            nextSave();
        });
        connect(worker, &QThread::finished, worker, &QObject::deleteLater);
        worker->start();
    }
    void savePrepared(bool all) {
        if (rendering || saving || analyzing || !media)
            return;
        const QString directory = QFileDialog::getExistingDirectory(this, text("Exportordner wählen", "Choose export folder"));
        if (directory.isEmpty())
            return;
        saveDirectory = directory;
        saveQueue.clear();
        for (int i = 0; i < model->rows.size(); ++i)
            if ((all || i == selected()) && permitted(model->rows[i]) && !model->rows[i].prepared.isEmpty())
                saveQueue.append(i);
        saving = true;
        saveCancelled = std::make_shared<std::atomic_bool>(false);
        progress->setRange(0, 0);
        progress->show();
        updateActions();
        nextSave();
    }
    void cancelWork() {
        if (analyzing) {
            if (media)
                media->cancelSongPreparation(requestID);
            analyzing = false;
            for (int i = 0; i < model->rows.size(); ++i) {
                model->rows[i].state = text("Abgebrochen", "Cancelled");
                model->changed(i);
            }
        }
        for (int i : queue) {
            model->rows[i].state = text("Abgebrochen", "Cancelled");
            model->changed(i);
        }
        queue.clear();
        if (!jobID.isEmpty() && media) {
            cancellingExport = true;
            media->cancelExport(jobID);
        } else {
            rendering = false;
        }
        if (saveCancelled)
            saveCancelled->store(true);
        for (int i : saveQueue) {
            model->rows[i].state = text("Abgebrochen", "Cancelled");
            model->changed(i);
        }
        saveQueue.clear();
        progress->setVisible(saving || rendering);
        updateActions();
    }
  public:
    SongExportDialog(QVector<Track> tracks, MediaEngine *engine, QWidget *parent)
        : QDialog(parent), media(engine), model(new ExportModel(tracks, this)) {
        setObjectName("songExportDialog");
        setWindowTitle(text("Titel aus Aufnahmen exportieren", "Export tracks from recordings"));
        resize(840, 690);
        auto *layout = new QVBoxLayout(this);
        auto *hint = new QLabel(text("Metadaten liefern Schnittvorschläge, keinen Nachweis vollständiger Songs. Senderansagen und Übergänge können enthalten sein. Die Quelldateien bleiben unverändert. Vorschau und Speichern verwenden dieselbe vorbereitete M4A-Datei.",
                                    "Metadata provides cut proposals, not proof of complete songs. Announcements and transitions may be included. Source files stay unchanged. Preview and save use the same prepared M4A file."));
        hint->setWordWrap(true);
        layout->addWidget(hint);
        view = new QTableView;
        view->setObjectName("songExportTable");
        view->setModel(model);
        view->setSelectionBehavior(QAbstractItemView::SelectRows);
        view->setSelectionMode(QAbstractItemView::SingleSelection);
        view->setEditTriggers(QAbstractItemView::NoEditTriggers);
        view->setAlternatingRowColors(true);
        view->setShowGrid(false);
        view->verticalHeader()->hide();
        view->horizontalHeader()->setSectionResizeMode(QHeaderView::Interactive);
        view->horizontalHeader()->setStretchLastSection(true);
        view->setColumnWidth(0, 200); view->setColumnWidth(1, 130); view->setColumnWidth(2, 145);
        layout->addWidget(view, 1);
        details = new QLabel;
        details->setObjectName("songExportDetails");
        details->setTextFormat(Qt::PlainText);
        details->setWordWrap(true);
        details->setTextInteractionFlags(Qt::TextSelectableByMouse);
        layout->addWidget(details);
        auto *form = new QGridLayout;
        auto spin = [this](const char *name, double maximum) {
            auto *field = new QDoubleSpinBox;
            field->setObjectName(name);
            field->setDecimals(2); field->setRange(0, maximum); field->setSuffix(" s");
            connect(field, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [this] { settingsChanged(); });
            return field;
        };
        start = spin("songStartAdjustment", 0); end = spin("songEndAdjustment", 0);
        fadeIn = spin("songFadeIn", 30); fadeOut = spin("songFadeOut", 30);
        int column = 0;
        for (const auto &pair : {qMakePair(text("Startkorrektur", "Start adjustment"), start),
                                qMakePair(text("Endkorrektur", "End adjustment"), end),
                                qMakePair(text("Einblenden", "Fade in"), fadeIn),
                                qMakePair(text("Ausblenden", "Fade out"), fadeOut)}) {
            auto *label = new QLabel(pair.first); label->setBuddy(pair.second);
            form->addWidget(label, 0, column); form->addWidget(pair.second, 1, column++);
        }
        layout->addLayout(form);
        consent = new QCheckBox(text("Unvollständige und ungefähre Schnitte ausdrücklich zulassen", "Explicitly allow partial and approximate cuts"));
        consent->setObjectName("songExportConsent");
        layout->addWidget(consent);
        connect(consent, &QCheckBox::toggled, this, [this] { updateActions(); });
        message = new QLabel(text("Audio-Schnittgrenzen werden untersucht …", "Analyzing audio boundaries …"));
        message->setTextFormat(Qt::PlainText);
        message->setWordWrap(true); layout->addWidget(message);
        progress = new QProgressBar; progress->setRange(0, 0); layout->addWidget(progress);
        auto makeButton = [this](QString caption, const char *name, QBoxLayout *line, const std::function<void()> &action) {
            auto *button = new QPushButton(caption); button->setObjectName(name); button->setMinimumHeight(32);
            line->addWidget(button); connect(button, &QPushButton::clicked, this, action); return button;
        };
        auto *renderActions = new QHBoxLayout;
        layout->addLayout(renderActions);
        prepare = makeButton(text("Auswahl vorbereiten", "Prepare selected"), "songPrepare", renderActions, [this] { render(false); });
        prepareAll = makeButton(text("Alle vorbereiten", "Prepare all"), "songPrepareAll", renderActions, [this] { render(true); });
        listen = makeButton(text("Anhören", "Listen"), "songListen", renderActions, [this] {
            const int i = selected();
            if (i < 0 || !media || model->rows[i].prepared.isEmpty()) return;
            const auto snapshot = media->snapshot();
            if (snapshot.recordActive || (snapshot.state != PlaybackState::Stopped && !snapshot.previewActive)) {
                const QString explanation = snapshot.recordActive
                    ? text("Titelvorhören beendet Live-Wiedergabe und laufende Aufnahme. Fortfahren?",
                           "Previewing this track ends live playback and the active recording. Continue?")
                    : text("Die Vorschau beendet die aktuelle Live-Wiedergabe. Fortfahren?",
                           "Preview ends current live playback. Continue?");
                QMessageBox question(QMessageBox::Question, text("Vorschau", "Preview"), explanation,
                                     QMessageBox::NoButton, this);
                auto *proceed = question.addButton(text("Vorschau starten", "Start preview"), QMessageBox::AcceptRole);
                auto *abort = question.addButton(text("Abbrechen", "Cancel"), QMessageBox::RejectRole);
                question.setDefaultButton(abort);
                question.exec();
                if (question.clickedButton() != proceed || !media)
                    return;
                if (!snapshot.recordActive && media->snapshot().recordActive)
                    return;
            }
            stopOwnPreview(); ownsPreview = true; previewStarting = true; previewRow = i;
            media->previewFile(model->rows[i].prepared); updateActions();
        });
        stopListen = makeButton(text("Vorschau stoppen", "Stop preview"), "songStopPreview", renderActions, [this] { stopOwnPreview(); updateActions(); });
        auto *saveActions = new QHBoxLayout;
        layout->addLayout(saveActions);
        save = makeButton(text("Auswahl speichern …", "Save selected …"), "songSave", saveActions, [this] { savePrepared(false); });
        saveAll = makeButton(text("Vorbereitete speichern …", "Save all prepared …"), "songSaveAll", saveActions, [this] { savePrepared(true); });
        cancel = makeButton(text("Rest abbrechen", "Cancel remaining"), "songCancel", saveActions, [this] { cancelWork(); });
        makeButton(text("Schließen", "Close"), "songClose", saveActions, [this] { reject(); });
        connect(view->selectionModel(), &QItemSelectionModel::currentRowChanged, this, [this] { loadSelection(); });
        connect(this, &QDialog::finished, this, [this] { cleanup(); });
        connect(engine, &MediaEngine::snapshotChanged, this, [this](PlaybackSnapshot snapshot) {
            if (snapshot.previewActive) previewStarting = false;
            if (!snapshot.previewActive && (!previewStarting || !snapshot.error.isEmpty())) {
                ownsPreview = false; previewStarting = false; previewRow = -1; updateActions();
            }
        });
        connect(engine, &QObject::destroyed, this, [this] { media = nullptr; cancelWork(); updateActions(); });
        connect(engine, &MediaEngine::songPreparationProgress, this, [this](QString request, int done, int total) {
            if (request != requestID || !analyzing) return;
            progress->setRange(0, std::max(0, total)); progress->setValue(std::clamp(done, 0, std::max(0, total)));
            message->setText(text("Aufnahmen untersucht: %1 / %2", "Recordings analyzed: %1 / %2").arg(done).arg(total));
        });
        connect(engine, &MediaEngine::songExportsPrepared, this, [this](QString request, QVector<SongExportProposal> proposals) {
            if (request != requestID || !analyzing || closing) return;
            analyzing = false;
            for (int i = 0; i < model->rows.size(); ++i) {
                auto &r = model->rows[i];
                r.analyzed = true; r.proposal.status = SongAudioStatus::Failed;
                r.proposal.explanation = text("Kein Schnittvorschlag erhalten.", "No cut proposal received.");
                for (const auto &p : proposals)
                    if (p.trackID == r.track.id && p.requestID == requestID) { r.proposal = p; break; }
                if (canRender(r.proposal) && !SongExportFile::validRange(r.proposal, 0, 0, 0, 0)) {
                    r.proposal.status = SongAudioStatus::Failed;
                    r.proposal.explanation = text("Ungültige Audio-Schnittgrenzen.", "Invalid audio boundaries.");
                }
                r.state = canRender(r.proposal) ? text("Bereit zum Vorbereiten", "Ready to prepare") : text("Nicht verfügbar", "Unavailable");
                model->changed(i);
            }
            progress->hide();
            message->setText(text("Auswahl korrigieren, vorbereiten, anhören und anschließend speichern. Vorhandene Dateien werden nie überschrieben; gleiche Namen erhalten eine Nummer.",
                                  "Adjust a selection, prepare, listen, then save. Existing files are never overwritten; duplicate names receive a number."));
            loadSelection();
        });
        connect(engine, &MediaEngine::exportFinished, this, [this](QString finishedJob, QString path, QString error) {
            if (finishedJob != jobID || closing || currentRow < 0) return;
            auto &r = model->rows[currentRow];
            jobID.clear();
            if (cancellingExport) {
                cancellingExport = false;
                r.state = text("Abgebrochen", "Cancelled");
                model->changed(currentRow);
                nextRender();
                return;
            }
            if (error.isEmpty() && path == expectedPath && QFileInfo(path).isFile() && QFileInfo(path).size() > 0) {
                r.prepared = path; r.state = text("Vorbereitet", "Prepared");
            } else {
                r.error = error.isEmpty() ? text("Die vorbereitete Datei fehlt.", "The prepared file is missing.") : error;
                r.state = text("Vorbereitung fehlgeschlagen", "Preparation failed");
            }
            model->changed(currentRow);
            nextRender();
        });
        if (!tracks.isEmpty()) view->selectRow(0);
        updateActions();
        if (!temporary.isValid()) {
            analyzing = false; progress->hide();
            message->setText(text("Temporärer Exportordner nicht verfügbar.", "Temporary export folder unavailable."));
            updateActions();
        } else {
            QTimer::singleShot(0, this, [this, tracks] {
                if (media && !closing && analyzing) media->prepareSongExports(requestID, tracks);
            });
        }
    }
    ~SongExportDialog() override { cleanup(); }
};
} // namespace
void showSongExportDialog(QVector<Track> tracks, MediaEngine *media, QWidget *parent) {
    if (!media || tracks.isEmpty()) return;
    if (tracks.size() > 100) {
        QMessageBox::information(parent, text("Titelexport", "Track export"),
                                 text("Bitte höchstens 100 Titel gleichzeitig auswählen.", "Select no more than 100 tracks at once."));
        return;
    }
    SongExportDialog dialog(std::move(tracks), media, parent);
    dialog.exec();
}
} // namespace Mucke
