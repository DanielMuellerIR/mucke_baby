#pragma once
#include "../types.h"
#include <QJsonObject>
#include <QObject>
#include <memory>
namespace Mucke {
class LibraryStore : public QObject {
    Q_OBJECT
public:
    explicit LibraryStore(QString dataDirectory, QObject *parent = nullptr);
    ~LibraryStore() override;
    bool load();
    QString dataDirectory() const;
    QString lastError() const;
    QVector<Station> stations() const;
    QVector<Group> groups() const;
    QVector<Track> history() const;
    QVector<Track> bookmarks() const;
    Station station(QString id) const;
    QJsonObject settings() const;
    bool saveStation(Station);
    bool removeStation(QString id);
    bool setStationOrder(QStringList ids);
    bool saveGroup(Group);
    bool removeGroup(QString id);
    bool saveSettings(QJsonObject);
    bool bookmark(Track);
    bool removeBookmark(QString id);
    bool clearHistory();
    QJsonObject previewImport(QString path);
    void discardImport(QJsonObject preview);
    bool applyImport(QJsonObject preview, QJsonObject choices);
    bool exportLibrary(QString path);
    bool exportBookmarks(QString path, bool csv, const QStringList *selection = nullptr);
public slots:
    void receiveTrack(Mucke::Track);
    void endReception(QDateTime);
signals:
    void libraryChanged();
    void historyChanged();
    void bookmarksChanged();
    void settingsChanged();
    void error(QString);
private:
    class Impl;
    std::unique_ptr<Impl> d;
};
}
