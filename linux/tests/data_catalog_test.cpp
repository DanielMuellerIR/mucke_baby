#include "../src/data/catalogservice.h"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QTextStream>
#include <QUrlQuery>
#include <QEventLoop>
#include <QTimer>
using namespace Mucke;
namespace {
int checks = 0;
void check(bool value, const char *why) {
    ++checks;
    if (!value)
        throw std::runtime_error(why);
}
void write(const QString &path, const QByteArray &bytes) {
    QFile file(path);
    check(file.open(QIODevice::WriteOnly), "cache fixture open");
    check(file.write(bytes) == bytes.size(), "cache fixture write");
}
} // namespace
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        QTemporaryDir directory;
        CatalogService service(directory.path());
        int errors = 0, responses = 0;
        QVector<Station> stations;
        bool more = true;
        QDateTime cachedAt;
        QObject::connect(&service, &CatalogService::error, [&](QString) { ++errors; });
        QObject::connect(&service, &CatalogService::results,
                         [&](QVector<Station> found, bool hasMore, QDateTime at) {
                             ++responses;
                             stations = found;
                             more = hasMore;
                             cachedAt = at;
                         });
        service.search({}, 20);
        check(errors == 1, "page limit");
        service.search({{"bitrateMin", -1}});
        check(errors == 2, "bitrate limit");
        service.search({{"order", "untrusted"}});
        check(errors == 3, "order whitelist");
        service.lookupStation("not-a-uuid");
        check(errors == 4, "lookup UUID policy");
        QUrlQuery query;
        query.addQueryItem("limit", "50");
        query.addQueryItem("offset", "0");
        query.addQueryItem("hidebroken", "true");
        query.addQueryItem("order", "name");
        query.addQueryItem("reverse", "false");
        const auto key = QString::fromLatin1(
            QCryptographicHash::hash(query.toString(QUrl::FullyEncoded).toUtf8(), QCryptographicHash::Sha256)
                .toHex());
        const auto path = directory.filePath(key + ".json");
        Json list = Json::array({{{"stationuuid", "11111111-1111-4111-8111-111111111111"},
                                  {"name", "Example Radio"},
                                  {"url_resolved", "https://radio.example/Stream"},
                                  {"url", "https://radio.example/playlist.m3u"}},
                                 {{"stationuuid", "22222222-2222-4222-8222-222222222222"},
                                  {"name", "Unsafe"},
                                  {"url", "https://user:pass@radio.example/secret"}},
                                 {{"stationuuid", "33333333-3333-4333-8333-333333333333"},
                                  {"name", "Local file"},
                                  {"url", "file:///etc/passwd"}}});
        write(path, QByteArray::fromStdString(list.dump()));
        service.search({});
        service.cancel();
        check(responses == 1, "cached result emitted");
        check(stations.size() == 1 && stations[0].name == "Example Radio",
              "untrusted catalog entries filtered");
        check(stations[0].radioBrowserID == "11111111-1111-4111-8111-111111111111",
              "portable catalog identity");
        check(!more && cachedAt.isValid(), "cache age and end-of-page");
        write(path, QByteArray(2 * 1024 * 1024 + 1, ' '));
        service.search({});
        service.cancel();
        check(responses == 1, "oversized cache ignored");
        QEventLoop loop;
        QTimer::singleShot(100, &loop, &QEventLoop::quit);
        loop.exec();
        check(responses == 1 && errors == 4, "cancelled requests publish no stale result");
        if (qEnvironmentVariableIsSet("MUCKE_LIVE_CATALOG_TEST")) {
            QEventLoop live;
            QObject::connect(&service, &CatalogService::results, &live, &QEventLoop::quit);
            QObject::connect(&service, &CatalogService::error, &live, &QEventLoop::quit);
            QTimer::singleShot(45000, &live, &QEventLoop::quit);
            service.search({{"name", "Radio"}, {"countrycode", "DE"}, {"bitrateMin", 64}, {"codec", "MP3"}});
            live.exec();
            check(responses > 1 && !stations.isEmpty(), "live TLS catalog search");
            service.cancel();
        }
        QTextStream(stdout) << checks << " catalog checks passed\n";
        return 0;
    } catch (const std::exception &e) {
        QTextStream(stderr) << "Failed after " << checks << " checks: " << e.what() << '\n';
        return 1;
    }
}
