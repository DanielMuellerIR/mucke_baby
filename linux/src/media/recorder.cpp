#include "recorder.h"
#include <QDir>
#include <QFileInfo>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QSet>
#include <QMap>
#include <cmath>
#include <algorithm>
#include <utility>
#include <QUuid>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <cerrno>
namespace Mucke::MediaPrivate {
static QString identifier() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
static QString statusText(const char *en, const char *de) { return QString::fromUtf8(QLocale().language() == QLocale::German ? de : en); }
static QDateTime date(const QJsonValue &value) { return QDateTime::fromString(value.toString(), Qt::ISODateWithMs); }
static bool plainName(const QString &file) { return !file.isEmpty() && !file.startsWith('.') && !file.contains('/') && !file.contains('\\') && !file.contains(QChar(0)); }
// 0 bedeutet unvollständig, -1 ungültig, 1 vollständige initiale Codec-Header.
static int completeHeader(const QByteArray &bytes, const QString &extension) {
    if (extension == "flac") {
        qsizetype offset = 4;
        while (offset + 4 <= bytes.size()) {
            const auto *p = reinterpret_cast<const unsigned char *>(bytes.constData() + offset);
            const qsizetype size = (p[1] << 16) | (p[2] << 8) | p[3];
            if (offset == 4 && ((p[0] & 0x7f) != 0 || size != 34)) return -1;
            if (offset + 4 + size > bytes.size()) return 0;
            offset += 4 + size;
            if (p[0] & 0x80) return 1;
        }
        return 0;
    }
    if (extension != "ogg") return 1;
    qsizetype offset = 0; int packets = 0, required = 0; QByteArray packet;
    while (offset + 27 <= bytes.size()) {
        if (bytes.mid(offset, 4) != "OggS" || bytes[offset + 4] != 0) return -1;
        const auto *p = reinterpret_cast<const unsigned char *>(bytes.constData() + offset);
        const int segments = p[26];
        if (offset + 27 + segments > bytes.size()) return 0;
        qsizetype payload = offset + 27 + segments, end = payload;
        for (int i = 0; i < segments; ++i) end += p[27 + i];
        if (end > bytes.size()) return 0;
        for (int i = 0; i < segments; ++i) {
            const int length = p[27 + i]; packet.append(bytes.constData() + payload, length); payload += length;
            if (packet.size() > 256 * 1024) return -1;
            if (length < 255) {
                if (packets == 0) {
                    if (packet.startsWith("OpusHead") && packet.size() >= 19) required = 2;
                    else if (packet.startsWith(QByteArray("\x01vorbis", 7)) && packet.size() >= 30) required = 3;
                    else return -1;
                } else if ((required == 2 && packets == 1 && !packet.startsWith("OpusTags"))
                    || (required == 3 && packets == 1 && !packet.startsWith(QByteArray("\x03vorbis", 7)))
                    || (required == 3 && packets == 2 && !packet.startsWith(QByteArray("\x05vorbis", 7)))) return -1;
                ++packets; packet.clear(); if (packets >= required) return 1;
            }
        }
        offset = end;
    }
    return 0;
}
Recorder::Recorder(QString directory, std::function<QDateTime()> clock) : root(QDir(directory).absolutePath()), clock(std::move(clock)) {}
QDateTime Recorder::now() const { return clock ? clock() : QDateTime::currentDateTimeUtc(); }
void Recorder::initialize() {
    if (rootFD >= 0) return;
    if (!QDir().mkpath(root) || QFileInfo(root).isSymLink()) { message = statusText("Recording directory unavailable", "Aufnahmeordner nicht verfügbar"); return; }
    rootFD = ::open(QFile::encodeName(root).constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    indexReady = rootFD >= 0 && load();
    if (!indexReady) message = statusText("Recording index unavailable; existing audio was preserved", "Aufnahmeindex nicht verfügbar; vorhandene Audiodateien bleiben erhalten");
}
Recorder::~Recorder() { finish(); if (rootFD >= 0) ::close(rootFD); }
bool Recorder::load() {
    int fd = ::openat(rootFD, "index.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT;
    struct stat info{};
    if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > 32 * 1024 * 1024) { ::close(fd); return false; }
    QByteArray contents(info.st_size, '\0');
    qint64 offset = 0;
    while (offset < contents.size()) { const ssize_t count = ::read(fd, contents.data() + offset, size_t(contents.size() - offset)); if (count <= 0) { ::close(fd); return false; } offset += count; }
    ::close(fd);
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(contents, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject() || document.object().value("version").toInt() != 1 || !document.object().value("recordings").isArray()) return false;
    const QJsonArray array = document.object().value("recordings").toArray();
    const auto savedBoundaries = document.object().value("currentBoundaries").toArray();
    if (array.size() > 8192) return false;
    QSet<QString> seenIDs, seenFiles;
    for (const QJsonValue &value : array) {
        const QJsonObject object = value.toObject();
        Recording r;
        r.id = object.value("id").toString(); r.file = object.value("file").toString(); r.station = object.value("station").toString();
        r.sessionID = object.value("sessionID").toString(); r.ext = object.value("ext").toString();
        r.start = date(object.value("start")); r.end = date(object.value("end")); r.receivedEnd = date(object.value("receivedEnd"));
        if (r.id.isEmpty() || !plainName(r.file) || !r.start.isValid() || seenIDs.contains(r.id) || seenFiles.contains(r.file)
            || !QStringList{"mp3", "aac", "ogg", "flac"}.contains(r.ext) || !r.file.endsWith("." + r.ext)) continue;
        struct stat fileInfo{};
        if (::fstatat(rootFD, QFile::encodeName(r.file).constData(), &fileInfo, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(fileInfo.st_mode)) continue;
        r.bytes = fileInfo.st_size;
        // Recovery übernimmt nur die vorhandene Länge; Dateien werden dabei niemals geöffnet oder gekürzt.
        if (!r.end.isValid()) {
            const QDateTime modified = QDateTime::fromSecsSinceEpoch(fileInfo.st_mtime, Qt::UTC);
            if (!r.receivedEnd.isValid() || modified > r.receivedEnd) r.receivedEnd = modified;
            r.end = r.receivedEnd >= r.start ? r.receivedEnd : r.start;
        }
        r.active = false;
        seenIDs.insert(r.id); seenFiles.insert(r.file); entries.append(r);
    }
    QMap<QString, qint64> sizes;
    for (const auto &r : std::as_const(entries)) sizes.insert(r.id, r.bytes);
    QSet<QString> firstBoundary;
    for (qsizetype i = std::max<qsizetype>(0, savedBoundaries.size() - 4096); i < savedBoundaries.size(); ++i) {
        const auto object = savedBoundaries[i].toObject(); RecordingBoundary b;
        b.recordingID = object.value("recordingID").toString();
        const double offset = object.value("byteOffset").toDouble(object.value("bytes").toDouble(-1));
        if (!sizes.contains(b.recordingID) || !std::isfinite(offset) || offset < 0 || offset > double(sizes.value(b.recordingID)) || std::floor(offset) != offset) continue;
        b.trackID = object.value("trackID").toString(); b.raw = object.value("raw").toString(object.value("title").toString()).left(4096);
        b.byteOffset = qint64(offset); b.receivedAt = date(object.value("receivedAt")); b.captureStart = object.value("captureStart").toBool(false);
        b.partialStart = object.contains("partialStart") ? object.value("partialStart").toBool() : !firstBoundary.contains(b.recordingID);
        firstBoundary.insert(b.recordingID); boundaries.append(b);
    }
    return true;
}
bool Recorder::persist() {
    if (rootFD < 0) return false;
    QJsonArray array;
    for (const Recording &r : entries) array.append(QJsonObject{{"id", r.id}, {"file", r.file}, {"station", r.station}, {"sessionID", r.sessionID}, {"ext", r.ext}, {"start", r.start.toString(Qt::ISODateWithMs)}, {"end", r.end.toString(Qt::ISODateWithMs)}, {"receivedEnd", r.receivedEnd.toString(Qt::ISODateWithMs)}, {"bytes", double(r.bytes)}, {"active", r.active}});
    QJsonArray markers;
    for (const auto &b : std::as_const(boundaries)) markers.append(QJsonObject{{"recordingID", b.recordingID}, {"trackID", b.trackID}, {"title", b.raw}, {"bytes", double(b.byteOffset)}, {"receivedAt", b.receivedAt.toString(Qt::ISODateWithMs)}, {"captureStart", b.captureStart}, {"partialStart", b.partialStart}});
    const QByteArray bytes = QJsonDocument(QJsonObject{{"version", 1}, {"recordings", array}, {"currentBoundaries", markers}}).toJson(QJsonDocument::Compact);
    if (bytes.size() > 32 * 1024 * 1024) return false;
    const QByteArray temporary = QFile::encodeName("index-" + identifier() + ".tmp");
    const int fd = ::openat(rootFD, temporary.constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    qint64 offset = 0;
    while (offset < bytes.size()) { const ssize_t count = ::write(fd, bytes.constData() + offset, size_t(bytes.size() - offset)); if (count <= 0) break; offset += count; }
    bool ok = offset == bytes.size() && ::fsync(fd) == 0;
    ::close(fd);
    if (ok) ok = ::renameat(rootFD, temporary.constData(), rootFD, "index.json") == 0 && ::fsync(rootFD) == 0;
    if (!ok) ::unlinkat(rootFD, temporary.constData(), 0);
    return ok;
}
void Recorder::beginSession(QString name, QString id) {
    finish(); station = name; session = id; initialAudio = true; headerRequired = false; rolloverHeaderPending = false; prefix.clear(); extension.clear(); currentTrack = {}; firstTitle = true;
    message = !indexReady ? statusText("Recording index unavailable; existing audio was preserved", "Aufnahmeindex nicht verfügbar; vorhandene Audiodateien bleiben erhalten")
        : requested ? statusText("Waiting for stream audio", "Warte auf Stream-Audio") : statusText("Recording off", "Aufnahme aus");
}
void Recorder::setEnabled(bool value) {
    requested = value;
    if (!value) { finish(); message = statusText("Recording off", "Aufnahme aus"); }
    else if (!indexReady) message = statusText("Recording index unavailable; existing audio was preserved", "Aufnahmeindex nicht verfügbar; vorhandene Audiodateien bleiben erhalten");
    else message = headerRequired ? statusText("Recording needs a fresh stream header; restart playback", "Aufnahme benötigt einen neuen Stream-Header; Wiedergabe neu starten") : statusText("Waiting for stream audio", "Warte auf Stream-Audio");
}
void Recorder::fail(QString reason) { finish(); message = reason; requested = false; if (changed) changed(); }
void Recorder::checkDisk() {
    if (!requested && !active()) return;
    struct statvfs info{};
    if (rootFD < 0 || ::fstatvfs(rootFD, &info) != 0) { fail(statusText("Cannot check free recording space", "Freier Aufnahmespeicher kann nicht geprüft werden")); return; }
    if (static_cast<long double>(info.f_bavail) * info.f_frsize < 10.0L * 1024 * 1024 * 1024) fail(statusText("Recording stopped: less than 10 GiB free", "Aufnahme gestoppt: weniger als 10 GiB frei"));
    if (active()) {
        if (!persist()) fail(statusText("Cannot update recording index", "Aufnahmeindex kann nicht aktualisiert werden"));
        else if (changed) changed();
    }
    sinceDiskCheck = 0;
}
bool Recorder::startFile(bool partialStart) {
    checkDisk();
    if (!requested || !indexReady || rootFD < 0 || entries.size() >= 8192) return false;
    Recording r; r.id = identifier(); r.station = station; r.sessionID = session; r.ext = extension; r.start = now(); r.active = true;
    r.file = r.start.toString("yyyyMMdd'T'HHmmss'Z'") + "-" + r.id + "." + extension;
    fileFD = ::openat(rootFD, QFile::encodeName(r.file).constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fileFD < 0) { fail(statusText("Cannot create recording file", "Aufnahmedatei kann nicht angelegt werden")); return false; }
    entries.append(r); activeIndex = int(entries.size() - 1);
    if (!persist()) { fail(statusText("Cannot save recording index; recording stopped", "Aufnahmeindex kann nicht gespeichert werden; Aufnahme gestoppt")); return false; }
    pendingCapture = boundary(currentTrack, 0, true, partialStart);
    message = statusText("Recording", "Aufnahme läuft"); if (changed) changed(); return true;
}
void Recorder::audio(const QByteArray &bytes) {
    if (bytes.isEmpty()) return;
    const bool first = initialAudio;
    if (initialAudio) {
        if (prefix.size() + bytes.size() > 256 * 1024) { initialAudio = false; headerRequired = true; message = statusText("Stream codec headers exceed the capture limit", "Stream-Header überschreiten das Aufnahmelimit"); prefix.clear(); if (changed) changed(); return; }
        prefix.append(bytes);
        if (prefix.size() < 16) return;
        if (prefix.startsWith("OggS")) extension = "ogg";
        else if (prefix.startsWith("fLaC")) extension = "flac";
        else if (prefix.startsWith("ID3") || (static_cast<unsigned char>(prefix[0]) == 0xff && (static_cast<unsigned char>(prefix[1]) & 0xe0) == 0xe0))
            extension = static_cast<unsigned char>(prefix[0]) == 0xff && (static_cast<unsigned char>(prefix[1]) & 0xf6) == 0xf0 ? "aac" : "mp3";
        if (extension.isEmpty()) { initialAudio = false; message = statusText("Recording unavailable for this stream format", "Aufnahme für dieses Stream-Format nicht verfügbar"); headerRequired = true; prefix.clear(); if (changed) changed(); return; }
        if (!requested) { initialAudio = false; headerRequired = extension == "ogg" || extension == "flac"; prefix.clear(); return; }
        const int complete = completeHeader(prefix, extension);
        if (complete == 0) return;
        initialAudio = false;
        if (complete < 0) { headerRequired = true; message = statusText("Invalid stream codec headers", "Ungültige Stream-Header"); prefix.clear(); if (changed) changed(); return; }
    }
    if (!requested || headerRequired || extension.isEmpty()) return;
    if (fileFD < 0 && !startFile()) return;
    const QByteArray output = first && !prefix.isEmpty() ? prefix : bytes;
    prefix.clear();
    qint64 offset = 0;
    while (offset < output.size()) { const ssize_t count = ::write(fileFD, output.constData() + offset, size_t(output.size() - offset)); if (count <= 0) { fail(statusText("Recording write failed", "Aufnahmedatei kann nicht geschrieben werden")); return; } offset += count; }
    Recording &r = entries[activeIndex]; const bool firstWrite = r.bytes == 0; r.bytes += output.size(); r.receivedEnd = now(); sinceDiskCheck += output.size();
    if (firstWrite) {
        if (pendingCapture) { appendBoundary(*pendingCapture); pendingCapture.reset(); }
        if (!persist()) { fail(statusText("Cannot save recording metadata", "Aufnahmemetadaten können nicht gespeichert werden")); return; }
        if (changed) changed();
    }
    if (sinceDiskCheck >= 8 * 1024 * 1024) checkDisk();
}
void Recorder::title(const QString &title) {
    Track track; track.id = identifier(); track.raw = title.left(4096); track.title = track.raw; track.receivedAt = now(); track.sessionID = session; track.station = station;
    this->title(track);
}
RecordingBoundary Recorder::boundary(const Track &track, qint64 offset, bool captureStart, bool partialStart) const {
    return {activeIndex >= 0 ? entries[activeIndex].id : QString(), track.id, track.raw.left(4096), offset,
            track.receivedAt.isValid() ? track.receivedAt : now(), captureStart, partialStart};
}
void Recorder::appendBoundary(RecordingBoundary value) {
    if (!boundaries.isEmpty()) {
        const auto &last = boundaries.constLast();
        if (last.recordingID == value.recordingID && !value.trackID.isEmpty() && last.trackID == value.trackID) return;
    }
    boundaries.append(std::move(value)); if (boundaries.size() > 4096) boundaries.removeFirst();
}
void Recorder::title(const Track &track) {
    currentTrack = track; const bool partial = firstTitle; firstTitle = false;
    if (fileFD < 0 || activeIndex < 0) return;
    if (entries[activeIndex].bytes == 0) { pendingCapture = boundary(track, 0, true, partial); return; }
    appendBoundary(boundary(track, entries[activeIndex].bytes, false, partial));
    if (entries[activeIndex].start.secsTo(now()) >= 24 * 60 * 60) {
        finish();
        if (extension == "mp3" || extension == "aac") startFile(false);
        else { headerRequired = true; rolloverHeaderPending = true; message = statusText("Recording rollover needs a fresh stream header", "Neuer Aufnahmeabschnitt benötigt einen neuen Stream-Header"); }
    } else if (!persist()) fail(statusText("Cannot save recording metadata", "Aufnahmemetadaten können nicht gespeichert werden"));
}
void Recorder::finish() {
    pendingCapture.reset(); if (fileFD < 0) return;
    ::fsync(fileFD); ::close(fileFD); fileFD = -1;
    Recording &r = entries[activeIndex]; r.active = false; r.end = r.receivedEnd.isValid() ? r.receivedEnd : r.start;
    activeIndex = -1; message = requested ? statusText("Recording idle", "Aufnahme bereit") : statusText("Recording off", "Aufnahme aus");
    persist(); if (changed) changed();
}
QString Recorder::checkedPath(QString id) const {
    for (const Recording &r : entries) if (r.id == id && plainName(r.file)) {
        struct stat info{};
        if (::fstatat(rootFD, QFile::encodeName(r.file).constData(), &info, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(info.st_mode)) return QDir(root).filePath(r.file);
    }
    return {};
}
bool Recorder::remove(QString id) {
    for (qsizetype i = 0; i < entries.size(); ++i) if (entries[i].id == id && !entries[i].active) {
        if (checkedPath(id).isEmpty() || ::unlinkat(rootFD, QFile::encodeName(entries[i].file).constData(), 0) != 0) return false;
        entries.removeAt(i);
        boundaries.erase(std::remove_if(boundaries.begin(), boundaries.end(), [&](const auto &b) { return b.recordingID == id; }), boundaries.end());
        const bool ok = persist(); if (changed) changed(); return ok;
    }
    return false;
}
int Recorder::openReadFD(QString id) const {
    for (const auto &r : entries) if (r.id == id && !r.active && plainName(r.file)) {
        const int fd = ::openat(rootFD, QFile::encodeName(r.file).constData(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        struct stat info{};
        if (fd >= 0 && ::fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_nlink == 1 && info.st_size > 0) return fd;
        if (fd >= 0) ::close(fd);
    }
    return -1;
}
}
