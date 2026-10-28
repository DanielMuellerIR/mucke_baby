#include "mediaengine.h"
#include "radioprefetch.h"
#include "recorder.h"
#include "streamprotocol.h"
#include "pulsemonitor.h"
#include "timeshift.h"
#include "playbackhealth.h"
#include "../export/songrangeresolver.h"
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QFile>
#include <QElapsedTimer>
#include <QLocale>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QProcess>
#include <QQueue>
#include <QSet>
#include <QThread>
#include <QTemporaryDir>
#include <QTimer>
#include <QUuid>
#include <vlc/vlc.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <atomic>
#include <unistd.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <linux/fs.h>
#include <cerrno>
#include <cstdarg>
#include <optional>
#include <utility>
#include <sys/stat.h>
#if __has_include("version.h")
#include "version.h"
#endif
#ifndef MUCKE_VERSION
#define MUCKE_VERSION "development"
#endif
namespace Mucke {
namespace {
QString trMessage(const char *en, const char *de) { return QString::fromUtf8(QLocale().language() == QLocale::German ? de : en); }
QString uniqueID() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
QByteArray userAgent() { return QByteArray("MuckeBaby/") + MUCKE_VERSION; }
class EngineWorker : public QObject {
public:
    std::function<void(PlaybackSnapshot)> onSnapshot;
    std::function<void(QVector<Recording>)> onRecordings;
    std::function<void(Track)> onTrack;
    std::function<void(QDateTime)> onEnd;
    std::function<void(QString, QString, QString)> onExport;
    std::function<void(QVector<float>, QVector<float>, float)> onFrames;
    std::function<void(QString, QVector<SongExportProposal>)> onSongPrepared;
    std::function<void(QString, int, int)> onSongProgress;
    std::function<void(double)> onSeek;
    EngineWorker(QString directory, QString cache) : recorder(std::move(directory)), cacheDirectory(std::move(cache)) {}
    ~EngineWorker() override { teardown(); }
    PlaybackSnapshot state;
    void initialize() {
        engineClock.start();
        recorder.initialize();
        songResolver = new SongRangeResolver(recorder.directory(), this);
        connect(songResolver, &SongRangeResolver::prepared, this, [this](QString request, QVector<SongExportProposal> proposals) { if (onSongPrepared) onSongPrepared(request, proposals); });
        connect(songResolver, &SongRangeResolver::progress, this, [this](QString request, int finished, int total) { if (onSongProgress) onSongProgress(request, finished, total); });
        network = new QNetworkAccessManager(this);
        monitor = new MediaPrivate::PulseMonitor(this);
        monitor->status = [this](QString value) { state.visualizerStatus = value; publish(); };
        monitor->frames = [this](QVector<float> wave, QVector<float> spectrum, float rms) {
            const float amplitude = std::pow(effectiveVolume / 100.0f, 3.0f);
            const float scale = effectiveVolume == 0 ? 0 : std::min(1000000.0f, 1.0f / amplitude);
            for (float &value : wave) value = std::clamp(value * scale, -1.0f, 1.0f);
            for (float &value : spectrum) value = std::clamp(value * scale, 0.0f, 1.0f);
            if (onFrames) onFrames(wave, spectrum, std::clamp(rms * scale, 0.0f, 1.0f));
        };
        diskTimer = new QTimer(this); diskTimer->setInterval(15000);
        connect(diskTimer, &QTimer::timeout, this, [this] { recorder.checkDisk(); if (shiftBuffer) shiftBuffer->checkDisk(); publish(); }); diskTimer->start();
        positionTimer = new QTimer(this); positionTimer->setInterval(250);
        connect(positionTimer, &QTimer::timeout, this, [this] { updateTimeshift(); });
        healthTimer = new QTimer(this); healthTimer->setInterval(1000);
        connect(healthTimer, &QTimer::timeout, this, [this] { healthTick(); });
        sleepTimer = new QTimer(this); sleepTimer->setInterval(1000);
        connect(sleepTimer, &QTimer::timeout, this, [this] {
            if (!sleepDeadline.isValid()) return;
            state.sleepRemaining = remainingSleepTime();
            if (state.sleepRemaining == 0) { sleepDeadline = {}; sleepTimer->stop(); stop(); }
            else { applyVolume(); publish(); }
        });
        recorder.changed = [this] { if (onRecordings) onRecordings(recorder.list()); publish(); };
        const char *options[] = {"--ignore-config", "--no-video", "--no-xlib", "--no-osd", "--no-media-library", "--no-stats", "--no-metadata-network-access", "--network-caching=1000", "--no-plugins-cache", "--equalizer-2pass", "--no-equalizer-vlcfreqs"};
        instance = libvlc_new(int(sizeof(options) / sizeof(options[0])), options);
        // Native Diagnosezeilen können vollständige Stream-URLs enthalten; sichtbare Fehler kommen aus den Events.
        if (instance) libvlc_log_set(instance, [](void *, int, const libvlc_log_t *, const char *, va_list) {}, nullptr);
        if (instance) player = libvlc_media_player_new(instance);
        if (!player) state.error = trMessage("libVLC could not initialize", "libVLC konnte nicht initialisiert werden");
        state.visualizerStatus = trMessage("Visualizer unavailable: private application monitor is not connected", "Visualizer ruht: privater Anwendungsmonitor ist nicht verbunden");
        if (onRecordings) onRecordings(recorder.list());
        publish();
    }
    void publish() {
        state.recordActive = recorder.active(); state.recordStatus = recordOverride.isEmpty() ? recorder.status() : recordOverride;
        if (onSnapshot) onSnapshot(state);
    }
    void abortReply(QNetworkReply *&reply) { if (reply) { reply->disconnect(this); reply->abort(); reply->deleteLater(); reply = nullptr; } }
    void stopUnneededAudioReader() {
        if (!audioOnlyReader || state.recordRequested || shiftBuffer || pendingShiftStart || aacProbeStage != AACProbeStage::None || !reader) return;
        if (parsingAudio) {
            const quint64 current = receptionGeneration;
            QTimer::singleShot(0, this, [this, current] { if (current == receptionGeneration) stopUnneededAudioReader(); }); return;
        }
        abortReply(reader); parser.reset();
        if (receiving) { receiving = false; if (onEnd) onEnd(QDateTime::currentDateTimeUtc()); }
    }
    void closeReception() {
        aacProbeStage = AACProbeStage::None; pendingAAC.clear(); aacPrefix.clear(); aacExpectedRate = 0; bufferFormatPending = false;
        if (shiftReader) shiftReader->cancel();
        abortReply(resolver); abortReply(reader); parser.reset();
        if (shiftBuffer) shiftBuffer->endReception();
        if (receiving) { receiving = false; if (onEnd) onEnd(QDateTime::currentDateTimeUtc()); }
        recorder.finish();
    }
    void releasePlayer() {
        ++outputGeneration;
        discontinuityPending = false;
        if (shiftReader) shiftReader->cancel();
        if (!player || !hasOutputMedia) {
            shiftReader.reset(); outputFromBuffer = false; aacProbeDirectory.reset();
            if (player && systemSleeping) { libvlc_media_player_release(player); player = nullptr; }
            return;
        }
        if (eventContext) {
            auto manager = libvlc_media_player_event_manager(player);
            for (libvlc_event_e event : events) libvlc_event_detach(manager, event, &EngineWorker::vlcEvent, eventContext.get());
        }
        // libVLC stoppt ausschließlich hier auf dem seriellen Worker, nie im Callback oder UI-Thread.
        libvlc_media_player_stop(player);
        libvlc_media_player_set_media(player, nullptr);
        aacProbeDirectory.reset();
        shiftReader.reset(); outputFromBuffer = false;
        eventContext.reset();
        libvlc_media_player_release(player); player = nullptr; hasOutputMedia = false;
        if (!shutDown && !systemSleeping) player = libvlc_media_player_new(instance);
    }
    bool ensurePlayer() { if (!player && instance && !shutDown && !systemSleeping) player = libvlc_media_player_new(instance); return player != nullptr; }
    void stop(bool preserveWakeIntent = false) {
        if (!preserveWakeIntent) resumeAfterWake = false;
        playbackHealth.cancel(); if (healthTimer) healthTimer->stop();
        ++receptionGeneration; retryScheduled = false; closeReception();
        if (player) libvlc_audio_set_mute(player, 1);
        pendingShiftStart = false; outputExpired = false; pendingLiveJump = false; shiftStatus.clear();
        if (positionTimer) positionTimer->stop();
        if (monitor) monitor->setActive(false);
        state.state = PlaybackState::Stopped; state.previewActive = false; state.timeshiftPaused = false;
        stationPreview = false; recordOverride.clear(); recorder.setEnabled(state.recordRequested);
        state.timeshiftAvailable = false; state.delaySeconds = state.bufferSeconds = 0; state.heardTrack = {}; liveTrack = {}; state.error.clear(); publish();
        releasePlayer(); shiftBuffer.reset();
    }
    void play(Station value) {
        startStation(std::move(value), false);
    }
    void previewStation(Station value) {
        startStation(std::move(value), true);
    }
    void startStation(Station value, bool preview) {
        if (systemSleeping) {
            resumeAfterWake = false; station = std::move(value); state.stationID = station.id; state.stationName = station.name;
            state.error = trMessage("Playback stays stopped while the system sleeps", "Wiedergabe bleibt während des Systemschlafs gestoppt"); publish(); return;
        }
        stop(); stationPreview = preview; state.previewActive = preview; station = std::move(value); retryCount = 0;
        if (preview) recordOverride = trMessage("Station preview: recording and history are off", "Sendervorschau: Aufnahme und Verlauf sind aus");
        state.stationID = station.id; state.stationName = station.name;
        if (!ensurePlayer() || !validStreamURL(station.url)) { fail(trMessage("Invalid or unsupported stream URL", "Ungültige oder nicht unterstützte Stream-URL")); return; }
        station.url = normalizedStreamURL(station.url);
        sessionID = uniqueID(); state.state = PlaybackState::Resolving; state.error.clear(); publish(); resolve(QUrl(station.url), 0);
    }
    void fail(QString error) { playbackHealth.cancel(); if (healthTimer) healthTimer->stop(); closeReception(); releasePlayer(); shiftBuffer.reset(); pendingShiftStart = false; state.state = PlaybackState::Error; state.error = std::move(error); publish(); }
    void resolve(QUrl url, int depth) {
        if (depth > 3 || !validStreamURL(url.toString())) { fail(trMessage("Playlist has no safe stream target", "Playlist enthält kein sicheres Stream-Ziel")); return; }
        if (!MediaPrivate::needsResolution(url)) { beginStream(url); return; }
        QNetworkRequest request(url); request.setTransferTimeout(8000);
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        request.setMaximumRedirectsAllowed(5); request.setRawHeader("Range", "bytes=0-65535"); request.setRawHeader("User-Agent", userAgent());
        resolver = network->get(request); resolver->setReadBufferSize(65536);
        auto bytes = std::make_shared<QByteArray>(); const quint64 current = receptionGeneration; QNetworkReply *reply = resolver;
        connect(reply, &QNetworkReply::readyRead, this, [this, reply, bytes, current] {
            if (current != receptionGeneration || reply != resolver) return;
            bytes->append(reply->read(65536 - bytes->size()));
            if (bytes->size() >= 65536) reply->abort();
        });
        connect(reply, &QNetworkReply::finished, this, [this, reply, bytes, current, depth] {
            if (current != receptionGeneration || reply != resolver) return;
            bytes->append(reply->read(65536 - bytes->size()));
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            resolver = nullptr; reply->deleteLater();
            if (status < 200 || status >= 300) { fail(trMessage("Playlist download failed", "Playlist konnte nicht geladen werden")); return; }
            const QUrl next = MediaPrivate::playlistTarget(*bytes);
            if (next.isEmpty()) { fail(trMessage("Playlist has no safe stream target", "Playlist enthält kein sicheres Stream-Ziel")); return; }
            resolve(next, depth + 1);
        });
    }
    struct EventContext { EngineWorker *worker; quint64 outputGeneration; };
    static void vlcEvent(const libvlc_event_t *event, void *opaque) {
        auto *context = static_cast<EventContext *>(opaque);
        EngineWorker *worker = context->worker; const quint64 current = context->outputGeneration; const int type = event->type;
        QMetaObject::invokeMethod(worker, [worker, current, type] { if (worker->outputGeneration == current) worker->handleVLC(type); }, Qt::QueuedConnection);
    }
    void handleVLC(int type) {
#ifdef MUCKE_MEDIA_TESTING
        if (type == libvlc_MediaPlayerAudioVolume) qInfo("native VLC volume=%d", libvlc_audio_get_volume(player));
#endif
        if (aacProbeStage == AACProbeStage::Decoding && (type == libvlc_MediaPlayerTimeChanged || type == libvlc_MediaPlayerEndReached || type == libvlc_MediaPlayerEncounteredError)) {
            if (type == libvlc_MediaPlayerEncounteredError) failAACProbe(trMessage("AAC decoder verification failed; playing live", "AAC-Decoderprüfung fehlgeschlagen; Live-Wiedergabe wird verwendet"));
            else finishAACProbe();
            return;
        }
        if (type == libvlc_MediaPlayerTimeChanged) {
            if (outputFromBuffer && aacExpectedRate > 0) {
                const unsigned actual = decodedRate();
                if (actual == 0) return;
                if (actual != unsigned(aacExpectedRate)) { shiftBuffer->close(); expireOutput(trMessage("AAC decoder rate differs from the header; press Live to resume", "AAC-Decoderfrequenz stimmt nicht mit dem Header überein; zum Fortsetzen Live drücken")); return; }
                if (bufferFormatPending) { bufferFormatPending = false; libvlc_audio_set_mute(player, 0); }
            }
            if (!state.previewActive && !state.timeshiftPaused && libvlc_media_player_get_state(player) != libvlc_Paused) {
                const qint64 mediaTime = libvlc_media_player_get_time(player);
                if (lastMediaTime < 0 || mediaTime > lastMediaTime) { playbackHealth.progress(engineClock.elapsed()); lastMediaTime = mediaTime; }
                else if (mediaTime + 1000 < lastMediaTime) { beginHealth(); playbackHealth.progress(engineClock.elapsed()); lastMediaTime = mediaTime; }
            }
            if (state.state != PlaybackState::Playing && libvlc_media_player_get_state(player) != libvlc_Paused) { state.state = PlaybackState::Playing; applyVolume(); state.error = shiftStatus; publish(); }
            if (discontinuityPending && outputFromBuffer) {
                updateTimeshift();
                if (discontinuityPending && outputFromBuffer && state.state == PlaybackState::Playing) {
                    discontinuityPending = false;
                    if (onSeek) onSeek(std::max(0.0, state.bufferSeconds - state.delaySeconds));
                }
            }
        } else if (type == libvlc_MediaPlayerEncounteredError || type == libvlc_MediaPlayerEndReached) {
            if (state.previewActive) {
                const bool previewFailed = type == libvlc_MediaPlayerEncounteredError
                    || (state.state == PlaybackState::Buffering && libvlc_media_player_get_length(player) <= 0);
                stop();
                if (previewFailed) {
                    state.state = PlaybackState::Error;
                    state.error = trMessage("Preview audio cannot be decoded", "Vorschauaudio kann nicht dekodiert werden");
                    publish();
                }
                return;
            }
            if (outputFromBuffer) { expireOutput(trMessage("Timeshift output ended; press Live to resume", "Timeshift-Ausgabe beendet; zum Fortsetzen Live drücken")); return; }
            scheduleRetry();
        } else if (type == libvlc_MediaPlayerPaused) { state.state = PlaybackState::Paused; publish(); }
    }
    void attachEvents() {
        eventContext = std::make_unique<EventContext>(EventContext{this, outputGeneration});
        auto manager = libvlc_media_player_event_manager(player);
        for (libvlc_event_e event : events) libvlc_event_attach(manager, event, &EngineWorker::vlcEvent, eventContext.get());
    }
    void beginStream(QUrl url) {
        resolvedURL = url; readerRetryCount = 0; liveTrack = {}; outputExpired = false;
        if (!stationPreview) recordOverride.clear();
        recorder.setEnabled(stationPreview ? false : state.recordRequested); recorder.beginSession(station.name, sessionID);
        state.state = PlaybackState::Buffering; state.previewActive = stationPreview; state.heardTrack = {};
        beginHealth();
        if (state.timeshiftEnabled && !stationPreview && !MediaPrivate::isHLS({}, url)) {
            pendingShiftStart = true; positionTimer->start(); setShiftStatus(trMessage("Building timeshift buffer…", "Timeshift-Puffer wird aufgebaut…")); startReader(url); publish(); return;
        }
        if (state.timeshiftEnabled && MediaPrivate::isHLS({}, url)) setShiftStatus(trMessage("HLS supports live playback only", "HLS unterstützt ausschließlich Live-Wiedergabe"));
        startDirectOutput();
        if (!stationPreview) startReader(url);
        publish();
    }
    void startDirectOutput() {
        aacProbeStage = AACProbeStage::None; pendingAAC.clear(); aacPrefix.clear(); aacExpectedRate = 0; bufferFormatPending = false;
        pendingShiftStart = false; pendingLiveJump = false; releasePlayer();
        if (!ensurePlayer()) { fail(trMessage("Native audio output unavailable", "Nativer Audioausgang nicht verfügbar")); return; }
        outputExpired = false;
        if (!shiftBuffer && positionTimer) positionTimer->stop();
        state.state = PlaybackState::Buffering; state.timeshiftPaused = false;
        beginHealth();
        state.timeshiftAvailable = false; state.delaySeconds = 0;
        if (!state.previewActive && !liveTrack.id.isEmpty()) { state.heardTrack = liveTrack; state.heardTrack.heardAt = QDateTime::currentDateTimeUtc(); }
        const QUrl url = resolvedURL;
        const QByteArray encoded = url.toEncoded(); libvlc_media_t *media = libvlc_media_new_location(instance, encoded.constData());
        if (!media) { fail(trMessage("Cannot open stream", "Stream kann nicht geöffnet werden")); return; }
        libvlc_media_add_option(media, ":no-video"); const QByteArray agent = ":http-user-agent=" + userAgent(); libvlc_media_add_option(media, agent.constData());
        libvlc_media_player_set_media(player, media); hasOutputMedia = true; libvlc_media_release(media); attachEvents(); libvlc_audio_set_mute(player, 0); applyVolume(); applyEqualizer();
        if (libvlc_media_player_play(player) != 0) { scheduleRetry(); return; }
        if (visualizationRequested) monitor->setActive(true);
    }
    void scheduleRetry() {
        if (retryScheduled) return;
        playbackHealth.cancel(); healthTimer->stop();
        ++receptionGeneration;
        closeReception(); releasePlayer(); shiftBuffer.reset(); pendingShiftStart = false;
        if (retryCount >= 3) { state.state = PlaybackState::Error; state.error = trMessage("Stream unavailable after three reconnect attempts", "Stream nach drei Wiederverbindungsversuchen nicht verfügbar"); publish(); return; }
        static const int delays[] = {2000, 5000, 15000}; const int delay = delays[retryCount++];
        retryScheduled = true; state.state = PlaybackState::Buffering;
        state.error = trMessage("Reconnecting…", "Verbindung wird wiederhergestellt…"); publish();
        const quint64 current = receptionGeneration;
        QTimer::singleShot(delay, this, [this, current] {
            if (current != receptionGeneration || !retryScheduled) return;
            retryScheduled = false; ++receptionGeneration; sessionID = uniqueID(); resolve(QUrl(station.url), 0);
        });
    }
    void startReader(QUrl url) {
        audioOnlyReader = false;
        if (MediaPrivate::isHLS({}, url)) { recordOverride = trMessage("HLS recording unavailable", "HLS-Aufnahme nicht verfügbar"); if (pendingShiftStart) { setShiftStatus(recordOverride); startDirectOutput(); } return; }
        QNetworkRequest request(url); request.setTransferTimeout(20000); request.setMaximumRedirectsAllowed(5);
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        request.setRawHeader("Icy-MetaData", "1"); request.setRawHeader("User-Agent", userAgent());
        reader = network->get(request); reader->setReadBufferSize(65536);
        QNetworkReply *reply = reader; const quint64 current = receptionGeneration;
        connect(reply, &QNetworkReply::metaDataChanged, this, [this, reply, current] {
            if (current != receptionGeneration || reply != reader || parser) return;
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt(); if (status < 200 || status >= 300) return;
            if (MediaPrivate::isHLS(reply->header(QNetworkRequest::ContentTypeHeader).toString(), reply->url())) {
                abortReply(reader); recordOverride = trMessage("HLS playback supports no recording or timeshift", "HLS-Wiedergabe unterstützt keine Aufnahme und kein Timeshift");
                if (pendingShiftStart) { setShiftStatus(recordOverride); startDirectOutput(); } publish(); return;
            }
            bool ok = false; const qlonglong interval = reply->rawHeader("icy-metaint").toLongLong(&ok);
            if (ok && (interval <= 0 || interval > 16 * 1024 * 1024)) { abortReply(reader); state.error = trMessage("Invalid ICY metadata interval", "Ungültiges ICY-Metadatenintervall"); if (pendingShiftStart) startDirectOutput(); publish(); return; }
            audioOnlyReader = !ok;
            if (state.timeshiftEnabled && !state.previewActive && !shiftBuffer) beginTimeshift(reply->header(QNetworkRequest::ContentTypeHeader).toString());
            if (audioOnlyReader && !state.recordRequested && !shiftBuffer && aacProbeStage == AACProbeStage::None) { abortReply(reader); return; }
            parser = std::make_unique<MediaPrivate::ICYParser>(ok ? int(interval) : 0); receiving = true;
        });
        connect(reply, &QNetworkReply::readyRead, this, [this, reply, current] { drainReader(reply, current); });
        connect(reply, &QNetworkReply::finished, this, [this, reply, current] {
            if (current != receptionGeneration || reply != reader) return;
            drainReader(reply, current); reader = nullptr; reply->deleteLater(); parser.reset(); recorder.finish();
            if (shiftBuffer) shiftBuffer->endReception();
            if (receiving) { receiving = false; if (onEnd) onEnd(QDateTime::currentDateTimeUtc()); }
            if (outputFromBuffer || outputExpired) { expireOutput(phaseMessage(MediaPrivate::BufferPhase::Closed)); return; }
            if (pendingShiftStart) { setShiftStatus(trMessage("Timeshift reception failed; using live playback", "Timeshift-Empfang fehlgeschlagen; Live-Wiedergabe wird verwendet")); shiftBuffer.reset(); startDirectOutput(); }
            publish();
            if (readerRetryCount < 3) {
                static const int delays[] = {2000, 5000, 15000}; const int delay = delays[readerRetryCount++];
                QTimer::singleShot(delay, this, [this, current] { if (current == receptionGeneration && !reader && !state.previewActive && state.state != PlaybackState::Stopped && state.state != PlaybackState::Error) startReader(resolvedURL); });
            }
        });
    }
    void drainReader(QNetworkReply *reply, quint64 current) {
        if (current != receptionGeneration || reply != reader || !parser) return;
        // Pro Event höchstens 256 KiB verarbeiten, damit Stop und Timer auch bei schnellen Servern drankommen.
        for (int i = 0; i < 8 && reply->bytesAvailable() > 0; ++i) {
            parsingAudio = true;
            parser->feed(reply->read(32768), [this](const QByteArray &audio) {
                recorder.audio(audio);
                const QDateTime now = QDateTime::currentDateTimeUtc();
                if (aacProbeStage != AACProbeStage::None) collectAACProbe(audio, now);
                else if (shiftBuffer && state.timeshiftEnabled) shiftBuffer->append(audio, now);
            }, [this](const QString &title) { receiveTitle(title); });
            parsingAudio = false;
            if (!parser || current != receptionGeneration || reply != reader) return;
        }
        if (reply->bytesAvailable() > 0) QTimer::singleShot(0, this, [this, reply, current] { drainReader(reply, current); });
    }
    void receiveTitle(QString raw) {
        Track track; track.id = uniqueID(); track.stationID = station.id; track.station = station.name; track.raw = raw; track.sessionID = sessionID;
        track.receivedAt = QDateTime::currentDateTimeUtc();
        const qsizetype split = raw.indexOf(" - ");
        if (split >= 0) { track.artist = raw.left(split).trimmed(); track.title = raw.mid(split + 3).trimmed(); } else track.title = raw;
        recorder.title(track);
        liveTrack = track;
        if (shiftBuffer) shiftBuffer->noteTitle(track);
        if (!outputFromBuffer && !pendingShiftStart) { track.heardAt = QDateTime::currentDateTimeUtc(); state.heardTrack = track; }
        if (onTrack) onTrack(track);
        if (state.recordRequested && recorder.rolloverNeedsHeader()) {
            const quint64 current = receptionGeneration;
            QTimer::singleShot(0, this, [this, current] {
                if (current != receptionGeneration || !state.recordRequested || !recorder.rolloverNeedsHeader()) return;
                ++receptionGeneration; abortReply(reader); parser.reset();
                if (receiving) { receiving = false; if (onEnd) onEnd(QDateTime::currentDateTimeUtc()); }
                sessionID = uniqueID(); recorder.beginSession(station.name, sessionID); startReader(resolvedURL);
            });
        }
        publish();
    }
    void togglePause() {
        if (systemSleeping) { resumeAfterWake = false; return; }
        if (!player) return;
        if (state.previewActive) { libvlc_media_player_pause(player); return; }
        if (outputFromBuffer && shiftBuffer && !outputExpired) {
            const auto view = shiftBuffer->view();
            if (state.timeshiftPaused) {
                if (pausedPosition < view.oldest) { expireOutput(trMessage("Pause exceeded the buffer; press Live to resume", "Pause hat den Puffer überschritten; zum Fortsetzen Live drücken")); return; }
                state.timeshiftPaused = false; libvlc_media_player_set_pause(player, 0); state.state = PlaybackState::Buffering; beginHealth();
            } else { pausedPosition = heardPosition(); state.timeshiftPaused = true; playbackHealth.cancel(); libvlc_media_player_set_pause(player, 1); state.state = PlaybackState::Paused; }
            updateTimeshift(); return;
        }
        state.error = trMessage("Pause requires a measured timeshift buffer; live playback continues", "Pause benötigt einen vermessenen Timeshift-Puffer; Live-Wiedergabe läuft weiter"); publish();
    }
    void setVolume(int value) { state.volume = std::clamp(value, 0, 100); applyVolume(); publish(); }
    void applyVolume() {
        effectiveVolume = aacProbeStage == AACProbeStage::Decoding ? 0 : int(std::round(state.volume * (state.sleepRemaining > 0 ? std::min(1.0, state.sleepRemaining / 30.0) : 1.0)));
        if (player) libvlc_audio_set_volume(player, effectiveVolume);
    }
    void setRecording(bool value) {
        state.recordRequested = value; recorder.setEnabled(value);
        if (value && recorder.needsFreshHeader() && !state.previewActive && (state.state == PlaybackState::Playing || state.state == PlaybackState::Buffering)) {
            ++receptionGeneration; abortReply(reader); parser.reset();
            if (receiving) { receiving = false; if (onEnd) onEnd(QDateTime::currentDateTimeUtc()); }
            sessionID = uniqueID(); recorder.beginSession(station.name, sessionID); startReader(resolvedURL);
        }
        if (!value && audioOnlyReader && reader && !shiftBuffer && aacProbeStage == AACProbeStage::None) {
            abortReply(reader); parser.reset();
            if (receiving) { receiving = false; if (onEnd) onEnd(QDateTime::currentDateTimeUtc()); }
        } else if (value && !reader && !resolvedURL.isEmpty() && !state.previewActive && (state.state == PlaybackState::Playing || state.state == PlaybackState::Buffering)) startReader(resolvedURL);
        publish();
    }
    void setTimeshift(bool enabled) {
        if (state.timeshiftEnabled == enabled) return;
        state.timeshiftEnabled = enabled; state.timeshiftAvailable = false; state.timeshiftPaused = false;
        if (!enabled) {
            aacProbeStage = AACProbeStage::None; pendingAAC.clear(); aacPrefix.clear(); aacExpectedRate = 0; bufferFormatPending = false;
            const bool needsLive = outputFromBuffer || pendingShiftStart || outputExpired;
            if (shiftReader) shiftReader->cancel();
            if (shiftBuffer) shiftBuffer->close();
            if (needsLive && !resolvedURL.isEmpty() && !state.previewActive) startDirectOutput();
            shiftBuffer.reset(); outputExpired = false; pendingShiftStart = false; positionTimer->stop(); setShiftStatus({});
            stopUnneededAudioReader();
            state.bufferSeconds = state.delaySeconds = 0;
        } else if (!resolvedURL.isEmpty() && !state.previewActive && state.state != PlaybackState::Stopped && state.state != PlaybackState::Error) {
            releasePlayer(); restartCaptureForTimeshift();
        }
        publish();
    }
    void unavailableSeek() { state.error = trMessage("No verified timeshift buffer is available", "Kein geprüfter Timeshift-Puffer verfügbar"); publish(); }
    void setShiftStatus(QString value) {
        const bool replace = state.error.isEmpty() || state.error == shiftStatus;
        shiftStatus = std::move(value); if (replace) state.error = shiftStatus;
    }
    QString phaseMessage(MediaPrivate::BufferPhase phase) const {
        using Phase = MediaPrivate::BufferPhase;
        switch (phase) {
        case Phase::Warming: return trMessage("Building timeshift buffer…", "Timeshift-Puffer wird aufgebaut…");
        case Phase::Unsupported: return trMessage("Timeshift is unavailable for this codec or decoder profile", "Timeshift ist für diesen Codec oder dieses Decoderprofil nicht verfügbar");
        case Phase::LowDisk: return trMessage("Timeshift stopped: less than 10 GiB free", "Timeshift gestoppt: weniger als 10 GiB frei");
        case Phase::ReaderOverrun: return trMessage("Pause exceeded the buffer; press Live to resume", "Pause hat den Puffer überschritten; zum Fortsetzen Live drücken");
        case Phase::FormatChanged: return trMessage("Stream format changed; press Live to resume", "Stream-Format geändert; zum Fortsetzen Live drücken");
        case Phase::InvalidAudio: return trMessage("Invalid audio frames; press Live to resume", "Ungültige Audioframes; zum Fortsetzen Live drücken");
        case Phase::IOError: return trMessage("Timeshift storage unavailable; press Live to resume", "Timeshift-Speicher nicht verfügbar; zum Fortsetzen Live drücken");
        case Phase::Closed: return trMessage("Timeshift reception ended; press Live to resume", "Timeshift-Empfang beendet; zum Fortsetzen Live drücken");
        default: return {};
        }
    }
    QString bufferMessage(const MediaPrivate::TimeshiftView &view) const {
        if (view.phase == MediaPrivate::BufferPhase::Unsupported && view.reason.contains("Gapless"))
            return trMessage("MP3 file headers with gapless padding do not support timeshift; live playback remains available", "MP3-Dateiheader mit Gapless-Padding unterstützen keinen Zeitversatz; Live-Wiedergabe bleibt verfügbar");
        return phaseMessage(view.phase);
    }
    void beginTimeshift(QString contentType) {
        const QString type = contentType.section(';', 0, 0).trimmed().toLower();
        if (type == "audio/aac" || type == "audio/adts" || type == "audio/aacp") {
            aacProbeStage = AACProbeStage::Collecting; aacPrefix.clear(); pendingAAC.clear(); aacProbeClock.start();
            setShiftStatus(trMessage("Checking AAC decoder format…", "AAC-Decoderformat wird geprüft…")); positionTimer->start(); return;
        }
        if (type != "audio/mpeg" && type != "audio/mp3") {
            setShiftStatus(trMessage("Timeshift is unavailable for this stream format; playing live", "Zeitversatz ist für dieses Streamformat nicht verfügbar; Live-Wiedergabe wird verwendet"));
            if (pendingShiftStart) startDirectOutput();
            return;
        }
        shiftBuffer = std::make_unique<MediaPrivate::TimeshiftBuffer>(QDir(cacheDirectory).filePath("timeshift"));
        if (!shiftBuffer->begin(type, sessionID, MediaPrivate::DecoderProfile{"mp3"})) {
            setShiftStatus(bufferMessage(shiftBuffer->view())); shiftBuffer.reset();
            if (pendingShiftStart) startDirectOutput();
            return;
        }
        if (!liveTrack.id.isEmpty()) shiftBuffer->noteTitle(liveTrack);
        positionTimer->start();
    }
    enum class AACProbeStage { None, Collecting, Decoding };
    struct PendingAudio { QByteArray bytes; QDateTime date; Track track; };
    unsigned decodedRate() const {
        libvlc_media_t *media = libvlc_media_player_get_media(player); if (!media) return 0;
        libvlc_media_track_t **tracks = nullptr; const unsigned count = libvlc_media_tracks_get(media, &tracks);
        unsigned rate = 0; int audioTracks = 0;
        for (unsigned i = 0; i < count; ++i) if (tracks[i]->i_type == libvlc_track_audio && tracks[i]->audio) { rate = tracks[i]->audio->i_rate; ++audioTracks; }
        libvlc_media_tracks_release(tracks, count); libvlc_media_release(media);
        return audioTracks == 1 ? rate : 0;
    }
    void failAACProbe(QString reason) {
        aacProbeStage = AACProbeStage::None; pendingAAC.clear(); aacPrefix.clear(); aacExpectedRate = 0; bufferFormatPending = false;
        setShiftStatus(std::move(reason)); startDirectOutput();
        stopUnneededAudioReader();
        publish();
    }
    void collectAACProbe(const QByteArray &bytes, QDateTime date) {
        if (aacPrefix.size() + bytes.size() > 256 * 1024 || pendingAAC.size() >= 512 || aacProbeClock.elapsed() > 2000) {
            failAACProbe(trMessage("AAC verification exceeded its bounded prefix; playing live", "AAC-Prüfung überschreitet den begrenzten Vorlauf; Live-Wiedergabe wird verwendet")); return;
        }
        aacPrefix.append(bytes); pendingAAC.append({bytes, date, liveTrack});
        if (aacProbeStage == AACProbeStage::Collecting && (aacPrefix.size() >= 8192 || (aacProbeClock.elapsed() >= 750 && aacPrefix.size() >= 2048))) startAACProbe();
    }
    void startAACProbe() {
        aacExpectedRate = MediaPrivate::encodedAACSampleRate(aacPrefix);
        if (aacExpectedRate == 0) return;
        if (!QDir().mkpath(cacheDirectory)) { failAACProbe(trMessage("AAC verification storage unavailable; playing live", "Speicher für AAC-Prüfung nicht verfügbar; Live-Wiedergabe wird verwendet")); return; }
        aacProbeDirectory = std::make_unique<QTemporaryDir>(QDir(cacheDirectory).filePath("aac-probe-XXXXXX"));
        if (!aacProbeDirectory->isValid()) { failAACProbe(trMessage("Cannot prepare AAC decoder verification; playing live", "AAC-Decoderprüfung kann nicht vorbereitet werden; Live-Wiedergabe wird verwendet")); return; }
        const QString path = QDir(aacProbeDirectory->path()).filePath("probe.aac"); QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::NewOnly) || file.write(aacPrefix) != aacPrefix.size()) { failAACProbe(trMessage("Cannot write AAC verification prefix; playing live", "AAC-Prüfvorlauf kann nicht geschrieben werden; Live-Wiedergabe wird verwendet")); return; }
        file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner); file.close();
        libvlc_media_t *media = libvlc_media_new_path(instance, QFile::encodeName(path).constData());
        if (!media) { failAACProbe(trMessage("Cannot inspect AAC decoder format; playing live", "AAC-Decoderformat kann nicht geprüft werden; Live-Wiedergabe wird verwendet")); return; }
        libvlc_media_add_option(media, ":demux=aac"); libvlc_media_add_option(media, ":file-caching=0"); libvlc_media_add_option(media, ":no-video");
        aacProbeStage = AACProbeStage::Decoding;
        libvlc_media_player_set_media(player, media); hasOutputMedia = true; libvlc_media_release(media); attachEvents(); libvlc_audio_set_mute(player, 1);
        if (libvlc_audio_set_volume(player, 0) != 0 || libvlc_audio_get_volume(player) != 0 || libvlc_audio_get_mute(player) != 1) {
            failAACProbe(trMessage("AAC decoder verification cannot be muted safely; playing live", "AAC-Decoderprüfung kann nicht sicher stummgeschaltet werden; Live-Wiedergabe wird verwendet")); return;
        }
        if (libvlc_media_player_play(player) != 0) failAACProbe(trMessage("AAC decoder verification cannot start; playing live", "AAC-Decoderprüfung kann nicht starten; Live-Wiedergabe wird verwendet"));
    }
    void finishAACProbe() {
        const unsigned actualRate = decodedRate();
        const auto profile = MediaPrivate::verifiedTimeshiftProfile("aac", aacExpectedRate);
        if (actualRate == 0) return;
        if (actualRate != unsigned(aacExpectedRate) || !profile.verified) {
            failAACProbe(trMessage("AAC decoder rate is unsupported for timeshift; playing live", "AAC-Decoderfrequenz unterstützt keinen Zeitversatz; Live-Wiedergabe wird verwendet")); return;
        }
        releasePlayer(); aacProbeStage = AACProbeStage::None;
        shiftBuffer = std::make_unique<MediaPrivate::TimeshiftBuffer>(QDir(cacheDirectory).filePath("timeshift"));
        if (!shiftBuffer->begin("audio/aac", sessionID, profile)) { shiftBuffer.reset(); failAACProbe(trMessage("AAC timeshift buffer unavailable; playing live", "AAC-Timeshift-Puffer nicht verfügbar; Live-Wiedergabe wird verwendet")); return; }
        for (const auto &chunk : pendingAAC) { shiftBuffer->noteTitle(chunk.track); if (!shiftBuffer->append(chunk.bytes, chunk.date)) break; }
        pendingAAC.clear(); aacPrefix.clear(); setShiftStatus(trMessage("Building timeshift buffer…", "Timeshift-Puffer wird aufgebaut…")); updateTimeshift();
    }
    double heardPosition() const {
        if (state.timeshiftPaused || outputExpired) return pausedPosition;
        if (!shiftReader || !player) return 0;
        return shiftReader->outputStart() + std::max<qint64>(0, libvlc_media_player_get_time(player)) / 1000.0;
    }
    void expireOutput(QString reason) {
        playbackHealth.cancel(); healthTimer->stop();
        pausedPosition = heardPosition();
        if (shiftReader) shiftReader->cancel();
        if (player) libvlc_audio_set_mute(player, 1);
        outputExpired = true; pendingShiftStart = false;
        state.state = PlaybackState::Stopped; state.timeshiftPaused = false; state.timeshiftAvailable = false;
        setShiftStatus(std::move(reason)); if (monitor) monitor->setActive(false); publish();
        releasePlayer();
    }
    bool playBuffer(std::shared_ptr<MediaPrivate::TimeshiftReader> next, bool signalJump = false) {
        if (!next || !ensurePlayer()) return false;
        releasePlayer();
        if (!player) return false;
        shiftReader = std::move(next); outputFromBuffer = true; outputExpired = false; pendingShiftStart = false;
        discontinuityPending = signalJump || pendingLiveJump; pendingLiveJump = false;
        libvlc_media_t *media = shiftReader->createMedia(instance);
        if (!media) { expireOutput(trMessage("Cannot open timeshift output; press Live to resume", "Timeshift-Ausgabe kann nicht geöffnet werden; zum Fortsetzen Live drücken")); return false; }
        MediaPrivate::configureRadioPrefetch(media);
        libvlc_media_player_set_media(player, media); hasOutputMedia = true; libvlc_media_release(media); attachEvents();
        state.state = PlaybackState::Buffering; state.timeshiftPaused = false; setShiftStatus({}); bufferFormatPending = aacExpectedRate > 0; bufferFormatClock.start(); libvlc_audio_set_mute(player, bufferFormatPending ? 1 : 0); applyVolume(); applyEqualizer();
        beginHealth();
        if (libvlc_media_player_play(player) != 0) { expireOutput(trMessage("Cannot start timeshift output; press Live to resume", "Timeshift-Ausgabe kann nicht starten; zum Fortsetzen Live drücken")); return false; }
        if (visualizationRequested) monitor->setActive(true);
        return true;
    }
    void updateTimeshift() {
        if (aacProbeStage != AACProbeStage::None) {
            if (aacProbeClock.elapsed() > 2000) failAACProbe(trMessage("AAC decoder verification timed out; playing live", "AAC-Decoderprüfung hat das Zeitlimit überschritten; Live-Wiedergabe wird verwendet"));
            return;
        }
        if (!shiftBuffer || !state.timeshiftEnabled || state.previewActive) return;
        if (outputFromBuffer && bufferFormatPending && bufferFormatClock.elapsed() > 2000) {
            shiftBuffer->close();
            expireOutput(trMessage("AAC output format could not be verified; press Live to resume", "AAC-Ausgabeformat konnte nicht geprüft werden; zum Fortsetzen Live drücken")); return;
        }
        const auto view = shiftBuffer->view();
        state.bufferSeconds = std::max(0.0, view.live - view.oldest);
        const bool ready = view.phase == MediaPrivate::BufferPhase::Ready;
        state.timeshiftAvailable = ready && !outputExpired;
        if (pendingShiftStart && ready) playBuffer(shiftBuffer->readerLive());
        else if (pendingShiftStart && view.phase != MediaPrivate::BufferPhase::Warming) {
            setShiftStatus(bufferMessage(view)); shiftBuffer->close(); shiftBuffer.reset(); startDirectOutput(); stopUnneededAudioReader(); publish(); return;
        }
        if (outputFromBuffer) {
            const double position = heardPosition();
            if (!ready || position + 0.001 < view.oldest) { expireOutput(!ready ? bufferMessage(view) : phaseMessage(MediaPrivate::BufferPhase::ReaderOverrun)); return; }
            state.delaySeconds = std::max(0.0, view.live - position);
            Track heard = shiftBuffer->trackAt(position);
            if (!heard.id.isEmpty() && (state.state == PlaybackState::Playing || state.timeshiftPaused)) { heard.heardAt = QDateTime::currentDateTimeUtc(); state.heardTrack = heard; }
        } else if (outputExpired) state.delaySeconds = std::max(0.0, view.live - pausedPosition);
        publish();
    }
    void seekDelay(double seconds) {
        if (systemSleeping) { resumeAfterWake = false; return; }
        if (!std::isfinite(seconds) || !shiftBuffer || !state.timeshiftAvailable) { unavailableSeek(); return; }
        if (seconds <= 3 && outputFromBuffer && !state.timeshiftPaused && state.state == PlaybackState::Playing && state.delaySeconds <= 3.5) return;
        const auto view = shiftBuffer->view();
        if (!playBuffer(shiftBuffer->readerAt(view.live - std::max(0.0, seconds)), true)) { unavailableSeek(); return; }
        updateTimeshift();
    }
    void restartCaptureForTimeshift(bool signalLiveJump = false) {
        ++receptionGeneration;
        aacProbeStage = AACProbeStage::None; pendingAAC.clear(); aacPrefix.clear(); aacExpectedRate = 0; bufferFormatPending = false;
        if (shiftReader) shiftReader->cancel();
        abortReply(reader); parser.reset();
        if (shiftBuffer) shiftBuffer->close();
        shiftBuffer.reset();
        if (receiving) { receiving = false; if (onEnd) onEnd(QDateTime::currentDateTimeUtc()); }
        sessionID = uniqueID(); recorder.beginSession(station.name, sessionID); liveTrack = {}; state.heardTrack = {};
        pendingShiftStart = true; outputExpired = false; state.state = PlaybackState::Buffering; state.timeshiftPaused = false;
        pendingLiveJump = signalLiveJump; beginHealth();
        setShiftStatus(trMessage("Building timeshift buffer…", "Timeshift-Puffer wird aufgebaut…")); positionTimer->start(); startReader(resolvedURL);
    }
    void goLive() {
        if (systemSleeping) { resumeAfterWake = false; return; }
        if (!state.timeshiftEnabled || state.previewActive) return;
        if (outputFromBuffer && !state.timeshiftPaused && state.state == PlaybackState::Playing && state.delaySeconds <= 3.5) return;
        if (shiftBuffer && shiftBuffer->view().phase == MediaPrivate::BufferPhase::Ready) {
            if (playBuffer(shiftBuffer->readerLive(), true)) { updateTimeshift(); return; }
        }
        if (!shiftBuffer && !outputExpired && !pendingShiftStart && state.state == PlaybackState::Playing) return;
        if (!resolvedURL.isEmpty()) { releasePlayer(); restartCaptureForTimeshift(true); publish(); }
    }
    void beginHealth() {
        if (state.previewActive) { playbackHealth.cancel(); healthTimer->stop(); return; }
        lastMediaTime = -1; playbackHealth.begin(engineClock.elapsed()); healthTimer->start();
    }
    void healthTick() {
        if (systemSleeping || retryScheduled || state.previewActive || state.timeshiftPaused || outputExpired || state.state == PlaybackState::Stopped || state.state == PlaybackState::Error) return;
        const auto tick = playbackHealth.tick(engineClock.elapsed());
        if (tick.renewBudget) { retryCount = 0; readerRetryCount = 0; }
        if (tick.stalled) scheduleRetry();
    }
    void setEqualizer(bool enabled, QVector<double> values, double preamp) {
        equalizerEnabled = enabled; bands = std::move(values); bands.resize(10);
        for (double &value : bands) value = std::isfinite(value) ? std::clamp(value, -12.0, 12.0) : 0;
        preampDB = std::isfinite(preamp) ? std::clamp(preamp, -12.0, 0.0) : 0; applyEqualizer();
    }
    void applyEqualizer() {
        if (!player) return;
        if (aacProbeStage == AACProbeStage::Decoding) return;
        if (state.previewActive) { libvlc_media_player_set_equalizer(player, nullptr); restoreVolumeAfterFilter(); return; }
        const double gain = stationGains.value(station.id, 0);
        if (!equalizerEnabled && gain == 0) { libvlc_media_player_set_equalizer(player, nullptr); restoreVolumeAfterFilter(); return; }
        libvlc_equalizer_t *equalizer = libvlc_audio_equalizer_new(); if (!equalizer) return;
        // Jeder VLC-Durchlauf multipliziert den Eingang mit 0,25. Zwei Durchläufe mit halben dB-Werten
        // bilden auch +12 dB Sendergain innerhalb des auf +20 dB begrenzten nativen Preamps ab.
        constexpr double neutralPreamp = 12.041199826559248;
        const double largestBoost = std::max(0.0, *std::max_element(bands.cbegin(), bands.cend()));
        const double effectivePreamp = equalizerEnabled ? std::min(preampDB, -largestBoost) : 0;
        libvlc_audio_equalizer_set_preamp(equalizer, float(std::clamp(neutralPreamp + (gain + effectivePreamp) / 2, -20.0, 20.0)));
        for (unsigned i = 0; i < 10; ++i) libvlc_audio_equalizer_set_amp_at_index(equalizer, float(equalizerEnabled ? bands.value(int(i), 0) / 2 : 0), i);
        libvlc_media_player_set_equalizer(player, equalizer); libvlc_audio_equalizer_release(equalizer);
        // Ein Filterwechsel kann den nativen Audioausgang neu öffnen; die gewählte Lautstärke danach erneut setzen.
        restoreVolumeAfterFilter();
    }
    void restoreVolumeAfterFilter() { applyVolume(); }
    void setGain(QString id, double value) { stationGains[id] = std::isfinite(value) ? std::clamp(value, -12.0, 12.0) : 0; if (id == station.id) applyEqualizer(); }
    void setVisualization(bool active) { visualizationRequested = active; if (monitor) monitor->setActive(active && state.state != PlaybackState::Stopped && state.state != PlaybackState::Error); }
    int remainingSleepTime() const {
        if (!sleepDeadline.isValid()) return 0;
        const qint64 milliseconds = QDateTime::currentDateTimeUtc().msecsTo(sleepDeadline);
        return milliseconds <= 0 ? 0 : int(std::min<qint64>(86400, milliseconds / 1000 + (milliseconds % 1000 != 0)));
    }
    void setSleep(int seconds) {
        state.sleepRemaining = std::clamp(seconds, 0, 24 * 60 * 60);
        sleepDeadline = state.sleepRemaining > 0 ? QDateTime::currentDateTimeUtc().addSecs(state.sleepRemaining) : QDateTime();
        if (state.sleepRemaining) sleepTimer->start(); else sleepTimer->stop(); applyVolume(); publish();
    }
    void prepareSleep(bool sleeping) {
        if (sleeping == systemSleeping) return;
        if (sleeping) {
            wakeStation = station;
            resumeAfterWake = state.state == PlaybackState::Playing && !state.timeshiftPaused && !state.previewActive && !outputExpired && !station.id.isEmpty();
            systemSleeping = true; stop(true); return;
        }
        systemSleeping = false;
        if (sleepDeadline.isValid()) {
            state.sleepRemaining = remainingSleepTime();
            if (state.sleepRemaining == 0) { resumeAfterWake = false; sleepDeadline = {}; sleepTimer->stop(); }
        }
        const bool resume = resumeAfterWake; const Station saved = wakeStation; resumeAfterWake = false;
        if (resume) startStation(saved, false); else publish();
    }
    void preview(QString path) {
        if (systemSleeping) { resumeAfterWake = false; state.error = trMessage("Preview is unavailable during system sleep", "Vorschau ist während des Systemruhezustands nicht verfügbar"); publish(); return; }
        const QFileInfo info(path);
        if (!info.isFile() || info.isSymLink() || !info.isReadable()) { state.error = trMessage("Preview file unavailable", "Vorschaudatei nicht verfügbar"); publish(); return; }
        stop(); if (!ensurePlayer()) { state.state = PlaybackState::Error; state.error = trMessage("Preview audio output unavailable", "Audioausgang für Vorschau nicht verfügbar"); publish(); return; }
        libvlc_media_t *media = libvlc_media_new_path(instance, QFile::encodeName(info.absoluteFilePath()).constData());
        if (!media) { state.state = PlaybackState::Error; state.error = trMessage("Preview media cannot be opened", "Vorschaumedium kann nicht geöffnet werden"); publish(); return; }
        libvlc_media_player_set_media(player, media); hasOutputMedia = true; libvlc_media_release(media); attachEvents(); libvlc_audio_set_mute(player, 0); applyVolume();
        state.previewActive = true; state.state = PlaybackState::Buffering; applyEqualizer();
        if (libvlc_media_player_play(player) != 0) { fail(trMessage("Preview cannot start", "Vorschau kann nicht gestartet werden")); return; }
        if (visualizationRequested) monitor->setActive(true);
        publish();
    }
    void previewRecording(QString id) { preview(recorder.checkedPath(id)); }
    void removeRecording(QString id) { if (!recorder.remove(id)) { state.error = trMessage("Recording cannot be deleted while active or unavailable", "Aktive oder nicht verfügbare Aufnahme kann nicht gelöscht werden"); publish(); } }
    void removeCompleted() { for (const Recording &item : recorder.list()) if (!item.active) recorder.remove(item.id); }
    struct ExportJob { QString id, input, output; double start = 0, duration = 0, fadeIn = 0, fadeOut = 0; QJsonObject metadata; std::optional<SongExportProposal> proposal{}; QString recordingID{}; };
    struct ExportSource {
        int fd = -1;
        struct stat initial{};
        ~ExportSource() { if (fd >= 0) ::close(fd); }
    };
    static bool sameSource(const struct stat &a, const struct stat &b) {
        return S_ISREG(b.st_mode) && b.st_nlink == 1 && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec
            && a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
    }
    bool exportSourceUnchanged() const {
        if (!exportSource) return false;
        struct stat held{}, named{};
        const QString path = recorder.checkedPath(exportJob.recordingID);
        return !path.isEmpty() && ::fstat(exportSource->fd, &held) == 0 && sameSource(exportSource->initial, held)
            && ::lstat(QFile::encodeName(path).constData(), &named) == 0 && sameSource(exportSource->initial, named);
    }
    void prepareSongs(QString request, QVector<Track> tracks) { songResolver->prepare(request, std::move(tracks), recorder.list(), recorder.songBoundaries()); }
    void cancelSongs(QString request) { songResolver->cancel(request); }
    void exportPrepared(QString id, SongExportProposal proposal, double startAdjustment, double endAdjustment, double fadeIn, double fadeOut, QString destination) {
        QString error;
        if (exportIDs.contains(id)) return;
        if (!songResolver->validate(proposal, &error) || !std::isfinite(startAdjustment) || !std::isfinite(endAdjustment)) {
            exportIDs.insert(id); reportExport(id, {}, error.isEmpty() ? trMessage("Invalid song adjustments", "Ungültige Titelkorrekturen") : error); return;
        }
        const double start = std::clamp(proposal.suggestedStart + startAdjustment, proposal.audioStart, proposal.audioEnd);
        const double end = std::clamp(proposal.suggestedEnd + endAdjustment, proposal.audioStart, proposal.audioEnd);
        if (!std::isfinite(start) || !std::isfinite(end) || end <= start) { exportIDs.insert(id); reportExport(id, {}, trMessage("The adjusted song range is empty", "Der korrigierte Titelbereich ist leer")); return; }
        exportClip({id, proposal.recordingID, std::move(destination), start, end - start, fadeIn, fadeOut, proposal.metadata, proposal});
    }
    void reportExport(QString id, QString path, QString error) {
        if (!exportIDs.remove(id)) return;
        if (onExport) onExport(std::move(id), std::move(path), std::move(error));
    }
    void exportClip(ExportJob job) {
        if (exportIDs.contains(job.id)) return;
        exportIDs.insert(job.id); job.recordingID = job.input;
        job.input = recorder.checkedPath(job.input);
        const QFileInfo output(job.output);
        const QString suffix = output.suffix().toLower();
        if (job.id.isEmpty() || job.input.isEmpty() || !std::isfinite(job.start) || !std::isfinite(job.duration) || job.start < 0 || job.duration <= 0 || job.duration > 24 * 3600
            || !std::isfinite(job.fadeIn) || !std::isfinite(job.fadeOut) || job.fadeIn < 0 || job.fadeOut < 0 || job.fadeIn + job.fadeOut > job.duration
            || output.fileName() != MediaPrivate::safeExportName(output.fileName()) || output.exists() || output.isSymLink()
            || !QStringList{"mp3", "m4a", "wav", "flac", "ogg", "opus"}.contains(suffix) || !QFileInfo(output.absolutePath()).isDir() || jobs.size() >= 64) {
            reportExport(job.id, {}, trMessage("Invalid export range or destination; existing files are never overwritten", "Ungültiger Exportbereich oder Zielpfad; bestehende Dateien werden niemals überschrieben"));
            return;
        }
        job.output = output.absoluteFilePath(); jobs.enqueue(std::move(job)); startExport();
    }
    void startExport() {
        if (shutDown || exporter || jobs.isEmpty()) return;
        exportJob = jobs.dequeue();
        exportCanceled = false;
        exportSource = std::make_unique<ExportSource>(); exportSource->fd = recorder.openReadFD(exportJob.recordingID);
        QString sourceError;
        if (exportSource->fd < 0 || ::fstat(exportSource->fd, &exportSource->initial) != 0 || !exportSourceUnchanged()
            || (exportJob.proposal && !songResolver->validate(*exportJob.proposal, &sourceError))) {
            exportSource.reset(); reportExport(exportJob.id, {}, sourceError.isEmpty() ? trMessage("Export requires a completed, unchanged recording", "Export benötigt eine abgeschlossene, unveränderte Aufnahme") : sourceError); startExport(); return;
        }
        exportDirectory = std::make_unique<QTemporaryDir>(QDir(QFileInfo(exportJob.output).absolutePath()).filePath(".mucke-export-XXXXXX"));
        if (!exportDirectory->isValid()) {
            reportExport(exportJob.id, {}, trMessage("Cannot prepare export destination", "Exportziel kann nicht vorbereitet werden"));
            exportDirectory.reset(); exportSource.reset(); startExport(); return;
        }
        exportTemporaryPath = QDir(exportDirectory->path()).filePath("audio." + QFileInfo(exportJob.output).suffix());
        exporter = new QProcess(this); exportError.clear();
        const int descriptor = exportSource->fd;
        QStringList args{"-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-ss", QString::number(exportJob.start, 'f', 6), "-i", QString("/proc/self/fd/%1").arg(descriptor), "-t", QString::number(exportJob.duration, 'f', 6), "-map", "0:a:0", "-vn"};
        QStringList filters;
        if (exportJob.fadeIn > 0) filters << "afade=t=in:st=0:d=" + QString::number(exportJob.fadeIn, 'f', 6);
        if (exportJob.fadeOut > 0) filters << "afade=t=out:st=" + QString::number(exportJob.duration - exportJob.fadeOut, 'f', 6) + ":d=" + QString::number(exportJob.fadeOut, 'f', 6);
        if (!filters.isEmpty()) args << "-af" << filters.join(',');
        for (const QString &key : {QString("title"), QString("artist"), QString("album"), QString("genre"), QString("date"), QString("comment")}) {
            QString value = exportJob.metadata.value(key).toString().left(4096).remove(QChar(0));
            if (!value.isEmpty()) args << "-metadata" << key + "=" + value;
        }
        if (QFileInfo(exportJob.output).suffix().compare("m4a", Qt::CaseInsensitive) == 0) args << "-c:a" << "aac" << "-b:a" << "192k" << "-movflags" << "+faststart";
        args << exportTemporaryPath;
        connect(exporter, &QProcess::readyReadStandardError, this, [this] { const QByteArray chunk = exporter->readAllStandardError(); if (exportError.size() < 8192) exportError.append(chunk.left(8192 - exportError.size())); });
        connect(exporter, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) { if (error == QProcess::FailedToStart) finishExport(false, trMessage("FFmpeg is unavailable", "FFmpeg ist nicht verfügbar")); });
        connect(exporter, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this, [this](int code, QProcess::ExitStatus status) { finishExport(code == 0 && status == QProcess::NormalExit, {}); });
        connect(exporter, &QProcess::started, this, [this] { if (exportCanceled) exporter->kill(); });
        exporter->setChildProcessModifier([descriptor] { if (::fcntl(descriptor, F_SETFD, 0) < 0) ::_exit(126); });
        exporter->setProgram("ffmpeg"); exporter->setArguments(args);
        sourceError.clear();
        if (!exportSourceUnchanged() || (exportJob.proposal && !songResolver->validate(*exportJob.proposal, &sourceError))) {
            finishExport(false, sourceError.isEmpty() ? trMessage("Recording changed before export", "Aufnahme vor Export verändert") : sourceError); return;
        }
        exporter->start();
    }
    void finishExport(bool ok, QString error) {
        if (!exporter) return;
        exporter->disconnect(this); exporter->deleteLater(); exporter = nullptr;
        if (exportCanceled) { ok = false; error = trMessage("Export canceled", "Export abgebrochen"); }
        if (ok) {
            QString validationError;
            if (!exportSourceUnchanged() || (exportJob.proposal && !songResolver->validate(*exportJob.proposal, &validationError))) {
                ok = false; error = validationError.isEmpty() ? trMessage("Recording changed during export; no output was saved", "Aufnahme während Export verändert; keine Ausgabe gespeichert") : validationError;
            }
        }
        if (ok) {
            const QByteArray source = QFile::encodeName(exportTemporaryPath), target = QFile::encodeName(exportJob.output);
            // Ein fertiger Export erscheint atomar. Selbst ein zwischenzeitlich angelegtes Ziel bleibt erhalten.
            int result = int(::syscall(SYS_renameat2, AT_FDCWD, source.constData(), AT_FDCWD, target.constData(), RENAME_NOREPLACE));
            if (result != 0 && (errno == ENOSYS || errno == EINVAL || errno == EOPNOTSUPP)) {
                result = ::link(source.constData(), target.constData());
                if (result == 0) ::unlink(source.constData());
            }
            if (result != 0) { ok = false; error = trMessage("Export destination already exists or cannot be written; no file was overwritten", "Exportziel existiert bereits oder kann nicht geschrieben werden; keine Datei wurde überschrieben"); }
        }
        exportDirectory.reset(); exportSource.reset(); exportTemporaryPath.clear();
        if (!ok && error.isEmpty()) error = trMessage("FFmpeg export failed", "FFmpeg-Export fehlgeschlagen") + ": " + QString::fromUtf8(exportError).left(2048);
        reportExport(exportJob.id, ok ? exportJob.output : QString(), error);
        exportCanceled = false;
        startExport();
    }
    void cancelExport(QString id) {
        for (qsizetype i = jobs.size() - 1; i >= 0; --i) if (jobs[i].id == id) { jobs.removeAt(i); reportExport(id, {}, trMessage("Export canceled", "Export abgebrochen")); }
        if (exporter && exportJob.id == id) { exportCanceled = true; exporter->kill(); }
    }
    void teardown() {
        if (shutDown) return;
        shutDown = true; ++receptionGeneration;
        if (diskTimer) diskTimer->stop();
        if (sleepTimer) sleepTimer->stop();
        if (positionTimer) positionTimer->stop();
        if (healthTimer) healthTimer->stop();
        if (monitor) monitor->setActive(false);
        if (songResolver) songResolver->shutdown();
        for (const auto &job : std::as_const(jobs)) reportExport(job.id, {}, trMessage("Export canceled", "Export abgebrochen"));
        jobs.clear(); if (exporter) { exporter->disconnect(this); exporter->kill(); exporter->waitForFinished(2000); delete exporter; exporter = nullptr; reportExport(exportJob.id, {}, trMessage("Export canceled", "Export abgebrochen")); }
        exportDirectory.reset(); exportSource.reset();
        closeReception(); releasePlayer(); shiftBuffer.reset(); if (player) { libvlc_media_player_release(player); player = nullptr; } if (instance) { libvlc_release(instance); instance = nullptr; }
    }
