#include "songrangeresolver.h"
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QLocale>
#include <QMap>
#include <QProcess>
#include <QSet>
#include <QTimer>
#include <algorithm>
#include <cmath>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace Mucke {
namespace {
constexpr int mappingVersion = 1;
constexpr int maxTracks = 100;
constexpr int maxCacheFiles = 16;
constexpr int maxBoundaries = 4096;
constexpr qint64 maxCacheBytes = 4 * 1024 * 1024;
QString text(const char *de, const char *en) {
    return QString::fromUtf8(QLocale().language() == QLocale::German ? de : en);
}
QString invalidSourceText() {
    return text("Die Aufnahmedatei fehlt oder wurde verändert.", "The recording file is missing or has changed.");
}
bool exportable(SongAudioStatus s) {
    return s == SongAudioStatus::Available || s == SongAudioStatus::Partial || s == SongAudioStatus::Approximate;
}
bool basename(const QString &name) {
    return !name.isEmpty() && name != "." && name != ".." && !name.contains('/') &&
           !name.contains('\\') && !name.contains(QChar::Null) && name.toUtf8().size() <= 255;
}
QString revision(const struct stat &s) {
#ifdef Q_OS_MACOS
    const auto mt = s.st_mtimespec, ct = s.st_ctimespec;
#else
    const auto mt = s.st_mtim, ct = s.st_ctim;
#endif
    const QByteArray values = QByteArray::number(mappingVersion) + ':' + QByteArray::number(qulonglong(s.st_dev)) + ':' +
        QByteArray::number(qulonglong(s.st_ino)) + ':' + QByteArray::number(qlonglong(s.st_size)) + ':' +
        QByteArray::number(qlonglong(mt.tv_sec)) + ':' + QByteArray::number(qlonglong(mt.tv_nsec)) + ':' +
        QByteArray::number(qlonglong(ct.tv_sec)) + ':' + QByteArray::number(qlonglong(ct.tv_nsec));
    return QString::fromLatin1(QCryptographicHash::hash(values, QCryptographicHash::Sha256).toHex());
}
struct Source {
    int fd = -1;
    qint64 size = 0;
    QString rev;
    Source() = default;
    Source(const Source &) = delete;
    Source &operator=(const Source &) = delete;
    ~Source() { if (fd >= 0) ::close(fd); }
};
bool openSource(const QString &directory, const QString &name, Source &out) {
    if (!basename(name)) return false;
    const auto root = QFile::encodeName(directory), leaf = QFile::encodeName(name);
    const int dir = ::open(root.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (dir < 0) return false;
    out.fd = ::openat(dir, leaf.constData(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    ::close(dir);
    struct stat st {};
    if (out.fd < 0 || ::fstat(out.fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size <= 0)
        return false;
    out.size = st.st_size;
    out.rev = revision(st);
    return true;
}
struct Interval { double lower = 0, upper = 0; bool found = false, grouped = false; };
struct Mapping {
    QString rev, file, failure;
    qint64 size = 0;
    double duration = 0;
    QMap<qint64, Interval> points;
    quint64 used = 0;
};
struct Candidate {
    int trackIndex = -1;
    Recording recording;
    RecordingBoundary boundary;
    qint64 endByte = 0;
    bool partialEnd = false;
};
QString proposalKey(const SongExportProposal &p) { return p.requestID + QChar::Null + p.trackID + QChar::Null + p.recordingID; }
bool sameProposal(const SongExportProposal &a, const SongExportProposal &b) {
    return a.requestID == b.requestID && a.trackID == b.trackID && a.recordingID == b.recordingID &&
        a.status == b.status && a.explanation == b.explanation && a.audioStart == b.audioStart &&
        a.audioEnd == b.audioEnd && a.suggestedStart == b.suggestedStart && a.suggestedEnd == b.suggestedEnd &&
        a.startLower == b.startLower && a.startUpper == b.startUpper && a.endLower == b.endLower &&
        a.endUpper == b.endUpper && a.partialStart == b.partialStart && a.partialEnd == b.partialEnd &&
        a.sourceRevision == b.sourceRevision && a.metadata == b.metadata;
}
}

class SongRangeResolver::Impl {
public:
    SongRangeResolver *q;
    QString directory, request;
    QVector<Track> tracks;
    QVector<SongExportProposal> proposals;
    QVector<Candidate> candidates;
    QVector<QString> files;
    QMap<QString, QVector<int>> fileCandidates;
    QMap<QString, QVector<qint64>> fileOffsets;
    QMap<QString, Mapping> cache;
    QMap<QString, SongExportProposal> issued;
    QMap<QString, QString> issuedFiles;
    quint64 clock = 0, generation = 0;
    int fileIndex = 0;
    bool stopped = false;
    QProcess *process = nullptr;
    QTimer *timeout = nullptr;
    std::unique_ptr<Source> source;
    Mapping mapping;
    QByteArray pending, stderrTail;
    bool bad = false, sawStream = false, originKnown = false;
    bool probeEnded = false, probeSucceeded = false, readScheduled = false;
    quint64 probeSerial = 0;
    QMap<qint64, Interval>::iterator point;
    QString codec;
    double origin = 0, streamDuration = 0, maxEnd = -1, lastPTS = -1e100, firstPTS = 0;
    qint64 sampleRate = 0, lastPadding = 0;
    struct PacketGroup { qint64 pos = -1, byteEnd = 0; double start = 0, end = 0; int count = 0; } group;

    explicit Impl(SongRangeResolver *owner, QString dir) : q(owner), directory(QDir(dir).absolutePath()) {}
    void fail(SongExportProposal &p, SongAudioStatus status, const QString &why) { p.status = status; p.explanation = why; }
    void stopProcess() {
        ++probeSerial;
        if (timeout) { timeout->stop(); timeout->deleteLater(); timeout = nullptr; }
        if (process) {
            QObject::disconnect(process, nullptr, q, nullptr);
            // QProcess bleibt bis zum Exit am Leben; kill() wartet nicht auf das Kind.
            auto *old = process;
            process = nullptr;
            old->setParent(nullptr);
            QObject::connect(old, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), old, &QObject::deleteLater);
            if (old->state() == QProcess::NotRunning) old->deleteLater(); else old->kill();
        }
        source.reset();
    }
    void finishRequest() {
        const auto id = request;
        const auto result = proposals;
        for (const auto &p : result) if (exportable(p.status)) {
            issued.insert(proposalKey(p), p);
            for (const auto &c : candidates) if (c.trackIndex >= 0 && c.trackIndex < tracks.size() &&
                tracks[c.trackIndex].id == p.trackID && c.recording.id == p.recordingID) {
                issuedFiles.insert(proposalKey(p), c.recording.file); break;
            }
        }
        request.clear(); tracks.clear(); candidates.clear(); files.clear(); fileCandidates.clear(); fileOffsets.clear(); proposals.clear();
        emit q->prepared(id, result);
    }
    void cancelCurrent(const QString &why) {
        if (request.isEmpty()) return;
        ++generation;
        stopProcess();
        for (auto &p : proposals) fail(p, SongAudioStatus::Failed, why);
        finishRequest();
    }
    void trimCache() {
        // Konservative Obergrenze für QMap-Knoten, Intervalle und QString-Speicher.
        auto bytes = [&] {
            qint64 total = 0;
            for (const auto &m : cache) total += 512 + m.points.size() * 128 + (m.file.size() + m.rev.size() + m.failure.size()) * 2;
            return total;
        };
        while (cache.size() > maxCacheFiles || bytes() > maxCacheBytes) {
            auto victim = cache.begin();
            for (auto it = cache.begin(); it != cache.end(); ++it) if (it->used < victim->used) victim = it;
            cache.erase(victim);
        }
    }
    void finishGroup(qint64 nextPosition) {
        if (group.pos < 0) return;
        if (nextPosition <= group.pos || group.byteEnd > nextPosition) { bad = true; return; }
        while (point != mapping.points.end() && point.key() < nextPosition) {
            auto it = point++;
            const qint64 offset = it.key();
            if (offset == 0 || offset == mapping.size) continue;
            if (offset < group.pos) { bad = true; continue; }
            it->found = true;
            it->grouped = group.count > 1;
            it->lower = group.start;
            // Innerhalb eines Frames bzw. einer Ogg-Seite ist nur ein Intervall belegbar.
            it->upper = offset == group.pos && group.count == 1 ? group.start : group.end;
        }
    }
    void parseLine(const QByteArray &line) {
        if (line.size() > 8192) { bad = true; return; }
        const auto fields = line.split('|');
        if (fields.isEmpty()) return;
        QMap<QByteArray, QByteArray> values;
        for (int i = 1; i < fields.size(); ++i) {
            const int equal = fields[i].indexOf('=');
            if (equal > 0) values.insert(fields[i].left(equal), fields[i].mid(equal + 1));
        }
        if (fields[0] == "stream") {
            bool ok = false;
            origin = values.value("start_time").toDouble(&ok);
            originKnown = ok && std::isfinite(origin);
            if (!originKnown) origin = 0;
            codec = QString::fromLatin1(values.value("codec_name"));
            sampleRate = values.value("sample_rate").toLongLong();
            streamDuration = values.value("duration").toDouble(&ok);
            if (!ok || !std::isfinite(streamDuration) || streamDuration <= 0) streamDuration = 0;
            sawStream = true;
            return;
        }
        if (fields[0] != "packet") return;
        bool posOK, sizeOK, ptsOK, durationOK;
        const qint64 pos = values.value("pos").toLongLong(&posOK);
        const qint64 size = values.value("size").toLongLong(&sizeOK);
        const double pts = values.value("pts_time").toDouble(&ptsOK);
        const double duration = values.value("duration_time").toDouble(&durationOK);
        if (!posOK || !sizeOK || !ptsOK || !durationOK || pos < 0 || size <= 0 || pos > mapping.size ||
            size > mapping.size - pos || !std::isfinite(pts) || !std::isfinite(duration) || duration <= 0 ||
            duration > 60 || pts < lastPTS - 0.00001 || pts > 60 * 60 * 24 * 366 ||
            (maxEnd >= 0 && pts > maxEnd + 1)) { bad = true; return; }
        if (group.pos < 0) firstPTS = pts;
        lastPTS = pts;
        if (pts + duration >= maxEnd) {
            lastPadding = 0;
            for (auto it = values.cbegin(); it != values.cend(); ++it)
                if (it.key() == "discard_padding" || it.key().endsWith(":discard_padding")) lastPadding = it.value().toLongLong();
        }
        maxEnd = std::max(maxEnd, pts + duration);
        if (group.pos >= 0 && pos < group.pos) { bad = true; return; }
        if (group.pos != pos) {
            finishGroup(pos);
            group = {pos, pos + size, pts, pts + duration, 1};
        } else {
            group.byteEnd = std::max(group.byteEnd, pos + size);
            group.end = std::max(group.end, pts + duration);
            ++group.count;
        }
    }
    void readOutput() {
        if (!process) return;
        // Kleine Arbeitsportionen halten auch während eines langen Scans die Engine bedienbar.
        int consumed = 0;
        while (process->bytesAvailable() > 0 && consumed < 65536) {
            const auto chunk = process->read(16384);
            consumed += chunk.size(); pending += chunk;
            int newline;
            while ((newline = pending.indexOf('\n')) >= 0) {
                const auto line = pending.left(newline);
                pending.remove(0, newline + 1);
                parseLine(line);
            }
            if (pending.size() > 8192) { bad = true; pending.clear(); }
        }
        if (process->bytesAvailable() > 0) {
            if (!readScheduled) {
                readScheduled = true;
                const auto serial = probeSerial;
                QTimer::singleShot(0, q, [this, serial] {
                    if (serial != probeSerial || !process) return;
                    readScheduled = false; readOutput();
                });
            }
        } else if (probeEnded) completeProbe(probeSucceeded);
    }
    void applyMapping(const Mapping &m) {
        const auto indexes = fileCandidates.value(files[fileIndex]);
        for (const int index : indexes) {
            const auto &c = candidates[index];
            auto &p = proposals[c.trackIndex];
            if (!m.failure.isEmpty()) { fail(p, SongAudioStatus::Unsupported, m.failure); continue; }
            const auto start = m.points.value(c.boundary.byteOffset), end = m.points.value(c.endByte);
            if (!start.found || !end.found || end.upper <= start.lower) {
                fail(p, SongAudioStatus::MissingBoundaries, text("Die Byte-Grenzen ergeben keinen abspielbaren Ausschnitt.", "The byte boundaries do not form a playable excerpt.")); continue;
            }
            p.sourceRevision = m.rev;
            p.audioStart = 0; p.audioEnd = m.duration;
            p.startLower = start.lower; p.startUpper = start.upper;
            p.endLower = end.lower; p.endUpper = end.upper;
            p.suggestedStart = start.lower; p.suggestedEnd = end.upper;
            const bool approximate = start.grouped || end.grouped || start.upper - start.lower > 0.00001 || end.upper - end.lower > 0.00001;
            p.status = approximate ? SongAudioStatus::Approximate : (p.partialStart || p.partialEnd ? SongAudioStatus::Partial : SongAudioStatus::Available);
            p.explanation = approximate ? text("Die Grenze liegt innerhalb eines Audioframes oder einer Ogg-Seite. Der Vorschlag enthält das gesamte belegbare Intervall.", "The boundary lies inside an audio frame or Ogg page. The suggestion includes the entire supported interval.") :
                (p.partialStart || p.partialEnd ? text("Die Aufnahme enthält nur einen Teil des Titels.", "The recording contains only part of this song.") :
                 text("Die Schnittgrenzen sind durch Audiopakete belegt.", "The cut boundaries are supported by audio packets."));
            if (approximate && (p.partialStart || p.partialEnd)) p.explanation += text(" Der Titel ist außerdem unvollständig.", " The song is also incomplete.");
        }
    }
    void nextFile() {
        if (request.isEmpty() || stopped || process) return;
        if (fileIndex >= files.size()) { finishRequest(); return; }
        const auto file = files[fileIndex];
        source = std::make_unique<Source>();
        if (!openSource(directory, file, *source)) {
            for (const int index : fileCandidates.value(file)) fail(proposals[candidates[index].trackIndex], SongAudioStatus::MissingFile, invalidSourceText());
            advance(); return;
        }
        auto found = cache.find(source->rev);
        if (found != cache.end()) {
            bool covered = true;
            for (const qint64 offset : fileOffsets.value(file)) if (!found->points.contains(offset)) covered = false;
            if (covered) { found->used = ++clock; applyMapping(*found); advance(); return; }
            // Veränderte Grenzdaten benötigen einen neuen Scan, innerhalb eines Batches nur einmal.
            cache.erase(found);
        }
        mapping = {}; mapping.rev = source->rev; mapping.file = file; mapping.size = source->size;
        for (const qint64 offset : fileOffsets.value(file)) mapping.points.insert(offset, {});
        point = mapping.points.begin();
        probeEnded = probeSucceeded = readScheduled = false; ++probeSerial;
        pending.clear(); stderrTail.clear(); codec.clear(); group = {}; bad = false; sawStream = false;
        origin = streamDuration = firstPTS = 0; originKnown = false; sampleRate = lastPadding = 0; maxEnd = -1; lastPTS = -1e100;
        process = new QProcess(q);
        const int descriptor = source->fd;
        process->setChildProcessModifier([descriptor] {
            if (descriptor != 3 && ::dup2(descriptor, 3) < 0) ::_exit(126);
            if (::fcntl(3, F_SETFD, 0) < 0) ::_exit(126);
        });
#ifdef Q_OS_LINUX
        const QString input = "/proc/self/fd/3";
#else
        const QString input = "/dev/fd/3";
#endif
        QObject::connect(process, &QProcess::readyReadStandardOutput, q, [this] { readOutput(); });
        QObject::connect(process, &QProcess::readyReadStandardError, q, [this] {
            // Diagnose enthält potenziell Dateinamen/URLs; nur begrenzt verwerfen, niemals loggen.
            if (!process) return;
            process->setReadChannel(QProcess::StandardError);
            while (process->bytesAvailable() > 0) {
                stderrTail += process->read(4096);
                if (stderrTail.size() > 4096) stderrTail = stderrTail.right(4096);
            }
            process->setReadChannel(QProcess::StandardOutput);
        });
        QObject::connect(process, &QProcess::errorOccurred, q, [this](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart) completeProbe(false);
        });
        QObject::connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), q,
            [this](int exit, QProcess::ExitStatus status) {
                probeEnded = true; probeSucceeded = exit == 0 && status == QProcess::NormalExit; readOutput();
            });
        timeout = new QTimer(q); timeout->setSingleShot(true);
        QObject::connect(timeout, &QTimer::timeout, q, [this] {
            mapping.failure = text("Die Audioanalyse hat das Zeitlimit überschritten.", "Audio analysis exceeded its time limit.");
            completeProbe(false);
        });
        timeout->start(90000);
        process->start("ffprobe", {"-v", "error", "-select_streams", "a:0", "-show_packets", "-show_streams", "-show_entries",
            "packet=pos,size,pts_time,dts_time,duration_time:stream=codec_name,start_time,duration,sample_rate:packet_side_data=discard_padding", "-of", "compact=p=1", input});
    }
    void advance() {
        source.reset();
        ++fileIndex;
        const auto expected = generation;
        emit q->progress(request, fileIndex, files.size());
        QTimer::singleShot(0, q, [this, expected] { if (expected == generation) nextFile(); });
    }
    void completeProbe(bool success) {
        if (!process) return;
        if (!pending.isEmpty()) parseLine(pending);
        finishGroup(mapping.size);
        Source current;
        struct stat held {};
        const bool unchanged = source && ::fstat(source->fd, &held) == 0 && revision(held) == mapping.rev &&
            openSource(directory, mapping.file, current) && current.rev == mapping.rev;
        if (!unchanged) {
            for (const int index : fileCandidates.value(files[fileIndex])) fail(proposals[candidates[index].trackIndex], SongAudioStatus::MissingFile, invalidSourceText());
            stopProcess(); advance(); return;
        }
        const QSet<QString> supported = {"mp3", "aac", "vorbis", "opus", "flac"};
        if (!originKnown && (codec == "aac" || codec == "flac")) { origin = firstPTS; originKnown = true; }
        if (codec == "mp3" && lastPadding > 0) {
            if (sampleRate <= 0 || sampleRate > 384000 || lastPadding > sampleRate * 2) bad = true;
            else maxEnd -= double(lastPadding) / sampleRate;
        }
        const double extent = maxEnd - origin;
        if (!success || bad || !sawStream || !originKnown || group.pos < 0 || !supported.contains(codec) || !std::isfinite(extent) || extent <= 0) {
            if (mapping.failure.isEmpty()) mapping.failure = text("Für dieses Audioformat sind keine eindeutigen Byte-/Paketgrenzen verfügbar.", "Unambiguous byte-to-packet boundaries are unavailable for this audio format.");
        } else {
            // start_time entfernt u.a. MP3-Priming; negative Opus-PTS werden auf den hörbaren Anfang geklemmt.
            mapping.duration = streamDuration > 0 ? std::min(extent, streamDuration) : extent;
            for (auto it = mapping.points.begin(); it != mapping.points.end(); ++it) {
                if (it.key() == 0) { it->lower = it->upper = 0; it->found = true; }
                else if (it.key() == mapping.size) { it->lower = it->upper = mapping.duration; it->found = true; }
                else if (it.key() < 0 || it.key() > mapping.size) { it->found = false; }
                else if (it->found) {
                    it->lower = std::clamp(it->lower - origin, 0.0, mapping.duration);
                    it->upper = std::clamp(it->upper - origin, 0.0, mapping.duration);
                }
            }
        }
        mapping.used = ++clock;
        cache.insert(mapping.rev, mapping); trimCache();
        applyMapping(mapping);
        stopProcess(); advance();
    }
};

