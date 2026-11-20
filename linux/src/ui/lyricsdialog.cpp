#include "lyricsdialog.h"
#include "dialogwidgets_p.h"
#include "songtools_p.h"
#include <QDesktopServices>
#include <QDialog>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPlainTextEdit>
#include <QPointer>
#include <QTimer>

namespace Mucke {
namespace {
using DialogWidgets::button;
using SongTools::trackName;

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
            state->setText(germanOrEnglish("Kein Songtext gefunden. Die Websuche kann weitere Quellen zeigen.",
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
                state->setText(germanOrEnglish("Quelle: lyrics.ovh", "Source: lyrics.ovh"));
            } else
                next();
        });
    }

  public:
    explicit LyricsDialog(const Track &track, QWidget *parent) : QDialog(parent) {
        setObjectName("lyricsDialog");
        setWindowTitle(germanOrEnglish("Songtext", "Lyrics"));
        resize(520, 590);
        auto *layout = new QVBoxLayout(this);
        auto *heading = new QLabel(trackName(track));
        heading->setTextFormat(Qt::PlainText);
        heading->setWordWrap(true);
        layout->addWidget(heading);
        state =
            new QLabel(germanOrEnglish("Songtext wird bei lyrics.ovh gesucht …", "Searching lyrics.ovh for lyrics …"));
        state->setWordWrap(true);
        layout->addWidget(state);
        lyrics = new QPlainTextEdit;
        lyrics->setReadOnly(true);
        layout->addWidget(lyrics, 1);
        auto *actions = new QHBoxLayout;
        layout->addLayout(actions);
        button(germanOrEnglish("Im Web suchen", "Search the web"), actions,
               [track] { QDesktopServices::openUrl(SongTools::lyricsSearchURL(track)); });
        button(germanOrEnglish("Schließen", "Close"), actions, [this] { reject(); });
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

void showLyricsDialog(const Track &track, QWidget *parent) {
    LyricsDialog dialog(track, parent);
    dialog.exec();
}
} // namespace Mucke