private:
    MediaPrivate::Recorder recorder;
    SongRangeResolver *songResolver = nullptr;
    QString cacheDirectory, sessionID;
    Station station; QUrl resolvedURL;
    quint64 receptionGeneration = 0, outputGeneration = 0; int retryCount = 0, readerRetryCount = 0; bool retryScheduled = false, receiving = false, shutDown = false;
    QNetworkAccessManager *network = nullptr; QNetworkReply *resolver = nullptr, *reader = nullptr;
    MediaPrivate::PulseMonitor *monitor = nullptr;
    bool visualizationRequested = false;
    bool stationPreview = false;
    int effectiveVolume = 70;
    bool audioOnlyReader = false;
    bool parsingAudio = false;
    QString recordOverride;
    std::unique_ptr<MediaPrivate::ICYParser> parser;
    std::unique_ptr<MediaPrivate::TimeshiftBuffer> shiftBuffer;
    std::shared_ptr<MediaPrivate::TimeshiftReader> shiftReader;
    AACProbeStage aacProbeStage = AACProbeStage::None;
    QByteArray aacPrefix;
    QVector<PendingAudio> pendingAAC;
    QElapsedTimer aacProbeClock, bufferFormatClock;
    int aacExpectedRate = 0;
    bool bufferFormatPending = false;
    std::unique_ptr<QTemporaryDir> aacProbeDirectory;
    bool pendingShiftStart = false, outputFromBuffer = false, outputExpired = false;
    bool discontinuityPending = false, pendingLiveJump = false;
    bool systemSleeping = false, resumeAfterWake = false;
    Station wakeStation;
    QDateTime sleepDeadline;
    double pausedPosition = 0;
    QString shiftStatus;
    Track liveTrack;
    libvlc_instance_t *instance = nullptr; libvlc_media_player_t *player = nullptr;
    bool hasOutputMedia = false;
    std::unique_ptr<EventContext> eventContext;
    const libvlc_event_e events[5] = {libvlc_MediaPlayerTimeChanged, libvlc_MediaPlayerEncounteredError, libvlc_MediaPlayerEndReached, libvlc_MediaPlayerPaused, libvlc_MediaPlayerAudioVolume};
    QTimer *diskTimer = nullptr, *sleepTimer = nullptr, *positionTimer = nullptr, *healthTimer = nullptr;
    QElapsedTimer engineClock;
    qint64 lastMediaTime = -1;
    MediaPrivate::PlaybackHealth playbackHealth;
    bool equalizerEnabled = false; QVector<double> bands = QVector<double>(10, 0); double preampDB = 0; QHash<QString, double> stationGains;
    QProcess *exporter = nullptr; QQueue<ExportJob> jobs; ExportJob exportJob; QByteArray exportError;
    QSet<QString> exportIDs;
    bool exportCanceled = false;
    std::unique_ptr<QTemporaryDir> exportDirectory;
    std::unique_ptr<ExportSource> exportSource;
    QString exportTemporaryPath;
};
}
class MediaEngine::Impl {
public:
    PlaybackSnapshot snapshot;
    QVector<Recording> recordings;
    QString directory;
    QThread thread;
    EngineWorker *worker;
    bool stopped = false;
    std::shared_ptr<std::atomic<bool>> framePending = std::make_shared<std::atomic<bool>>(false);
    Impl(MediaEngine *owner, QString path, QString cache) : directory(std::move(path)), worker(new EngineWorker(directory, std::move(cache))) {
        worker->moveToThread(&thread);
        QPointer<MediaEngine> target(owner);
        worker->onSnapshot = [this, target](PlaybackSnapshot value) { if (target) QMetaObject::invokeMethod(target, [this, target, value] { if (target) { snapshot = value; emit target->snapshotChanged(value); } }, Qt::QueuedConnection); };
        worker->onRecordings = [this, target](QVector<Recording> value) { if (target) QMetaObject::invokeMethod(target, [this, target, value] { if (target) { recordings = value; emit target->recordingsChanged(); } }, Qt::QueuedConnection); };
        worker->onTrack = [target](Track value) { if (target) QMetaObject::invokeMethod(target, [target, value] { if (target) emit target->receivedTrack(value); }, Qt::QueuedConnection); };
        worker->onEnd = [target](QDateTime value) { if (target) QMetaObject::invokeMethod(target, [target, value] { if (target) emit target->receptionEnded(value); }, Qt::QueuedConnection); };
        worker->onExport = [target](QString id, QString path, QString error) { if (target) QMetaObject::invokeMethod(target, [target, id, path, error] { if (target) emit target->exportFinished(id, path, error); }, Qt::QueuedConnection); };
        worker->onSongPrepared = [target](QString request, QVector<SongExportProposal> proposals) { if (target) QMetaObject::invokeMethod(target, [target, request, proposals] { if (target) emit target->songExportsPrepared(request, proposals); }, Qt::QueuedConnection); };
        worker->onSongProgress = [target](QString request, int finished, int total) { if (target) QMetaObject::invokeMethod(target, [target, request, finished, total] { if (target) emit target->songPreparationProgress(request, finished, total); }, Qt::QueuedConnection); };
        worker->onSeek = [target](double position) { if (target) QMetaObject::invokeMethod(target, [target, position] { if (target) emit target->positionDiscontinuity(position); }, Qt::QueuedConnection); };
        worker->onFrames = [target, pending = framePending](QVector<float> wave, QVector<float> spectrum, float rms) {
            if (!target || pending->exchange(true)) return;
            QMetaObject::invokeMethod(target, [target, pending, wave, spectrum, rms] { if (target) emit target->visualization(wave, spectrum, rms); pending->store(false); }, Qt::QueuedConnection);
        };
        QObject::connect(&thread, &QThread::finished, worker, &QObject::deleteLater);
        thread.start(); enqueue([](EngineWorker &w) { w.initialize(); });
    }
    void enqueue(std::function<void(EngineWorker &)> fn) { if (!stopped) QMetaObject::invokeMethod(worker, [w = worker, fn = std::move(fn)] { fn(*w); }, Qt::QueuedConnection); }
    void shutdown() { if (stopped) return; stopped = true; QMetaObject::invokeMethod(worker, [w = worker] { w->teardown(); }, Qt::BlockingQueuedConnection); thread.quit(); thread.wait(); }
    ~Impl() { shutdown(); }
};
MediaEngine::MediaEngine(QString path, QString cache, QObject *parent) : QObject(parent), d(std::make_unique<Impl>(this, std::move(path), std::move(cache))) {}
MediaEngine::~MediaEngine() = default;
PlaybackSnapshot MediaEngine::snapshot() const { return d->snapshot; }
QVector<Recording> MediaEngine::recordings() const { return d->recordings; }
QString MediaEngine::recordingsDirectory() const { return d->directory; }
void MediaEngine::play(Station value) { d->enqueue([value](auto &w) { w.play(value); }); }
void MediaEngine::previewStation(Station value) { d->enqueue([value](auto &w) { w.previewStation(value); }); }
void MediaEngine::stop() { d->enqueue([](auto &w) { w.stop(); }); }
void MediaEngine::togglePause() { d->enqueue([](auto &w) { w.togglePause(); }); }
void MediaEngine::setVolume(int value) { d->enqueue([value](auto &w) { w.setVolume(value); }); }
void MediaEngine::setRecordingEnabled(bool value) { d->enqueue([value](auto &w) { w.setRecording(value); }); }
void MediaEngine::setTimeshiftEnabled(bool value) { d->enqueue([value](auto &w) { w.setTimeshift(value); }); }
void MediaEngine::seekDelay(double value) { d->enqueue([value](auto &w) { w.seekDelay(value); }); }
void MediaEngine::goLive() { d->enqueue([](auto &w) { w.goLive(); }); }
void MediaEngine::setEqualizer(bool enabled, QVector<double> bands, double preamp) { d->enqueue([enabled, bands, preamp](auto &w) { w.setEqualizer(enabled, bands, preamp); }); }
void MediaEngine::setStationGain(QString id, double value) { d->enqueue([id, value](auto &w) { w.setGain(id, value); }); }
void MediaEngine::setSleepTimer(int value) { d->enqueue([value](auto &w) { w.setSleep(value); }); }
void MediaEngine::prepareForSleep(bool sleeping) { d->enqueue([sleeping](auto &w) { w.prepareSleep(sleeping); }); }
void MediaEngine::setVisualizationActive(bool active) { d->enqueue([active](auto &w) { w.setVisualization(active); }); }
void MediaEngine::previewRecording(QString id) { d->enqueue([id](auto &w) { w.previewRecording(id); }); }
void MediaEngine::previewFile(QString path) { d->enqueue([path](auto &w) { w.preview(path); }); }
void MediaEngine::stopPreview() { d->enqueue([](auto &w) { if (w.state.previewActive) w.stop(); }); }
void MediaEngine::removeRecording(QString id) { d->enqueue([id](auto &w) { w.removeRecording(id); }); }
void MediaEngine::removeCompletedRecordings() { d->enqueue([](auto &w) { w.removeCompleted(); }); }
void MediaEngine::exportClip(QString jobID, QString recordingID, double start, double duration, double fadeIn, double fadeOut, QJsonObject metadata, QString destination) {
    d->enqueue([=](auto &w) { w.exportClip({jobID, recordingID, destination, start, duration, fadeIn, fadeOut, metadata}); });
}
void MediaEngine::cancelExport(QString id) { d->enqueue([id](auto &w) { w.cancelExport(id); }); }
void MediaEngine::prepareSongExports(QString request, QVector<Track> tracks) { d->enqueue([request, tracks](auto &w) { w.prepareSongs(request, tracks); }); }
void MediaEngine::cancelSongPreparation(QString request) { d->enqueue([request](auto &w) { w.cancelSongs(request); }); }
void MediaEngine::exportPreparedSong(QString id, SongExportProposal proposal, double startAdjustment, double endAdjustment, double fadeIn, double fadeOut, QString destination) {
    d->enqueue([=](auto &w) { w.exportPrepared(id, proposal, startAdjustment, endAdjustment, fadeIn, fadeOut, destination); });
}
void MediaEngine::shutdown() { d->shutdown(); }
}
