#include "catalogservice.h"
#include "../buildinfo.h"
#include "codec_p.h"
#include "messages_p.h"
#include <QCryptographicHash>
#include <QDir>
#include <QDnsLookup>
#include <QFileInfo>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QRandomGenerator>
#include <QSaveFile>
#include <QTimer>
#include <QUrlQuery>
#include <algorithm>
using namespace Mucke::DataCodec;
namespace Mucke {
namespace {
constexpr int responseLimit = 2 * 1024 * 1024;
QVector<Station> parseResults(const QByteArray &bytes, bool *fullPage = nullptr) {
    const auto j = Json::parse(bytes.constData(), bytes.constData() + bytes.size());
    require(j.is_array() && j.size() <= 50, "Invalid catalog response.");
    if (fullPage) *fullPage = j.size() == 50;
    QVector<Station> result;
    QSet<QString> seen;
    for (const auto &v : j) {
        try {
            Station s;
            s.radioBrowserID = uuid(requiredString(v, "stationuuid"));
            if (seen.contains(s.radioBrowserID))
                continue;
            s.id = s.radioBrowserID;
            s.name = requiredString(v, "name").trimmed();
            s.url = optionalString(v, "url_resolved");
            if (!validStreamURL(s.url))
                s.url = requiredString(v, "url");
            require(textValid(s.name, 256, true, false) && s.url.toUtf8().size() <= 4096 &&
                    validStreamURL(s.url));
            s.url = normalizedStreamURL(s.url);
            seen.insert(s.radioBrowserID);
            result.append(s);
        } catch (const std::exception &) {
        }
    }
    return result;
}
} // namespace
class CatalogService::Impl {
  public:
    CatalogService *q;
    QString cacheDir;
    QNetworkAccessManager network;
    QPointer<QNetworkReply> reply;
    QDnsLookup dns;
    quint64 generation = 0;
    QStringList servers;
    bool resolving = false;
    std::function<void()> pending;
    Impl(CatalogService *q, QString directory) : q(q), cacheDir(std::move(directory)), network(q), dns(q) {
        QObject::connect(&dns, &QDnsLookup::finished, q, [this] {
            resolving = false;
            for (const auto &r : dns.serviceRecords()) {
                QString name = r.target().toLower();
                if (name.endsWith('.'))
                    name.chop(1);
                if (name.endsWith(".api.radio-browser.info") && !servers.contains(name))
                    servers.append(name);
            }
            if (servers.isEmpty())
                servers = {"de1.api.radio-browser.info", "de2.api.radio-browser.info",
                           "nl1.api.radio-browser.info"};
            std::shuffle(servers.begin(), servers.end(), *QRandomGenerator::global());
            if (pending) {
                auto action = std::move(pending);
                pending = {};
                action();
            }
        });
    }
    void stop() {
        ++generation;
        pending = {};
        if (reply) {
            auto old = reply;
            reply = nullptr;
            old->abort();
            old->deleteLater();
        }
    }
    void withServers(std::function<void()> action) {
        if (!servers.isEmpty()) {
            action();
            return;
        }
        pending = std::move(action);
        if (resolving)
            return;
        resolving = true;
        dns.setType(QDnsLookup::SRV);
        dns.setName("_api._tcp.radio-browser.info");
        dns.lookup();
        QTimer::singleShot(4000, q, [this] {
            if (resolving) {
                dns.abort();
            }
        });
    }
    QString cachePath(QString key) const { return QDir(cacheDir).filePath(key + ".json"); }
    void writeCache(QString key, QByteArray data) {
        if (data.size() > responseLimit)
            return;
        QDir directory(cacheDir);
        if (!directory.mkpath("."))
            return;
        QSaveFile f(cachePath(key));
        if (!f.open(QIODevice::WriteOnly) || f.write(data) != data.size() || !f.commit())
            return;
        auto files =
            directory.entryInfoList({"*.json"}, QDir::Files | QDir::NoSymLinks, QDir::Time | QDir::Reversed);
        qint64 total = 0;
        for (const auto &i : files)
            total += i.size();
        for (const auto &i : files) {
            if (total <= responseLimit)
                break;
            if (QFile::remove(i.absoluteFilePath()))
                total -= i.size();
        }
    }
    QByteArray cache(QString key, QDateTime &at) {
        QFileInfo info(cachePath(key));
        if (!info.isFile() || info.isSymLink() || info.size() > responseLimit)
            return {};
        QFile f(info.absoluteFilePath());
        if (!f.open(QIODevice::ReadOnly))
            return {};
        auto b = f.read(responseLimit + 1);
        if (b.size() > responseLimit)
            return {};
        at = info.lastModified();
        return b;
    }
    void request(QString path, QUrlQuery query, quint64 requestGeneration,
                 std::function<void(QByteArray)> success, int serverIndex = 0) {
        if (requestGeneration != generation)
            return;
        if (serverIndex >= qMin(servers.size(), 3)) {
            emit q->error(localizedDataMessage(
                QObject::tr("The station catalog could not be reached. Please try again later.")));
            return;
        }
        QUrl url;
        url.setScheme("https");
        url.setHost(servers[serverIndex]);
        url.setPath(path);
        url.setQuery(query);
        QNetworkRequest request(url);
        request.setRawHeader("User-Agent", "MuckeBaby/" MUCKE_VERSION);
        request.setRawHeader("Accept", "application/json");
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
        request.setTransferTimeout(12000);
        auto *r = network.get(request);
        reply = r;
        auto buffer = std::make_shared<QByteArray>();
        auto tooLarge = std::make_shared<bool>(false);
        QObject::connect(r, &QIODevice::readyRead, q, [r, buffer, tooLarge] {
            buffer->append(r->readAll());
            if (buffer->size() > responseLimit) {
                *tooLarge = true;
                r->abort();
            }
        });
        QObject::connect(r, &QNetworkReply::metaDataChanged, q, [r, tooLarge] {
            if (r->header(QNetworkRequest::ContentLengthHeader).toLongLong() > responseLimit) {
                *tooLarge = true;
                r->abort();
            }
        });
        QObject::connect(
            r, &QNetworkReply::finished, q,
            [this, r, buffer, tooLarge, path, query, requestGeneration, success, serverIndex] {
                r->deleteLater();
                if (reply == r)
                    reply = nullptr;
                if (requestGeneration != generation)
                    return;
                buffer->append(r->readAll());
                if (*tooLarge || buffer->size() > responseLimit) {
                    emit q->error(
                        localizedDataMessage(QObject::tr("The station catalog response exceeds 2 MiB.")));
                    return;
                }
                const auto status = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                if (r->error() != QNetworkReply::NoError || status != 200) {
                    this->request(path, query, requestGeneration, success, serverIndex + 1);
                    return;
                }
                try {
                    success(*buffer);
                } catch (const std::exception &) {
                    emit q->error(
                        localizedDataMessage(QObject::tr("The station catalog returned invalid data.")));
                }
            });
    }
};
CatalogService::CatalogService(QString directory, QObject *parent)
    : QObject(parent), d(std::make_unique<Impl>(this, std::move(directory))) {}
CatalogService::~CatalogService() {
    d->stop();
    d->dns.abort();
}
void CatalogService::cancel() { d->stop(); }
void CatalogService::search(QJsonObject filters, int page) {
    d->stop();
    const auto generation = d->generation;
    if (page < 0 || page >= 20) {
        emit error(localizedDataMessage(tr("The catalog is limited to 20 pages of 50 stations.")));
        return;
    }
    QUrlQuery query;
    query.addQueryItem("limit", "50");
    query.addQueryItem("offset", QString::number(page * 50));
    query.addQueryItem("hidebroken", "true");
    for (const auto &key : {"name", "language", "tag", "codec"}) {
        const auto v = filters.value(key).toString().trimmed();
        if (!v.isEmpty()) {
            if (!textValid(v, 256, true, false)) {
                emit error(localizedDataMessage(tr("The search filter is too long or invalid.")));
                return;
            }
            query.addQueryItem(key, v);
        }
    }
    auto country = filters.value("countrycode").toString(filters.value("country").toString()).trimmed();
    if (!country.isEmpty()) {
        if (country.size() == 2)
            query.addQueryItem("countrycode", country.toUpper());
        else
            query.addQueryItem("country", country.left(256));
    }
    for (const auto &key : {"bitrateMin", "bitrateMax"})
        if (filters.contains(key)) {
            const int v = filters.value(key).toInt(-1);
            if (v < 0 || v > 1000000) {
                emit error(localizedDataMessage(tr("The bitrate filter is invalid.")));
                return;
            }
            query.addQueryItem(key, QString::number(v));
        }
    if (filters.contains("bitrate") && !filters.contains("bitrateMin")) {
        int v = filters.value("bitrate").toInt(-1);
        if (v < 0 || v > 1000000) {
            emit error(localizedDataMessage(tr("The bitrate filter is invalid.")));
            return;
        }
        query.addQueryItem("bitrateMin", QString::number(v));
    }
    const auto order = filters.value("order").toString("name");
    const QStringList orders = {"name",   "votes",   "clickcount", "clicktrend", "bitrate",
                                "random", "country", "language",   "codec",      "lastcheckok"};
    if (!orders.contains(order)) {
        emit error(localizedDataMessage(tr("The catalog sort order is invalid.")));
        return;
    }
    query.addQueryItem("order", order);
    query.addQueryItem("reverse", filters.value("reverse").toBool(false) ? "true" : "false");
    const auto key = QString::fromLatin1(
        QCryptographicHash::hash(query.toString(QUrl::FullyEncoded).toUtf8(), QCryptographicHash::Sha256)
            .toHex());
    QDateTime cachedAt;
    const auto cached = d->cache(key, cachedAt);
    if (!cached.isEmpty()) {
        try {
            bool fullPage = false;
            const auto list = parseResults(cached, &fullPage);
            emit results(list, fullPage && page < 19, cachedAt);
        } catch (const std::exception &) {
        }
    }
    d->withServers([this, generation, query, key, page] {
        d->request("/json/stations/search", query, generation, [this, key, page](QByteArray b) {
            bool fullPage = false;
            const auto list = parseResults(b, &fullPage);
            d->writeCache(key, b);
            emit results(list, fullPage && page < 19, QDateTime());
        });
    });
}
void CatalogService::lookupStation(QString id) {
    d->stop();
    const auto generation = d->generation;
    try {
        id = uuid(id);
    } catch (const std::exception &) {
        emit error(localizedDataMessage(tr("The station catalog ID is invalid.")));
        return;
    }
    d->withServers([this, generation, id] {
        d->request("/json/stations/byuuid/" + id, QUrlQuery(), generation, [this, id](QByteArray b) {
            const auto list = parseResults(b);
            for (const auto &s : list)
                if (s.radioBrowserID == id) {
                    emit repairCandidate(id, s.url);
                    return;
                }
            emit error(localizedDataMessage(tr("No replacement stream was found for this station.")));
        });
    });
}
} // namespace Mucke
