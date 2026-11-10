#pragma once
#include "../types.h"
#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QObject>
#include <QVariantMap>
namespace Mucke {
class MediaEngine;
class LibraryStore;
class MainWindow;
class MprisBridge : public QObject {
    Q_OBJECT
public:
    MprisBridge(MediaEngine*, LibraryStore*, MainWindow*, QObject *parent = nullptr);
    MediaEngine *engine;
    LibraryStore *store;
    MainWindow *window;
    PlaybackSnapshot current;
    QString serviceName;
    void stepStation(int direction);
    void play();
    QVariantMap metadata() const;
private:
    void announce();
    QVariantMap announcedProperties;
};
class MprisRoot : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(bool CanQuit READ canQuit CONSTANT)
    Q_PROPERTY(bool CanRaise READ canRaise CONSTANT)
    Q_PROPERTY(bool HasTrackList READ hasTrackList CONSTANT)
    Q_PROPERTY(QString Identity READ identity CONSTANT)
    Q_PROPERTY(QString DesktopEntry READ desktopEntry CONSTANT)
    Q_PROPERTY(QStringList SupportedUriSchemes READ schemes CONSTANT)
    Q_PROPERTY(QStringList SupportedMimeTypes READ mimeTypes CONSTANT)
public:
    explicit MprisRoot(MprisBridge*);
    bool canQuit() const { return true; }
    bool canRaise() const;
    bool hasTrackList() const { return false; }
    QString identity() const { return QStringLiteral("Mucke, Baby!"); }
    QString desktopEntry() const { return QStringLiteral("de.danielmuller.muckebaby"); }
    QStringList schemes() const { return {QStringLiteral("http"), QStringLiteral("https")}; }
    QStringList mimeTypes() const { return {}; }
public slots:
    void Raise();
    void Quit();
private:
    MprisBridge *bridge;
};
class MprisPlayer : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString PlaybackStatus READ playbackStatus)
    Q_PROPERTY(QString LoopStatus READ loopStatus WRITE setLoopStatus)
    Q_PROPERTY(double Rate READ rate WRITE setRate)
    Q_PROPERTY(bool Shuffle READ shuffle WRITE setShuffle)
    Q_PROPERTY(QVariantMap Metadata READ metadata)
    Q_PROPERTY(double Volume READ volume WRITE setVolume)
    Q_PROPERTY(qlonglong Position READ position)
    Q_PROPERTY(double MinimumRate READ rate CONSTANT)
    Q_PROPERTY(double MaximumRate READ rate CONSTANT)
    Q_PROPERTY(bool CanGoNext READ canStep)
    Q_PROPERTY(bool CanGoPrevious READ canStep)
    Q_PROPERTY(bool CanPlay READ canPlay)
    Q_PROPERTY(bool CanPause READ canPause)
    Q_PROPERTY(bool CanSeek READ canSeek)
    Q_PROPERTY(bool CanControl READ canControl CONSTANT)
public:
    explicit MprisPlayer(MprisBridge*);
    QString playbackStatus() const;
    QString loopStatus() const { return QStringLiteral("None"); }
    void setLoopStatus(const QString&) {}
    double rate() const { return 1.0; }
    void setRate(double) {}
    bool shuffle() const { return false; }
    void setShuffle(bool) {}
    QVariantMap metadata() const;
    double volume() const;
    void setVolume(double);
    qlonglong position() const;
    bool canStep() const;
    bool canPlay() const;
    bool canPause() const;
    bool canSeek() const;
    bool canControl() const { return true; }
public slots:
    void Next();
    void Previous();
    void Pause();
    void PlayPause();
    void Stop();
    void Play();
    void Seek(qlonglong offset);
    void SetPosition(QDBusObjectPath trackID, qlonglong position);
    void OpenUri(QString uri);
signals:
    void Seeked(qlonglong position);
private:
    MprisBridge *bridge;
};
}
