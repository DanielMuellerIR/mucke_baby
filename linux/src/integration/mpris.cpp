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
    if (!serviceName.isEmpty()) bus.registerObject(QStringLiteral("/org/mpris/MediaPlayer2"), this, QDBusConnection::ExportAdaptors);
    connect(e, &MediaEngine::snapshotChanged, this, [this](const PlaybackSnapshot &next) {
        current = next;
        announce();
    });
    connect(s, &LibraryStore::libraryChanged, this, &MprisBridge::announce);
}
void MprisBridge::stepStation(int direction) {
    QVector<Station> enabled;
    for (const auto &station : store->stations()) if (station.enabled && validStreamURL(station.url)) enabled.append(station);
    if (enabled.isEmpty()) return;
    int index = -1;
    for (int i = 0; i < enabled.size(); ++i) if (enabled[i].id == current.stationID) index = i;
    const int target = index < 0 ? (direction > 0 ? 0 : enabled.size()-1) : (index + direction + enabled.size()) % enabled.size();
    engine->play(enabled[target]);
}
void MprisBridge::play() {
    if (current.state == PlaybackState::Paused) { engine->togglePause(); return; }
    if (current.state == PlaybackState::Playing || current.state == PlaybackState::Buffering || current.state == PlaybackState::Resolving) return;
    const auto selected = store->station(current.stationID);
    if (!selected.id.isEmpty() && selected.enabled) { engine->play(selected); return; }
    stepStation(1);
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
    int enabledStations = 0;
    for (const auto &station : store->stations()) if (station.enabled) ++enabledStations;
    QVariantMap properties{{QStringLiteral("PlaybackStatus"),state}, {QStringLiteral("Metadata"),metadata()},
        {QStringLiteral("CanPlay"),enabledStations > 0}, {QStringLiteral("CanGoNext"),enabledStations > 1},
        {QStringLiteral("CanGoPrevious"),enabledStations > 1},
        {QStringLiteral("Volume"),current.volume/100.0}, {QStringLiteral("CanPause"),current.timeshiftAvailable || (current.previewActive && (current.state == PlaybackState::Playing || current.state == PlaybackState::Paused))},
        {QStringLiteral("CanSeek"),current.timeshiftAvailable}};
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
bool MprisPlayer::canStep() const { int count=0; for (const auto &s:bridge->store->stations()) if(s.enabled) ++count; return count>1; }
bool MprisPlayer::canPlay() const { for (const auto &s:bridge->store->stations()) if(s.enabled) return true; return false; }
bool MprisPlayer::canPause() const { return bridge->current.timeshiftAvailable || (bridge->current.previewActive && (bridge->current.state == PlaybackState::Playing || bridge->current.state == PlaybackState::Paused)); }
bool MprisPlayer::canSeek() const { return bridge->current.timeshiftAvailable; }
void MprisPlayer::Next() { bridge->stepStation(1); }
void MprisPlayer::Previous() { bridge->stepStation(-1); }
void MprisPlayer::Pause() { if (canPause() && bridge->current.state == PlaybackState::Playing) bridge->engine->togglePause(); }
void MprisPlayer::PlayPause() { if (bridge->current.state == PlaybackState::Playing || bridge->current.state == PlaybackState::Paused) bridge->engine->togglePause(); else bridge->play(); }
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
