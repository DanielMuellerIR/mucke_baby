#include "updatedialog.h"
#include "../buildinfo.h"
#include <QtWidgets>
namespace Mucke {
namespace {
QString tr(const char *de, const char *en) {
    return QString::fromUtf8(QLocale().language() == QLocale::German ? de : en);
}
class UpdateDialog final : public QDialog {
    QTemporaryDir directory;
    QProcess process;
    QTimer deadline;
    QLabel *status;
    QPushButton *install, *close;
    QProgressBar *progress;
    QString version;
    bool quiet, installing = false;
    void failed(QString message) {
        deadline.stop();
        progress->hide();
        install->setEnabled(false);
        close->setEnabled(true);
        status->setText(message);
        if (quiet) deleteLater();
    }
    void run(bool update) {
        installing = update;
        install->setEnabled(false);
        close->setEnabled(!update);
        progress->show();
        status->setText(update ? tr("Update wird heruntergeladen, geprüft und installiert …",
                                   "Downloading, verifying and installing update …")
                               : tr("GitHub-Releases werden geprüft …", "Checking GitHub releases …"));
        QStringList arguments{directory.filePath("update.py"), "--current", MUCKE_VERSION};
        if (update)
            arguments << "--install-version" << version << "--executable" << QCoreApplication::applicationFilePath();
        process.start(QStandardPaths::findExecutable("python3"), arguments);
        deadline.start(update ? 180000 : 30000);
    }
  public:
    UpdateDialog(QWidget *parent, bool silent) : QDialog(parent), quiet(silent) {
        setAttribute(Qt::WA_DeleteOnClose);
        setObjectName("updateDialog");
        setWindowTitle(tr("Softwareupdate", "Software update"));
        resize(480, 220);
        auto *layout = new QVBoxLayout(this);
        auto *heading = new QLabel(tr("Updates über GitHub", "Updates via GitHub"));
        auto font = heading->font(); font.setBold(true); heading->setFont(font);
        layout->addWidget(heading);
        status = new QLabel; status->setTextFormat(Qt::PlainText); status->setWordWrap(true);
        status->setObjectName("updateStatus");
        layout->addWidget(status, 1);
        progress = new QProgressBar; progress->setRange(0, 0); layout->addWidget(progress);
        auto *hint = new QLabel(tr("Installiert erst nach deinem Klick. Die laufende Wiedergabe bleibt erhalten; "
                                   "das Update gilt ab dem nächsten Appstart.",
                                   "Installs only after you click. Playback continues; the update takes effect "
                                   "the next time the app starts."));
        hint->setWordWrap(true); layout->addWidget(hint);
        auto *buttons = new QDialogButtonBox;
        install = buttons->addButton(tr("Jetzt installieren", "Install now"), QDialogButtonBox::ActionRole);
        install->setObjectName("installUpdate");
        install->setEnabled(false);
        close = buttons->addButton(QDialogButtonBox::Close);
        close->setText(tr("Schließen", "Close"));
        layout->addWidget(buttons);
        QObject::connect(close, &QPushButton::clicked, this, &QDialog::reject);
        QObject::connect(install, &QPushButton::clicked, this, [this] { quiet = false; run(true); });
        deadline.setSingleShot(true);
        QObject::connect(&deadline, &QTimer::timeout, this, [this] {
            process.terminate();
            status->setText(tr("Zeitlimit beim Update erreicht.", "Update timed out."));
        });
        QObject::connect(&process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart)
                failed(tr("Python 3 konnte nicht gestartet werden.", "Could not start Python 3."));
        });
        QObject::connect(&process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
                         [this](int code, QProcess::ExitStatus exit) {
            deadline.stop(); progress->hide(); close->setEnabled(true);
            const auto result = QJsonDocument::fromJson(process.readAllStandardOutput()).object();
            if (code != 0 || exit != QProcess::NormalExit || result.isEmpty()) {
                const auto detail = result["error"].toString();
                failed(tr("Update fehlgeschlagen. Die bisherige Installation bleibt erhalten.",
                          "Update failed. The existing installation is kept.") + "\n" + detail);
                return;
            }
            if (installing) {
                if (!result["installed"].toBool() || result["version"].toString() != version) {
                    failed(tr("Das Update wurde nicht bestätigt. Bitte erneut prüfen.", "The update was not confirmed. Please check again."));
                    return;
                }
                status->setText(tr("Version %1 wurde installiert. Bitte die App vollständig beenden und neu öffnen.",
                                   "Version %1 was installed. Please quit and reopen the app.").arg(result["version"].toString()));
                return;
            }
            if (!result["available"].toBool()) {
                status->setText(tr("Version %1 ist aktuell. Kein neueres Linux-Paket verfügbar.",
                                   "Version %1 is up to date. No newer Linux package is available.").arg(MUCKE_VERSION));
                if (quiet) deleteLater();
                return;
            }
            version = result["version"].toString();
            status->setText(tr("Version %1 ist verfügbar (installiert: %2).", "Version %1 is available (installed: %2).")
                                .arg(version, MUCKE_VERSION));
            install->setEnabled(true);
            if (quiet) { quiet = false; show(); }
        });
        if (!directory.isValid() || QStandardPaths::findExecutable("python3").isEmpty() ||
            !QFile::copy(":/updater/update.py", directory.filePath("update.py")) ||
            !QFile::copy(":/updater/install.py", directory.filePath("install.py"))) {
            failed(tr("Updatehelfer nicht verfügbar; Python 3 wird benötigt.",
                      "Update helper unavailable; Python 3 is required."));
            return;
        }
        QTimer::singleShot(0, this, [this] { run(false); });
    }
    ~UpdateDialog() override {
        if (process.state() != QProcess::NotRunning) {
            process.terminate();
            if (!process.waitForFinished(5000)) { process.kill(); process.waitForFinished(1000); }
        }
    }
    void reject() override {
        if (installing && process.state() != QProcess::NotRunning) return;
        QDialog::reject();
    }
};
}
void checkForUpdates(QWidget *parent, bool quiet) {
    if (auto *existing = parent->findChild<QDialog *>("updateDialog")) {
        if (!quiet) existing->show();
        return;
    }
    auto *dialog = new UpdateDialog(parent, quiet);
    if (!quiet) dialog->show();
}
}
