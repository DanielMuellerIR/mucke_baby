#include "types.h"
#include <QUrl>
#include <QObject>
#include <QUuid>
namespace Mucke {
QString newID() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
bool validStreamURL(const QString &text, QString *reason) {
    const QUrl url(text.trimmed(), QUrl::StrictMode);
    const bool valid = url.isValid() &&
                       (url.scheme().compare("http", Qt::CaseInsensitive) == 0 ||
                        url.scheme().compare("https", Qt::CaseInsensitive) == 0) &&
                       !url.host().isEmpty() && url.userInfo().isEmpty() &&
                       !url.authority(QUrl::FullyEncoded).contains('@') && url.port(1) > 0 &&
                       url.port(1) <= 65535;
    if (!valid && reason)
        *reason = QObject::tr("A valid HTTP(S) stream URL without credentials is required.");
    return valid;
}
QString normalizedStreamURL(const QString &text) {
    if (!validStreamURL(text))
        return {};
    QUrl url(text.trimmed(), QUrl::StrictMode);
    url.setScheme(url.scheme().toLower());
    url.setHost(url.host().toLower());
    if ((url.scheme() == "http" && url.port() == 80) || (url.scheme() == "https" && url.port() == 443))
        url.setPort(-1);
    if (url.path().isEmpty())
        url.setPath("/");
    return url.toString(QUrl::FullyEncoded);
}
} // namespace Mucke
