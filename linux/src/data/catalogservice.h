#pragma once
#include "../types.h"
#include <QJsonObject>
#include <QObject>
#include <memory>
namespace Mucke {
class CatalogService : public QObject {
    Q_OBJECT
public:
    explicit CatalogService(QString cacheDirectory, QObject *parent = nullptr);
    ~CatalogService() override;
    void search(QJsonObject filters, int page = 0);
    void cancel();
    void lookupStation(QString radioBrowserID);
signals:
    void results(QVector<Mucke::Station>, bool hasMore, QDateTime cachedAt);
    void repairCandidate(QString radioBrowserID, QString proposedURL);
    void error(QString);
private:
    class Impl;
    std::unique_ptr<Impl> d;
};
}
