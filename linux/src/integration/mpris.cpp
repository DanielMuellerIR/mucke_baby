#include "mpris.h"
#include "../data/librarystore.h"
#include "../media/mediaengine.h"
#include "../ui/mainwindow.h"
#include <QApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QUrl>
#include <algorithm>
#include <cmath>

namespace Mucke {
static QString trackPath(const PlaybackSnapshot &snapshot) {
    QString id = snapshot.heardTrack.id;
    if (id.isEmpty()) id = snapshot.stationID;
    id.replace('-', '_');
    if (id.isEmpty()) return QStringLiteral("/org/mpris/MediaPlayer2/TrackList/NoTrack");
    return QStringLiteral("/org/mpris/MediaPlayer2/track/") + id;
}
MprisBridge::MprisBridge(MediaEngine *e, LibraryStore *s, MainWindow *w, QObject *parent)
    : QObject(parent), engine(e), store(s), window(w), current(e->snapshot()) {
    new MprisRoot(this);
    auto *playerAdaptor = new MprisPlayer(this);
    connect(e, &MediaEngine::positionDiscontinuity, playerAdaptor, [playerAdaptor](double position) {
        emit playerAdaptor->Seeked(qlonglong(std::max(0.0, position)*1000000));
    });
    auto bus = QDBusConnection::sessionBus();
    serviceName = QStringLiteral("org.mpris.MediaPlayer2.muckebaby");
    if (!bus.registerService(serviceName)) {
        serviceName += QStringLiteral(".instance%1").arg(QCoreApplication::applicationPid());
        if (!bus.registerService(serviceName)) serviceName.clear();
    }
    if (!serviceName.isEmpty() && !bus.registerObject(QStringLiteral("/org/mpris/MediaPlayer2"), this, QDBusConnection::ExportAdaptors)) {
        bus.unregisterService(serviceName);
        serviceName.clear();
    }
    if (serviceName.isEmpty()) qWarning("MPRIS registration failed; desktop media controls are unavailable");
    connect(e, &MediaEngine::snapshotChanged, this, [this](const PlaybackSnapshot &next) {
        current = next;
        announce();
    });
    connect(s, &LibraryStore::libraryChanged, this, &MprisBridge::announce);
}
MprisBridge::~MprisBridge() {
    if (!serviceName.isEmpty()) QDBusConnection::sessionBus().unregisterService(serviceName);
}
void MprisBridge::play() {
    if (current.state == PlaybackState::Playing || current.state == PlaybackState::Buffering || current.state == PlaybackState::Resolving) return;
    if (!current.stationID.isEmpty() || current.state == PlaybackState::Paused) { engine->resume(); return; }
    for (const auto &station : store->stations()) {
        if (station.enabled && validStreamURL(station.url)) { engine->play(station); return; }
    }
}
void MprisBridge::playPause() {
    if (current.state == PlaybackState::Playing || current.state == PlaybackState::Buffering || current.state == PlaybackState::Resolving) engine->pauseOrStop();
    else play();
}
QVariantMap MprisBridge::metadata() const {
    QVariantMap result;
    result.insert(QStringLiteral("mpris:trackid"), QVariant::fromValue(QDBusObjectPath(trackPath(current))));
    result.insert(QStringLiteral("xesam:title"), current.heardTrack.title.isEmpty() ? current.heardTrack.raw : current.heardTrack.title);
    if (!current.heardTrack.artist.isEmpty()) result.insert(QStringLiteral("xesam:artist"), QStringList{current.heardTrack.artist});
    result.insert(QStringLiteral("xesam:album"), current.stationName);
    return result;
}
void MprisBridge::announce() {
    if (serviceName.isEmpty()) return;
    QString state = QStringLiteral("Stopped");
    if (current.state == PlaybackState::Paused) state = QStringLiteral("Paused");
    else if (current.state == PlaybackState::Playing || current.state == PlaybackState::Buffering || current.state == PlaybackState::Resolving) state = QStringLiteral("Playing");
    const auto *player = findChild<MprisPlayer*>();
    QVariantMap properties{{QStringLiteral("PlaybackStatus"),state}, {QStringLiteral("Metadata"),metadata()},
        {QStringLiteral("CanPlay"),player->canPlay()}, {QStringLiteral("CanGoNext"),player->canStep()},
        {QStringLiteral("CanGoPrevious"),player->canStep()},
        {QStringLiteral("Volume"),current.volume/100.0}, {QStringLiteral("CanPause"),player->canPause()},
        {QStringLiteral("CanSeek"),player->canSeek()}};
    if (properties == announcedProperties) return;
    announcedProperties = properties;
    auto message = QDBusMessage::createSignal(QStringLiteral("/org/mpris/MediaPlayer2"), QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("PropertiesChanged"));
    message << QStringLiteral("org.mpris.MediaPlayer2.Player") << properties << QStringList{};
    QDBusConnection::sessionBus().send(message);
}
MprisRoot::MprisRoot(MprisBridge *b) : QDBusAbstractAdaptor(b), bridge(b) {}
bool MprisRoot::canRaise() const { return bridge->window; }
void MprisRoot::Raise() { if (bridge->window) { bridge->window->showNormal(); bridge->window->raise(); bridge->window->activateWindow(); } }
void MprisRoot::Quit() { QApplication::quit(); }
MprisPlayer::MprisPlayer(MprisBridge *b) : QDBusAbstractAdaptor(b), bridge(b) {}
QString MprisPlayer::playbackStatus() const {
    switch (bridge->current.state) {
    case PlaybackState::Playing: case PlaybackState::Buffering: case PlaybackState::Resolving: return QStringLiteral("Playing");
    case PlaybackState::Paused: return QStringLiteral("Paused");
    default: return QStringLiteral("Stopped");
    }
}
QVariantMap MprisPlayer::metadata() const { return bridge->metadata(); }
double MprisPlayer::volume() const { return bridge->current.volume/100.0; }
void MprisPlayer::setVolume(double value) { if (std::isfinite(value)) bridge->engine->setVolume(qRound(std::clamp(value,0.0,1.0)*100)); }
qlonglong MprisPlayer::position() const { return qlonglong(std::max(0.0, bridge->current.bufferSeconds-bridge->current.delaySeconds)*1000000); }
bool MprisPlayer::canPlay() const {
    if (!bridge->current.stationID.isEmpty() || bridge->current.previewActive) return true;
    for (const auto &s:bridge->store->stations()) if(s.enabled && validStreamURL(s.url)) return true;
    return false;
}
bool MprisPlayer::canPause() const { return canPlay(); }
bool MprisPlayer::canSeek() const { return bridge->current.timeshiftAvailable; }
void MprisPlayer::Next() {}
void MprisPlayer::Previous() {}
void MprisPlayer::Pause() { if (canPause()) bridge->engine->pauseOrStop(); }
void MprisPlayer::PlayPause() { bridge->playPause(); }
void MprisPlayer::Stop() { bridge->engine->stop(); }
void MprisPlayer::Play() { bridge->play(); }
void MprisPlayer::Seek(qlonglong offset) {
    if (!canSeek()) return;
    bridge->engine->seekDelay(std::max(0.0,bridge->current.delaySeconds-offset/1000000.0));
}
void MprisPlayer::SetPosition(QDBusObjectPath id, qlonglong requested) {
    if (!canSeek() || id.path()!=trackPath(bridge->current) || requested<0) return;
    bridge->engine->seekDelay(std::max(0.0,bridge->current.bufferSeconds-requested/1000000.0));
}
void MprisPlayer::OpenUri(QString uri) {
    if (!validStreamURL(uri)) return;
    bridge->engine->play(Station{newID(),QUrl(uri).host(),uri,QString(),true,false});
}
}
