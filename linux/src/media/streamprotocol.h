#pragma once
#include <QByteArray>
#include <QString>
#include <QUrl>
#include <functional>
namespace Mucke::MediaPrivate {
QString decodeText(const QByteArray &);
bool needsResolution(const QUrl &);
QUrl playlistTarget(const QByteArray &);
bool isHLS(const QString &contentType, const QUrl &);
QString safeExportName(QString);
class ICYParser {
public:
    explicit ICYParser(int interval = 0);
    void feed(const QByteArray &, const std::function<void(const QByteArray &)> &audio,
              const std::function<void(const QString &)> &title);
private:
    int interval, audioLeft, metadataLeft = -1;
    QByteArray metadata;
    QString lastTitle;
};
}