SongRangeResolver::SongRangeResolver(QString directory, QObject *parent) : QObject(parent), d(std::make_unique<Impl>(this, std::move(directory))) {}
SongRangeResolver::~SongRangeResolver() { shutdown(); }
void SongRangeResolver::prepare(QString requestID, QVector<Track> tracks, QVector<Recording> recordings, QVector<RecordingBoundary> boundaries) {
    d->cancelCurrent(text("Die Vorbereitung wurde durch eine neue Anfrage ersetzt.", "Preparation was replaced by a new request."));
    d->issued.clear(); d->issuedFiles.clear();
    if (d->stopped) { emit prepared(requestID, {}); return; }
    ++d->generation;
    d->request = requestID;
    if (requestID.isEmpty()) { emit prepared(requestID, {}); return; }
    d->tracks = tracks.mid(0, maxTracks);
    d->proposals.resize(d->tracks.size());
    if (tracks.size() > maxTracks) {
        for (int i = 0; i < d->tracks.size(); ++i) {
            auto &p = d->proposals[i]; p.requestID = requestID; p.trackID = d->tracks[i].id;
            d->fail(p, SongAudioStatus::Failed, text("Bitte höchstens 100 Titel gleichzeitig auswählen.", "Select at most 100 songs at a time."));
        }
        d->finishRequest(); return;
    }
    QMap<QString, QVector<RecordingBoundary>> byRecording;
    QSet<QString> sessions, recordingIDs;
    for (const auto &t : d->tracks) if (!t.sessionID.isEmpty()) sessions.insert(t.sessionID);
    for (const auto &r : recordings) if (sessions.contains(r.sessionID)) recordingIDs.insert(r.id);
    for (const auto &b : boundaries) if (recordingIDs.contains(b.recordingID)) byRecording[b.recordingID].push_back(b);
    for (auto it = byRecording.begin(); it != byRecording.end(); ++it)
        std::stable_sort(it->begin(), it->end(), [](const auto &a, const auto &b) { return a.byteOffset < b.byteOffset; });
    QMap<QString, int> trackIDs;
    for (const auto &t : d->tracks) ++trackIDs[t.id];
    for (int ti = 0; ti < d->tracks.size(); ++ti) {
        const auto &t = d->tracks[ti]; auto &p = d->proposals[ti];
        p.requestID = requestID; p.trackID = t.id;
        p.metadata = {{"artist", t.artist}, {"title", t.title.isEmpty() ? t.raw : t.title}, {"album", t.station},
                      {"comment", t.raw}, {"date", t.receivedAt.toString(Qt::ISODateWithMs)}};
        d->fail(p, SongAudioStatus::MissingBoundaries, text("Zu diesem Titel fehlen eindeutige Aufnahmegrenzen.", "This song has no unambiguous recording boundaries."));
        if (t.id.isEmpty() || trackIDs.value(t.id) != 1 || t.sessionID.isEmpty()) continue;
        QVector<Candidate> options;
        bool active = false;
        for (const auto &r : recordings) {
            if (r.sessionID != t.sessionID || r.id.isEmpty()) continue;
            const auto bs = byRecording.value(r.id);
            int match = -1, matches = 0;
            for (int bi = 0; bi < bs.size(); ++bi) {
                const auto &b = bs[bi];
                bool belongs = !b.trackID.isEmpty() ? b.trackID == t.id : (b.raw == t.raw && b.receivedAt.isValid() && b.receivedAt == t.receivedAt);
                if (belongs && b.trackID.isEmpty()) {
                    int legacyMatches = 0;
                    for (const auto &other : d->tracks) if (other.sessionID == t.sessionID && other.raw == b.raw && other.receivedAt == b.receivedAt) ++legacyMatches;
                    belongs = legacyMatches == 1;
                }
                if (belongs) { match = bi; ++matches; }
            }
            if (matches != 1) continue;
            if (r.active) { active = true; continue; }
            const qint64 end = match + 1 < bs.size() ? bs[match + 1].byteOffset : r.bytes;
            if (bs[match].byteOffset < 0 || end <= bs[match].byteOffset) continue;
            options.push_back({ti, r, bs[match], end, match + 1 == bs.size()});
        }
        if (options.isEmpty()) {
            if (active) d->fail(p, SongAudioStatus::ActiveRecording, text("Die Aufnahme läuft noch. Bitte zuerst die Aufnahme beenden.", "The recording is still active. Stop recording first."));
            continue;
        }
        std::stable_sort(options.begin(), options.end(), [](const auto &a, const auto &b) {
            const int ap = int(a.boundary.partialStart) + int(a.partialEnd), bp = int(b.boundary.partialStart) + int(b.partialEnd);
            return ap != bp ? ap < bp : a.endByte - a.boundary.byteOffset > b.endByte - b.boundary.byteOffset;
        });
        Candidate chosen = options.first();
        for (const auto &candidate : options) { Source available; if (openSource(d->directory, candidate.recording.file, available)) { chosen = candidate; break; } }
        p.recordingID = chosen.recording.id; p.partialStart = chosen.boundary.partialStart; p.partialEnd = chosen.partialEnd;
        const int ci = d->candidates.size(); d->candidates.push_back(chosen);
        d->fileCandidates[chosen.recording.file].push_back(ci);
    }
    for (auto it = d->fileCandidates.begin(); it != d->fileCandidates.end(); ++it) {
        QSet<qint64> offsets;
        for (const auto &r : recordings) if (r.file == it.key()) {
            for (const auto &b : byRecording.value(r.id)) offsets.insert(b.byteOffset);
            offsets.insert(r.bytes);
        }
        if (offsets.size() > maxBoundaries + 1) {
            for (const int index : it.value()) d->fail(d->proposals[d->candidates[index].trackIndex], SongAudioStatus::Unsupported,
                text("Die Datei überschreitet das Limit von 4096 Aufnahmegrenzen.", "The file exceeds the limit of 4096 recording boundaries."));
            continue;
        }
        d->files.push_back(it.key()); d->fileOffsets.insert(it.key(), offsets.values().toVector());
    }
    d->fileIndex = 0;
    const auto expected = d->generation;
    emit progress(requestID, 0, d->files.size());
    QTimer::singleShot(0, this, [this, expected] { if (expected == d->generation) d->nextFile(); });
}
void SongRangeResolver::cancel(QString requestID) {
    if (d->request == requestID) d->cancelCurrent(text("Die Vorbereitung wurde abgebrochen.", "Preparation was cancelled."));
    for (auto it = d->issued.begin(); it != d->issued.end();) {
        if (it->requestID == requestID) { d->issuedFiles.remove(it.key()); it = d->issued.erase(it); } else ++it;
    }
}
bool SongRangeResolver::validate(const SongExportProposal &proposal, QString *error) const {
    const auto key = proposalKey(proposal);
    const auto issued = d->issued.constFind(key);
    const bool finite = std::isfinite(proposal.audioStart) && std::isfinite(proposal.audioEnd) &&
        std::isfinite(proposal.suggestedStart) && std::isfinite(proposal.suggestedEnd) &&
        std::isfinite(proposal.startLower) && std::isfinite(proposal.startUpper) &&
        std::isfinite(proposal.endLower) && std::isfinite(proposal.endUpper);
    if (d->stopped || issued == d->issued.cend() || !sameProposal(*issued, proposal) || !exportable(proposal.status) || !finite ||
        proposal.audioStart != 0 || proposal.suggestedStart < 0 || proposal.suggestedEnd <= proposal.suggestedStart ||
        proposal.suggestedEnd > proposal.audioEnd || proposal.startLower > proposal.startUpper || proposal.endLower > proposal.endUpper) {
        if (error) *error = text("Dieser Schnittvorschlag ist nicht mehr gültig. Bitte erneut vorbereiten.", "This cut proposal is no longer valid. Prepare it again.");
        return false;
    }
    Source source;
    if (!openSource(d->directory, d->issuedFiles.value(key), source) || source.rev != proposal.sourceRevision) {
        if (error) *error = invalidSourceText();
        return false;
    }
    if (error) error->clear();
    return true;
}
void SongRangeResolver::shutdown() {
    if (!d || d->stopped) return;
    d->stopped = true;
    d->cancelCurrent(text("Die Audioanalyse wurde beendet.", "Audio analysis was stopped."));
    d->stopProcess(); d->cache.clear(); d->issued.clear(); d->issuedFiles.clear();
}
}
