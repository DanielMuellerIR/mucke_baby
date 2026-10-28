#include "timeshift.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QUuid>
#include <vlc/vlc.h>
#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <mutex>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

namespace Mucke::MediaPrivate {
namespace {
constexpr double epsilon = 0.000001;
constexpr int maximumReaders = 2;
const QByteArray ownerMarker("MuckeLinuxTimeshift-v1\n");
struct Header {
    int bytes = 0, samples = 0, rate = 0, channels = 0, identity = 0;
    double duration() const { return double(samples) / rate; }
};
Header parseHeader(const QByteArray &data, bool aac) {
    if (data.size() < (aac ? 7 : 4)) return {};
    const auto *h = reinterpret_cast<const unsigned char *>(data.constData());
    if (aac) {
        // Nur AAC-LC/ADTS mit einem Raw-Block und expliziter Kanalzahl.
        if (h[0] != 0xff || (h[1] & 0xf6) != 0xf0 || h[2] >> 6 != 1 || (h[6] & 3)) return {};
        static const int rates[] = {96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
        const int rateIndex = (h[2] >> 2) & 15;
        const int channels = ((h[2] & 1) << 2) | (h[3] >> 6);
        const int length = ((h[3] & 3) << 11) | (h[4] << 3) | (h[5] >> 5);
        if (rateIndex >= 13 || channels < 1 || channels > 2 || length <= ((h[1] & 1) ? 7 : 9)) return {};
        return {length, 1024, rates[rateIndex], channels, rates[rateIndex] * 16 + channels * 2 + ((h[1] >> 3) & 1)};
    }
    if (h[0] != 0xff || (h[1] & 0xe0) != 0xe0 || (h[1] & 6) != 2 || (h[3] & 3) == 2) return {};
    const int version = (h[1] >> 3) & 3, bitrateIndex = h[2] >> 4, rateIndex = (h[2] >> 2) & 3;
    if (version == 1 || bitrateIndex < 1 || bitrateIndex > 14 || rateIndex > 2) return {};
    static const int rates[] = {44100,48000,32000};
    static const int rates1[] = {0,32,40,48,56,64,80,96,112,128,160,192,224,256,320};
    static const int rates2[] = {0,8,16,24,32,40,48,56,64,80,96,112,128,144,160};
    const int rate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4);
    const int bitrate = (version == 3 ? rates1 : rates2)[bitrateIndex] * 1000;
    const int length = (version == 3 ? 144 : 72) * bitrate / rate + ((h[2] >> 1) & 1);
    const int channels = h[3] >> 6 == 3 ? 1 : 2;
    return {length, version == 3 ? 1152 : 576, rate, channels, rate * 16 + version * 2 + channels};
}
int leadingID3Bytes(const QByteArray &data) {
    if (data.size() < 3) return -1;
    if (!data.startsWith("ID3")) return 0;
    if (data.size() < 10) return -1;
    const auto *h = reinterpret_cast<const unsigned char *>(data.constData());
    if (h[3] < 2 || h[3] > 4 || ((h[6] | h[7] | h[8] | h[9]) & 128)) return -2;
    const int bytes = 10 + (int(h[6]) << 21) + (int(h[7]) << 14) + (int(h[8]) << 7) + h[9]
        + ((h[3] == 4 && (h[5] & 16)) ? 10 : 0);
    return bytes <= 65536 ? bytes : -2;
}
bool hasMP3FileIndex(const QByteArray &frame, const Header &header) {
    const auto *bytes = reinterpret_cast<const unsigned char *>(frame.constData());
    const int version = (bytes[1] >> 3) & 3;
    const int sideBytes = version == 3 ? (header.channels == 1 ? 17 : 32) : (header.channels == 1 ? 9 : 17);
    const int xingOffset = 4 + ((bytes[1] & 1) ? 0 : 2) + sideBytes;
    const auto marker = [&](int offset, const char *text) { return offset + 4 <= header.bytes && std::memcmp(frame.constData() + offset, text, 4) == 0; };
    // Dateiindizes beeinflussen den Decoderstart und das Gapless-Padding.
    // Die vermessenen Live-Frameprofile gelten dafür ausdrücklich nicht.
    return marker(xingOffset, "Xing") || marker(xingOffset, "Info") || marker(36, "VBRI");
}
QString bounded(QString value, int bytes) { return QString::fromUtf8(value.toUtf8().left(bytes)); }
Track boundedTrack(Track value) {
    value.id = bounded(value.id, 128); value.sessionID = bounded(value.sessionID, 128);
    value.stationID = bounded(value.stationID, 128); value.station = bounded(value.station, 256);
    value.raw = bounded(value.raw, 1024); value.artist = bounded(value.artist, 512); value.title = bounded(value.title, 512);
    value.recognition = nullptr;
    return value;
}
bool sameTrack(const Track &a, const Track &b) {
    return a.raw == b.raw && a.artist == b.artist && a.title == b.title && a.stationID == b.stationID && a.id == b.id;
}
bool writeAll(int fd, const char *bytes, size_t length) {
    while (length) {
        const auto count = ::write(fd, bytes, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        bytes += count; length -= size_t(count);
    }
    return true;
}
bool regularOwned(int fd) {
    struct stat st{};
    return fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() && st.st_nlink == 1;
}
bool safeDirectory(int fd) {
    struct stat st{};
    return fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == geteuid() && (st.st_mode & 0077) == 0;
}
bool knownSegment(const QString &name) { return QRegularExpression(QStringLiteral("^segment-[0-9]{8}\\.data$")).match(name).hasMatch(); }
void cleanupAbandoned(int rootFD, const QString &root) {
    const QDir dir(root);
    for (const auto &name : dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden)) {
        if (QUuid(name).isNull() || name != QUuid(name).toString(QUuid::WithoutBraces)) continue;
        const auto encoded = QFile::encodeName(name);
        int childFD = openat(rootFD, encoded.constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (childFD < 0) continue;
        int lockFD = openat(childFD, "owner.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC);
        int ownerFD = openat(childFD, "owner", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        char marker[64]{};
        const auto count = ownerFD < 0 ? -1 : ::read(ownerFD, marker, sizeof(marker));
        bool valid = safeDirectory(childFD) && lockFD >= 0 && ownerFD >= 0 && regularOwned(lockFD) && regularOwned(ownerFD)
            && count == ownerMarker.size() && QByteArray(marker, int(std::max<ssize_t>(0, count))) == ownerMarker
            && flock(lockFD, LOCK_EX | LOCK_NB) == 0;
        const auto entries = QDir(root + '/' + name).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
        for (const auto &entry : entries) {
            struct stat st{};
            const auto encodedEntry = QFile::encodeName(entry);
            if ((entry != "owner" && entry != "owner.lock" && !knownSegment(entry))
                || fstatat(childFD, encodedEntry.constData(), &st, AT_SYMLINK_NOFOLLOW) != 0
                || !S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1) valid = false;
        }
        if (valid) {
            for (const auto &entry : entries) unlinkat(childFD, QFile::encodeName(entry).constData(), 0);
            unlinkat(rootFD, encoded.constData(), AT_REMOVEDIR);
        }
        if (ownerFD >= 0) ::close(ownerFD);
        if (lockFD >= 0) ::close(lockFD);
        ::close(childFD);
    }
}
struct Frame { qint64 offset; double position; };
struct Receipt { double position; QDateTime date; };
struct Segment {
    int fd = -1;
    QString name;
    qint64 bytes = 0;
    double start = 0, end = 0;
    QVector<Frame> frames;
    QVector<TimeshiftAnchor> titles;
    QVector<Receipt> receipts;
    ~Segment() { if (fd >= 0) ::close(fd); }
};
}
struct TimeshiftReader::Cursor {
    std::shared_ptr<Segment> segment;
    qint64 offset = 0;
    bool cancelled = false;
    double input = 0, output = 0, frameDuration = 0;
    QString codec;
    int correction = 0;
};
struct TimeshiftState {
    mutable std::mutex mutex;
    std::condition_variable changed;
    TimeshiftLimits limits;
    QString root, directory;
    int rootFD = -1, directoryFD = -1, ownerFD = -1;
    std::deque<std::shared_ptr<Segment>> segments;
    std::vector<std::weak_ptr<TimeshiftReader::Cursor>> readers;
    BufferPhase phase = BufferPhase::Off;
    QString reason;
    bool begun = false, ended = false, closed = false, aac = false, id3Checked = false;
    int identity = 0, sequence = 0, skipID3 = 0;
    double live = 0, frameDuration = 0;
    qint64 bytes = 0;
    QByteArray pending;
    Track title, pendingTitle;
    QDateTime pendingDate;
    DecoderProfile profile;
    ~TimeshiftState() {
        segments.clear();
        if (directoryFD >= 0) {
            // Dieser Destruktor läuft erst nach Freigabe des letzten Lesers.
            const auto entries = QDir(directory).entryList(QDir::Files | QDir::Hidden | QDir::System);
            for (const auto &entry : entries)
                if (entry == "owner" || entry == "owner.lock" || knownSegment(entry)) unlinkat(directoryFD, QFile::encodeName(entry).constData(), 0);
            ::close(directoryFD);
            if (rootFD >= 0) unlinkat(rootFD, QFile::encodeName(QFileInfo(directory).fileName()).constData(), AT_REMOVEDIR);
        }
        if (ownerFD >= 0) ::close(ownerFD);
        if (rootFD >= 0) ::close(rootFD);
    }
    bool fail(BufferPhase value, QString message) {
        phase = value; reason = std::move(message); ended = true; pending.clear(); changed.notify_all(); return false;
    }
    bool disk() {
        struct statvfs stats{};
        if (directoryFD < 0 || fstatvfs(directoryFD, &stats) != 0) return fail(BufferPhase::IOError, "Pufferspeicher nicht lesbar.");
        const long double free = static_cast<long double>(stats.f_bavail) * stats.f_frsize;
        if (free < limits.minimumFreeBytes) return fail(BufferPhase::LowDisk, "Zu wenig freier Speicher für Zeitversatz.");
        return true;
    }
    bool failed() const { return phase != BufferPhase::Warming && phase != BufferPhase::Ready; }
    double oldest() const {
        if (segments.empty() || frameDuration <= 0) return live;
        // Die erste Sekunde bleibt ausschließlich Decoder-Vorlauf.
        const double desired = segments.front()->start + std::ceil(1.0 / frameDuration - epsilon) * frameDuration;
        return std::min(live, desired);
    }
    void updatePhase() { if (!failed()) phase = live - oldest() >= 3 - epsilon ? BufferPhase::Ready : BufferPhase::Warming; }
    bool pinned(const std::shared_ptr<Segment> &segment) {
        readers.erase(std::remove_if(readers.begin(), readers.end(), [](const auto &weak) { return weak.expired(); }), readers.end());
        return std::any_of(readers.begin(), readers.end(), [&](const auto &weak) {
            auto reader = weak.lock(); return reader && !reader->cancelled && reader->segment == segment;
        });
    }
    bool store(const QByteArray &frame, const Header &h) {
        const bool roll = segments.empty() || segments.back()->bytes + frame.size() > limits.segmentBytes
            || live + h.duration() - segments.back()->start > limits.segmentSeconds + epsilon;
        while (!segments.empty() && (bytes + frame.size() > limits.bytes
            || live + h.duration() - segments.front()->start > limits.seconds + epsilon
            || (roll && int(segments.size()) >= limits.segments))) {
            auto first = segments.front();
            if (pinned(first)) return fail(BufferPhase::ReaderOverrun, "Der Hörpunkt hat das Pufferlimit erreicht.");
            if (!roll && segments.size() == 1) return fail(BufferPhase::InvalidAudio, "Audioframe überschreitet das Pufferlimit.");
            if (unlinkat(directoryFD, QFile::encodeName(first->name).constData(), 0) != 0) return fail(BufferPhase::IOError, "Puffersegment kann nicht entfernt werden.");
            bytes -= first->bytes; segments.pop_front();
        }
        if (frame.size() > limits.bytes || frame.size() > limits.segmentBytes) return fail(BufferPhase::InvalidAudio, "Audioframe überschreitet das Pufferlimit.");
        if (roll) {
            auto segment = std::make_shared<Segment>();
            segment->name = QString("segment-%1.data").arg(sequence++, 8, 10, QLatin1Char('0'));
            segment->fd = openat(directoryFD, QFile::encodeName(segment->name).constData(), O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (segment->fd < 0) return fail(BufferPhase::IOError, "Puffersegment kann nicht angelegt werden.");
            segment->start = segment->end = live; segments.push_back(segment);
        }
        auto &segment = *segments.back();
        const bool titleChanged = segment.titles.isEmpty() || !sameTrack(segment.titles.last().track, pendingTitle);
        const bool receiptChanged = pendingDate.isValid() && (segment.receipts.isEmpty() || segment.receipts.last().date != pendingDate);
        if ((titleChanged && segment.titles.size() >= 64) || (receiptChanged && segment.receipts.size() >= 256))
            return fail(BufferPhase::InvalidAudio, "Zu viele Metadatenwechsel im Audiosegment.");
        if (!writeAll(segment.fd, frame.constData(), size_t(frame.size()))) return fail(BufferPhase::IOError, "Audio kann nicht in den Puffer geschrieben werden.");
        segment.frames.append({segment.bytes, live});
        if (titleChanged) segment.titles.append({live, pendingTitle});
        if (receiptChanged) segment.receipts.append({live, pendingDate});
        segment.bytes += frame.size(); bytes += frame.size(); live += h.duration(); segment.end = live;
        updatePhase(); return true;
    }
};

int encodedAACSampleRate(const QByteArray &prefix) {
    const int skip = leadingID3Bytes(prefix);
    if (skip < 0 || prefix.size() < skip + 7) return 0;
    const auto header = prefix.mid(skip, 9);
    if (!(static_cast<unsigned char>(header[1]) & 1) && header.size() < 9) return 0;
    return parseHeader(header, true).rate;
}
DecoderProfile verifiedTimeshiftProfile(QString codec, int decodedSampleRate) {
    DecoderProfile profile; profile.codec = codec.toLower(); profile.decodedSampleRate = decodedSampleRate;
    const bool knownRate = decodedSampleRate == 48000 || decodedSampleRate == 44100 || decodedSampleRate == 32000
        || (profile.codec == "mp3" && (decodedSampleRate == 24000 || decodedSampleRate == 22050 || decodedSampleRate == 16000));
    if (!knownRate || (profile.codec != "mp3" && profile.codec != "aac")) return profile;
    // Die PCM-Gates in timeshift_verify.py messen CBR/VBR, MPEG-1/2 und AAC-LC
    // gegen vollständige direkte VLC-Ausgaben. Andere Decoder bleiben gesperrt.
    profile.clockCorrectionFrames = profile.codec == "mp3" ? ((decodedSampleRate == 32000 || decodedSampleRate == 16000) ? 1 : 2) : (decodedSampleRate == 32000 ? 1 : 0);
    const auto version = QString::fromLatin1(libvlc_get_version()).section(' ', 0, 0);
    profile.verified = version == "3.0.20" || version == "3.0.24";
    return profile;
}
TimeshiftBuffer::TimeshiftBuffer(QString root, TimeshiftLimits limits) : state_(std::make_shared<TimeshiftState>()) {
    auto &s = *state_; s.root = QDir::cleanPath(std::move(root)); s.limits = limits;
    if (!QDir::isAbsolutePath(s.root) || !std::isfinite(limits.seconds) || limits.seconds < 4 || limits.seconds > 300
        || limits.bytes < 1024 || limits.bytes > 32LL*1024*1024 || limits.segments < 2 || limits.segments > 256
        || !std::isfinite(limits.segmentSeconds) || limits.segmentSeconds < .05 || limits.segmentSeconds > 2
        || limits.segmentBytes < 512 || limits.segmentBytes > 65536 || limits.minimumFreeBytes < 0) {
        s.fail(BufferPhase::IOError, "Ungültige Puffergrenzen."); return;
    }
    if (!QDir().mkpath(s.root)) { s.fail(BufferPhase::IOError, "Pufferordner kann nicht angelegt werden."); return; }
    s.rootFD = ::open(QFile::encodeName(s.root).constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    // Vorhandene fremde oder zugängliche Ordner werden niemals umgewidmet.
    if (s.rootFD >= 0) {
        struct stat st{};
        if (fstat(s.rootFD, &st) == 0 && st.st_uid == geteuid() && (st.st_mode & 0077) != 0) {
            // mkpath folgt der umask; nur ein leerer eigener Ordner darf privat werden.
            if (QDir(s.root).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System).isEmpty()) fchmod(s.rootFD, 0700);
        }
    }
    if (s.rootFD < 0 || !safeDirectory(s.rootFD)) { s.fail(BufferPhase::IOError, "Pufferordner ist nicht privat und sicher."); return; }
    int manager = openat(s.rootFD, "manager.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (manager < 0 || !regularOwned(manager) || flock(manager, LOCK_EX) != 0) {
        if (manager >= 0) ::close(manager);
        s.fail(BufferPhase::IOError, "Pufferverwaltung kann nicht gesperrt werden."); return;
    }
    cleanupAbandoned(s.rootFD, s.root);
    const auto name = QUuid::createUuid().toString(QUuid::WithoutBraces);
    s.directory = s.root + '/' + name;
    if (mkdirat(s.rootFD, QFile::encodeName(name).constData(), 0700) == 0)
        s.directoryFD = openat(s.rootFD, QFile::encodeName(name).constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (s.directoryFD >= 0) s.ownerFD = openat(s.directoryFD, "owner.lock", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    bool okay = s.ownerFD >= 0 && flock(s.ownerFD, LOCK_EX | LOCK_NB) == 0;
    int marker = s.directoryFD < 0 ? -1 : openat(s.directoryFD, "owner", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    okay = okay && marker >= 0 && writeAll(marker, ownerMarker.constData(), ownerMarker.size());
    if (marker >= 0) ::close(marker);
    ::close(manager);
    if (!okay) s.fail(BufferPhase::IOError, "Privater Puffer kann nicht angelegt werden.");
}
TimeshiftBuffer::~TimeshiftBuffer() { close(); }
bool TimeshiftBuffer::begin(QString contentType, QString sessionID, DecoderProfile profile) {
    auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex);
    if (s.begun || s.closed || s.phase != BufferPhase::Off) return false;
    const auto type = contentType.section(';', 0, 0).trimmed().toLower();
    if (type == "audio/mpeg" || type == "audio/mp3") s.aac = false;
    else if (type == "audio/aac" || type == "audio/adts" || type == "audio/aacp") s.aac = true;
    else return s.fail(BufferPhase::Unsupported, "Dieses Streamformat unterstützt keinen Zeitversatz.");
    const auto codec = s.aac ? QStringLiteral("aac") : QStringLiteral("mp3");
    const bool deferredMP3 = !s.aac && profile.codec.toLower() == "mp3" && profile.decodedSampleRate == 0
        && !profile.verified && profile.clockCorrectionFrames == 0;
    const auto expected = verifiedTimeshiftProfile(codec, deferredMP3 ? 48000 : profile.decodedSampleRate);
    if ((!deferredMP3 && !profile.verified) || !expected.verified || profile.codec.toLower() != codec
        || (!deferredMP3 && profile.clockCorrectionFrames != expected.clockCorrectionFrames))
        return s.fail(BufferPhase::Unsupported, "Decoderprofil für Zeitversatz ist noch nicht geprüft.");
    s.profile = std::move(profile); s.title.sessionID = bounded(sessionID, 128); s.begun = true; s.phase = BufferPhase::Warming;
    return s.disk();
}
bool TimeshiftBuffer::append(QByteArray data, QDateTime receivedAt) {
    auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex);
    if (!s.begun || s.closed || s.ended || s.failed()) return false;
    if (!s.disk()) return false;
    for (qsizetype offset = 0; offset < data.size(); offset += 4096) {
        if (s.pending.isEmpty()) { s.pendingTitle = s.title; s.pendingDate = receivedAt; }
        s.pending.append(data.constData() + offset, std::min<qsizetype>(4096, data.size() - offset));
        while (true) {
            if (!s.id3Checked) {
                const int bytes = leadingID3Bytes(s.pending);
                if (bytes == -1) break;
                if (bytes < 0) return s.fail(BufferPhase::InvalidAudio, "Ungültiger oder zu großer ID3-Vorlauf.");
                s.skipID3 = bytes;
                s.id3Checked = true;
            }
            if (s.skipID3) {
                const int skip = std::min(s.skipID3, int(s.pending.size())); s.pending.remove(0, skip); s.skipID3 -= skip;
                if (s.skipID3 || s.pending.isEmpty()) break;
                s.pendingTitle = s.title; s.pendingDate = receivedAt;
            }
            if (s.pending.size() < (s.aac ? 7 : 4)) break;
            const auto h = parseHeader(s.pending, s.aac);
            if (!h.bytes) return s.fail(BufferPhase::InvalidAudio, "Ungültige Audioframes im Stream.");
            if (s.identity && s.identity != h.identity) return s.fail(BufferPhase::FormatChanged, "Das Audioformat hat sich geändert.");
            if (!s.aac && s.profile.decodedSampleRate == 0) {
                s.profile = verifiedTimeshiftProfile("mp3", h.rate);
                if (!s.profile.verified) return s.fail(BufferPhase::Unsupported, "Dieses MP3-Decoderprofil ist noch nicht geprüft.");
            }
            if (s.profile.decodedSampleRate != h.rate) return s.fail(BufferPhase::Unsupported, "Ungeprüfte Decoderfrequenz; HE-AAC ist gesperrt.");
            if (s.pending.size() < h.bytes) break;
            if (!s.aac && hasMP3FileIndex(s.pending, h))
                return s.fail(BufferPhase::Unsupported, "MP3-Dateiindizes mit Gapless-Daten sind für Zeitversatz noch nicht geprüft.");
            s.identity = h.identity; s.frameDuration = h.duration();
            if (!s.store(s.pending.left(h.bytes), h)) return false;
            s.pending.remove(0, h.bytes); s.pendingTitle = s.title; s.pendingDate = receivedAt;
        }
    }
    s.changed.notify_all(); return true;
}
void TimeshiftBuffer::noteTitle(Track track) { auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex); if (!s.closed) s.title = boundedTrack(std::move(track)); }
bool TimeshiftBuffer::checkDisk() { auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex); return !s.closed && !s.failed() && s.disk(); }
TimeshiftView TimeshiftBuffer::view() const {
    auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex);
    TimeshiftView view; view.phase = s.phase; view.reason = s.reason; view.oldest = s.oldest(); view.live = s.live; view.bytes = s.bytes; view.segments = int(s.segments.size());
    TimeshiftAnchor prior; bool havePrior = false;
    for (const auto &segment : s.segments) for (const auto &anchor : segment->titles) {
        if (anchor.position <= view.oldest + epsilon) { prior = anchor; havePrior = true; }
        else if (view.titles.isEmpty() || !sameTrack(view.titles.last().track, anchor.track)) view.titles.append(anchor);
    }
    if (havePrior) { prior.position = view.oldest; view.titles.prepend(prior); }
    return view;
}
Track TimeshiftBuffer::trackAt(double position) const {
    auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex);
    if (!std::isfinite(position) || s.segments.empty() || position < s.segments.front()->start - epsilon || position > s.live + epsilon) return {};
    Track track;
    for (const auto &segment : s.segments) { if (segment->start > position + epsilon) break; for (const auto &anchor : segment->titles) if (anchor.position <= position + epsilon) track = anchor.track; }
    return track;
}
QDateTime TimeshiftBuffer::receivedAt(double position) const {
    auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex);
    if (!std::isfinite(position) || s.segments.empty() || position < s.segments.front()->start - epsilon || position > s.live + epsilon) return {};
    QDateTime date;
    for (const auto &segment : s.segments) { if (segment->start > position + epsilon) break; for (const auto &anchor : segment->receipts) if (anchor.position <= position + epsilon) date = anchor.date; }
    return date;
}
std::shared_ptr<TimeshiftReader> TimeshiftBuffer::readerAt(double position) {
    auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex);
    if (s.closed || s.ended || s.phase != BufferPhase::Ready || !std::isfinite(position) || s.segments.empty()) return {};
    s.readers.erase(std::remove_if(s.readers.begin(), s.readers.end(), [](const auto &weak) { return weak.expired(); }), s.readers.end());
    int active = 0; for (const auto &weak : s.readers) if (auto reader = weak.lock(); reader && !reader->cancelled) ++active;
    if (active >= maximumReaders) return {};
    const double desired = std::clamp(position, s.oldest(), std::max(s.oldest(), s.live - 3));
    std::shared_ptr<Segment> outputSegment; Frame output{};
    for (const auto &segment : s.segments) for (const auto &frame : segment->frames)
        if (frame.position <= desired + epsilon) { outputSegment = segment; output = frame; }
    if (!outputSegment) return {};
    std::shared_ptr<Segment> inputSegment; Frame input{};
    const double inputTarget = output.position - 1;
    // Mindestens eine volle Sekunde vor dem Ziel, ohne duplizierte Segmentpräfixe.
    for (const auto &segment : s.segments) for (const auto &frame : segment->frames)
        if (frame.position <= inputTarget + epsilon) { inputSegment = segment; input = frame; }
    if (!inputSegment) { inputSegment = s.segments.front(); input = inputSegment->frames.front(); }
    auto cursor = std::make_shared<TimeshiftReader::Cursor>(); cursor->segment = inputSegment; cursor->offset = input.offset;
    cursor->input = input.position; cursor->output = output.position; cursor->frameDuration = s.frameDuration; cursor->codec = s.aac ? "aac" : "mp3"; cursor->correction = s.profile.clockCorrectionFrames;
    s.readers.push_back(cursor);
    return std::shared_ptr<TimeshiftReader>(new TimeshiftReader(state_, std::move(cursor)));
}
std::shared_ptr<TimeshiftReader> TimeshiftBuffer::readerLive() { const auto snapshot = view(); return readerAt(snapshot.live - 3); }
void TimeshiftBuffer::endReception() { auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex); if (s.ended) return; if ((!s.pending.isEmpty() || s.skipID3 > 0) && !s.closed) s.fail(BufferPhase::InvalidAudio, "Stream endet in einem unvollständigen Audioframe."); s.ended = true; s.changed.notify_all(); }
void TimeshiftBuffer::close() {
    auto &s = *state_; std::lock_guard<std::mutex> lock(s.mutex);
    if (s.closed) return;
    s.closed = true; s.ended = true; s.pending.clear();
    if (s.phase == BufferPhase::Off || s.phase == BufferPhase::Warming || s.phase == BufferPhase::Ready) s.phase = BufferPhase::Closed;
    s.changed.notify_all();
}
TimeshiftReader::TimeshiftReader(std::shared_ptr<TimeshiftState> state, std::shared_ptr<Cursor> cursor) : state_(std::move(state)), cursor_(std::move(cursor)) {}
TimeshiftReader::~TimeshiftReader() { cancel(); }
void TimeshiftReader::cancel() { std::lock_guard<std::mutex> lock(state_->mutex); cursor_->cancelled = true; cursor_->segment.reset(); state_->changed.notify_all(); }
double TimeshiftReader::inputStart() const { return cursor_->input; }
double TimeshiftReader::outputStart() const { return cursor_->output; }
QStringList TimeshiftReader::mediaOptions() const {
    const int frames = int(std::llround((cursor_->output - cursor_->input) / cursor_->frameDuration));
    const double skipMilliseconds = (frames + cursor_->correction) * cursor_->frameDuration * 1000;
    // ADTS benötigt die erste Millisekunde hinter der Framegrenze. Abrunden
    // kann bei libVLC 3.0.20 einen vollständigen AAC-Frame zusätzlich ausgeben.
    const int milliseconds = cursor_->codec == "aac" ? int(std::ceil(skipMilliseconds - epsilon)) : int(std::floor(skipMilliseconds + epsilon));
    return {":demux=" + (cursor_->codec == "mp3" ? QString("mpga") : QString("aac")), ":file-caching=1000", QString(":audio-desync=-%1").arg(milliseconds)};
}
ssize_t TimeshiftReader::read(unsigned char *output, size_t count) {
    if (!count) return 0;
    if (!output) return -1;
    auto &s = *state_; std::unique_lock<std::mutex> lock(s.mutex);
    while (true) {
        if (cursor_->cancelled || s.closed) return 0;
        if (s.failed()) return -1;
        auto segment = cursor_->segment;
        if (!segment) return 0;
        if (cursor_->offset < segment->bytes) {
            const size_t wanted = std::min<size_t>({count, 65536, size_t(segment->bytes - cursor_->offset)});
            ssize_t result;
            do { result = pread(segment->fd, output, wanted, cursor_->offset); } while (result < 0 && errno == EINTR);
            if (result <= 0) { s.fail(BufferPhase::IOError, "Puffersegment kann nicht gelesen werden."); return -1; }
            cursor_->offset += result; return result;
        }
        const auto current = std::find(s.segments.begin(), s.segments.end(), segment);
        if (current == s.segments.end()) { s.fail(BufferPhase::ReaderOverrun, "Der Hörpunkt ist nicht mehr im Puffer."); return -1; }
        const auto next = std::next(current);
        if (next != s.segments.end()) { cursor_->segment = *next; cursor_->offset = 0; continue; }
        if (s.ended) return 0;
        s.changed.wait(lock);
    }
}
libvlc_media_t *TimeshiftReader::createMedia(libvlc_instance_t *instance) {
    if (!instance) return nullptr;
    // VLC besitzt keine Destruktorfunktion für das opaque-Argument. Der Aufrufer
    // hält deshalb den Reader bis nach stop() und media_release() am Leben.
    auto *media = libvlc_media_new_callbacks(instance,
        [](void *opaque, void **out, uint64_t *size) -> int { *out = opaque; *size = UINT64_MAX; return 0; },
        [](void *opaque, unsigned char *bytes, size_t count) -> ssize_t { return static_cast<TimeshiftReader *>(opaque)->read(bytes, count); },
        nullptr, [](void *) {}, this);
    if (media) for (const auto &option : mediaOptions()) libvlc_media_add_option(media, option.toUtf8().constData());
    return media;
}
}
