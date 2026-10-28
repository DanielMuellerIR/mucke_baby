#include "librarystore.h"
#include "codec_p.h"
#include "messages_p.h"
#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLockFile>
#include <QSaveFile>
#include <QSet>
#include <QMap>
#include <QStandardPaths>
#include <sys/stat.h>
#include <functional>
#include <algorithm>
using namespace Mucke::DataCodec;
namespace Mucke {
namespace {
constexpr qint64 historyByteLimit = 64LL * 1024 * 1024;
// Bekannte V3-Felder: höchstens 14.848 UTF-8-Textbytes, jeweils maximal doppelt
// JSON-escaped, plus konservative 2.048 Bytes für UUIDs, Daten, Schlüssel und Layout.
// Unbekannte Provenienzfelder bleiben erhalten; dafür gilt zusätzlich das exakte Dump-Limit.
static_assert((2LL * (6400 + 8448) + 2048) * 2000 + 2 < historyByteLimit);
QByteArray readFile(const QString &path, qint64 limit = 16 * 1024 * 1024) {
    QFileInfo info(path);
    if (!info.exists() && !info.isSymLink())
        return {};
    require(info.isFile() && !info.isSymLink() && info.size() <= limit,
            "The data file is not a regular file or is too large.");
    QFile f(path);
    require(f.open(QIODevice::ReadOnly), "The data file could not be read.");
    auto b = f.read(limit + 1);
    require(b.size() <= limit && f.error() == QFileDevice::NoError, "The data file could not be read.");
    return b;
}
bool saveFile(const QString &path, const QByteArray &b) {
    QSaveFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(b) == b.size() && f.commit();
}
Json localDocument(const Library &l) {
    auto j = arrays(l);
    j["format"] = "mucke-baby-linux-library";
    j["formatVersion"] = 1;
    return j;
}
bool sameLibrary(const Library &left, const Library &right) {
    if (left.stations.size() != right.stations.size() || left.groups.size() != right.groups.size() ||
        left.bookmarks.size() != right.bookmarks.size())
        return false;
    const auto sameStation = [](const Station &a, const Station &b) {
        return a.id == b.id && a.name == b.name && a.url == b.url && a.enabled == b.enabled &&
               a.favorite == b.favorite && a.radioBrowserID == b.radioBrowserID;
    };
    const auto sameGroup = [](const Group &a, const Group &b) {
        return a.id == b.id && a.name == b.name && a.stationIDs == b.stationIDs;
    };
    const auto sameBookmark = [](const Track &a, const Track &b) {
        return a.id == b.id && a.station == b.station && a.raw == b.raw && a.artist == b.artist &&
               a.title == b.title &&
               (a.heardAt.isValid() ? a.heardAt : a.receivedAt) ==
                   (b.heardAt.isValid() ? b.heardAt : b.receivedAt) &&
               a.savedAt == b.savedAt && a.recognition == b.recognition;
    };
    return std::equal(left.stations.begin(), left.stations.end(), right.stations.begin(), sameStation) &&
           std::equal(left.groups.begin(), left.groups.end(), right.groups.begin(), sameGroup) &&
           std::equal(left.bookmarks.begin(), left.bookmarks.end(), right.bookmarks.begin(), sameBookmark);
}
void validateLibraryRecords(const Library &library) {
    require(library.stations.size() <= 2000 && library.groups.size() <= 200 &&
            library.bookmarks.size() <= 20000);
    QSet<QString> stationIDs, groupIDs, bookmarkIDs;
    stationIDs.reserve(library.stations.size());
    groupIDs.reserve(library.groups.size());
    bookmarkIDs.reserve(library.bookmarks.size());
    for (const auto &record : library.stations) {
        const auto parsed = parseStation(stationJson(record));
        require(!stationIDs.contains(parsed.id));
        stationIDs.insert(parsed.id);
    }
    for (const auto &record : library.groups) {
        const auto parsed = parseGroup(groupJson(record));
        require(!groupIDs.contains(parsed.id));
        groupIDs.insert(parsed.id);
        for (const auto &id : parsed.stationIDs)
            require(stationIDs.contains(id));
    }
    for (const auto &record : library.bookmarks) {
        const auto parsed = parseBookmark(bookmarkJson(record));
        require(!bookmarkIDs.contains(parsed.id));
        bookmarkIDs.insert(parsed.id);
    }
}
void validateHistoryTrack(const Track &t) {
    uuid(t.id);
    if (!t.stationID.isEmpty())
        uuid(t.stationID);
    if (!t.sessionID.isEmpty())
        uuid(t.sessionID);
    require(textValid(t.station, 256) && textValid(t.raw, 4096) && textValid(t.artist, 1024) &&
                textValid(t.title, 1024),
            "Listening history contains invalid or oversized fields.");
    const auto validDate = [](const QDateTime &value) {
        return value.isValid() && value.toSecsSinceEpoch() >= -62135596800LL &&
               value.toSecsSinceEpoch() <= 253402300799LL;
    };
    require(validDate(t.receivedAt) && (!t.endedAt.isValid() || validDate(t.endedAt)),
            "Listening history contains invalid or oversized fields.");
    if (!t.recognition.is_null())
        validateRecognition(t.recognition);
}
Json historyJson(const Track &t) {
    validateHistoryTrack(t);
    Json j = {{"id", str(t.id)},
              {"station", str(t.station)},
              {"raw", str(t.raw)},
              {"start", timestamp(t.receivedAt)}};
    if (!t.stationID.isEmpty())
        j["stationID"] = str(t.stationID);
    if (!t.artist.isEmpty())
        j["artist"] = str(t.artist);
    if (!t.title.isEmpty())
        j["title"] = str(t.title);
    if (!t.sessionID.isEmpty())
        j["sessionID"] = str(t.sessionID);
    if (t.endedAt.isValid())
        j["end"] = timestamp(t.endedAt);
    if (t.placeholder)
        j["placeholder"] = true;
    if (!t.recognition.is_null())
        j["recognition"] = t.recognition;
    return j;
}
Track parseHistory(const Json &j) {
    Track t;
    t.id = uuid(requiredString(j, "id"));
    t.station = requiredString(j, "station");
    t.raw = requiredString(j, "raw");
    t.artist = optionalString(j, "artist");
    t.title = optionalString(j, "title");
    t.stationID = optionalString(j, "stationID");
    t.sessionID = optionalString(j, "sessionID");
    t.receivedAt = date(requiredString(j, "start"));
    t.heardAt = t.receivedAt;
    t.endedAt = optionalDate(j, "end");
    t.placeholder = flag(j, "placeholder", false);
    if (j.contains("recognition") && !j["recognition"].is_null()) {
        validateRecognition(j["recognition"]);
        t.recognition = j["recognition"];
    }
    validateHistoryTrack(t);
    return t;
}
QJsonObject validateSettings(QJsonObject patch) {
    for (const auto *key : {"recordingEnabled", "timeshiftEnabled", "equalizerEnabled", "closeToTray"})
        if (patch.contains(key))
            require(patch[key].isBool(), "A setting has an invalid type.");
    if (patch.contains("quickSlots")) {
        require(patch["quickSlots"].isArray() && patch["quickSlots"].toArray().size() == 5,
                "Exactly five quick slots are required.");
        for (const auto &value : patch["quickSlots"].toArray())
            if (!value.isNull()) {
                require(value.isString(), "Invalid quick slot.");
                uuid(value.toString());
            }
    }
    if (patch.contains("language"))
        require(QStringList{"de", "en", "system"}.contains(patch["language"].toString()),
                "Invalid language setting.");
    if (patch.contains("autostart"))
        require(QStringList{"none", "last", "selected"}.contains(patch["autostart"].toString()),
                "Invalid startup setting.");
    if (patch.contains("equalizerBands")) {
        require(patch["equalizerBands"].isArray() && patch["equalizerBands"].toArray().size() == 10,
                "Exactly ten equalizer bands are required.");
        for (const auto &value : patch["equalizerBands"].toArray())
            require(value.isDouble() && std::isfinite(value.toDouble()), "Invalid equalizer value.");
    }
    if (patch.contains("equalizerPreamp"))
        require(patch["equalizerPreamp"].isDouble() && std::isfinite(patch["equalizerPreamp"].toDouble()),
                "Invalid equalizer value.");
    if (patch.contains("quickSlots")) {
        QJsonArray normalized;
        for (const auto &value : patch["quickSlots"].toArray())
            normalized.append(value.isNull() ? QJsonValue(QJsonValue::Null)
                                             : QJsonValue(uuid(value.toString())));
        patch["quickSlots"] = normalized;
    }
    return patch;
}
QString description(const Station &s) {
    return s.name + "\n" + s.url + "\n" +
           (s.enabled ? localizedDataMessage(QObject::tr("Visible"))
                      : localizedDataMessage(QObject::tr("Hidden"))) +
           " · " +
           (s.favorite ? localizedDataMessage(QObject::tr("Favorite"))
                       : localizedDataMessage(QObject::tr("Not a favorite")));
}
QString description(const Group &g) { return g.name + "\n" + g.stationIDs.join(", "); }
QString description(const Track &t) {
    QString s = t.raw + "\n" + t.artist + " · " + t.title + "\n" + t.station + "\n" +
                t.heardAt.toString(Qt::ISODateWithMs) + "\n" + t.savedAt.toString(Qt::ISODateWithMs);
    if (!t.recognition.is_null())
        s += "\n" + QString::fromStdString(t.recognition.dump());
    return s;
}
struct IdentityMatch {
    int firstIndex = -1;
    int count = 0;
};
struct RecordIndex {
    QHash<QString, int> ids;
    QHash<QString, IdentityMatch> identities;
    QVector<QString> keys;
};
template <class T, class Identity> RecordIndex indexRecords(const QVector<T> &records, Identity identity) {
    RecordIndex result;
    result.ids.reserve(records.size());
    result.identities.reserve(records.size());
    result.keys.reserve(records.size());
    for (int i = 0; i < records.size(); ++i) {
        result.ids.insert(records[i].id, i);
        const auto key = identity(records[i]);
        result.keys.append(key);
        auto &match = result.identities[key];
        if (match.count == 0)
            match.firstIndex = i;
        ++match.count;
    }
    return result;
}
template <class T>
int matchedIndex(const QVector<T> &local, const RecordIndex &localIndex, const RecordIndex &incomingIndex,
                 int incomingPosition, const QString &id) {
    const auto exact = localIndex.ids.constFind(id);
    if (exact != localIndex.ids.cend())
        return exact.value();
    const auto &key = incomingIndex.keys[incomingPosition];
    const auto localMatch = localIndex.identities.constFind(key);
    const auto incomingMatch = incomingIndex.identities.constFind(key);
    if (localMatch == localIndex.identities.cend() || incomingMatch == incomingIndex.identities.cend() ||
        localMatch->count != 1 || incomingMatch->count != 1)
        return -1;
    const int candidate = localMatch->firstIndex;
    // Eine andere importierte UUID darf ihren direkten Treffer nicht verlieren.
    return incomingIndex.ids.contains(local[candidate].id) ? -1 : candidate;
}
template <class T> QHash<QString, int> idIndex(const QVector<T> &records) {
    QHash<QString, int> result;
    result.reserve(records.size());
    for (int i = 0; i < records.size(); ++i)
        result.insert(records[i].id, i);
    return result;
}
template <class T> int byID(const QVector<T> &list, const QString &id) {
    for (int i = 0; i < list.size(); ++i)
        if (list[i].id == id)
            return i;
    return -1;
}
} // namespace
class LibraryStore::Impl {
  public:
    LibraryStore *q;
    QString dir, lastError;
    Library library;
    QVector<Track> history;
    QJsonObject settings;
    std::unique_ptr<QLockFile> lock;
    bool writable = false, historyWritable = false, settingsWritable = false;
    QByteArray libraryBytes, historyBytes, settingsBytes;
    struct Row {
        QString key, kind, status, localID, duplicateID;
        int incomingIndex;
    };
    struct Preview {
        Library incoming;
        QVector<Row> rows;
        QByteArray fingerprint;
    };
    QMap<QString, Preview> previews;
    Impl(LibraryStore *q, QString dir) : q(q), dir(std::move(dir)) {}
    bool fail(QString message) {
        lastError = localizedDataMessage(std::move(message));
        emit q->error(lastError);
        return false;
    }
    QString path(const QString &name) const { return QDir(dir).filePath(name); }
    QByteArray fingerprint() const {
        // Jeder Bibliothekswechsel übernimmt den erfolgreich gespeicherten Bytebestand gemeinsam mit dem
        // Modell.
        return QCryptographicHash::hash(libraryBytes, QCryptographicHash::Sha256);
    }
    bool commit(const Library &next) {
        if (!writable)
            return fail(QObject::tr("The library is read-only. Check the file version, permissions and "
                                    "whether another instance is running."));
        try {
            require(readFile(path("library.json")) == libraryBytes,
                    "The library changed on disk. Reload it before saving.");
            if (!libraryBytes.isNull() && sameLibrary(next, library)) {
                lastError.clear();
                return true;
            }
            validateLibraryRecords(next);
            auto b = bytes(localDocument(next));
            require(b.size() <= 16 * 1024 * 1024, "The library is too large.");
            if (!saveFile(path("library.json"), b))
                return fail(QObject::tr("The library could not be saved."));
            library = next;
            libraryBytes = b;
            lastError.clear();
            return true;
        } catch (const std::exception &e) {
            return fail(QObject::tr("The library could not be saved: %1").arg(QString::fromUtf8(e.what())));
        }
    }
    bool writeHistory(const QVector<Track> &next) {
        if (!historyWritable)
            return fail(QObject::tr("Listening history is read-only."));
        try {
            require(readFile(path("history.json"), historyByteLimit) == historyBytes,
                    "Listening history changed on disk.");
            require(next.size() <= 2000, "Listening history contains too many records.");
            Json a = Json::array();
            for (const auto &t : next)
                a.push_back(historyJson(t));
            auto b = bytes(a);
            require(b.size() <= historyByteLimit, "Listening history exceeds the 64 MiB limit.");
            require(saveFile(path("history.json"), b), "Listening history could not be saved.");
            history = next;
            historyBytes = b;
            emit q->historyChanged();
            return true;
        } catch (const std::exception &e) {
            return fail(QString::fromUtf8(e.what()));
        }
    }
    QByteArray recover(const QString &name, bool &canWrite, std::function<void(const QByteArray &)> parse,
                       qint64 byteLimit = 16 * 1024 * 1024) {
        auto b = readFile(path(name), byteLimit);
        if (b.isNull())
            return b;
        try {
            parse(b);
            return b;
        } catch (const std::exception &) {
            const auto backup =
                path(name) + ".broken-" + QDate::currentDate().toString(Qt::ISODate) + "-" + newID();
            require(canWrite && QFile::rename(path(name), backup),
                    "Damaged data could not be backed up. The original file remains protected.");
            fail(QObject::tr("Damaged data was backed up as %1.").arg(QFileInfo(backup).fileName()));
            return {};
        }
    }
};
LibraryStore::LibraryStore(QString directory, QObject *parent)
    : QObject(parent), d(std::make_unique<Impl>(this, std::move(directory))) {}
LibraryStore::~LibraryStore() = default;
QString LibraryStore::dataDirectory() const { return d->dir; }
QString LibraryStore::lastError() const { return d->lastError; }
QVector<Station> LibraryStore::stations() const { return d->library.stations; }
QVector<Group> LibraryStore::groups() const { return d->library.groups; }
QVector<Track> LibraryStore::history() const { return d->history; }
QVector<Track> LibraryStore::bookmarks() const { return d->library.bookmarks; }
QJsonObject LibraryStore::settings() const { return d->settings; }
Station LibraryStore::station(QString id) const {
    for (const auto &s : d->library.stations)
        if (s.id == id)
            return s;
    return {};
}
bool LibraryStore::load() {
    d->previews.clear();
    d->lastError.clear();
    d->libraryBytes = {};
    d->writable = d->historyWritable = d->settingsWritable = false;
    if (!QDir().mkpath(d->dir))
        return d->fail(tr("The data directory could not be created."));
    if (!d->lock)
        d->lock = std::make_unique<QLockFile>(d->path(".library.lock"));
    d->lock->setStaleLockTime(30000);
    const bool locked = d->lock->isLocked() || d->lock->tryLock(0);
    d->writable = d->historyWritable = d->settingsWritable = locked;
    bool ok = true;
    try {
        const auto existing = readFile(d->path("library.json"));
        if (!existing.isNull()) {
            try {
                const auto j = Json::parse(existing.constData(), existing.constData() + existing.size());
                if (j.is_object() && j.contains("formatVersion") &&
                    (!j["formatVersion"].is_number_integer() || j["formatVersion"] != 1 ||
                     !j.contains("format") || j["format"] != "mucke-baby-linux-library")) {
                    d->writable = false;
                    ok = d->fail(tr("This library uses an unsupported version and remains unchanged."));
                } else
                    d->libraryBytes = d->recover("library.json", d->writable, [&](const QByteArray &b) {
                        auto doc = Json::parse(b.constData(), b.constData() + b.size());
                        require(requiredString(doc, "format") == "mucke-baby-linux-library");
                        require(doc["formatVersion"] == 1);
                        require(doc.contains("groups") && doc.contains("bookmarks"));
                        d->library = parseLibrary(doc);
                    });
            } catch (const std::exception &) {
                d->libraryBytes = d->recover("library.json", d->writable, [&](const QByteArray &b) {
                    auto j = Json::parse(b.constData(), b.constData() + b.size());
                    require(j.is_object());
                    d->library = parseLibrary(j);
                });
            }
        }
        if (d->libraryBytes.isNull() && d->writable) {
            d->library = {};
            QFile seed(":/Resources/seed-stations.example.json");
            if (seed.open(QIODevice::ReadOnly)) {
                const auto b = seed.readAll();
                const auto j = Json::parse(b.constData(), b.constData() + b.size());
                d->library = parseLibrary(j, true);
            }
            if (!d->commit(d->library))
                ok = false;
        }
    } catch (const std::exception &e) {
        d->writable = false;
        ok = d->fail(tr("The library could not be loaded: %1").arg(QString::fromUtf8(e.what())));
    }
    try {
        d->history.clear();
        d->historyBytes = d->recover(
            "history.json", d->historyWritable,
            [&](const QByteArray &b) {
                const auto a = Json::parse(b.constData(), b.constData() + b.size());
                require(a.is_array());
                for (const auto &v : a)
                    d->history.append(parseHistory(v));
                while (d->history.size() > 2000)
                    d->history.removeFirst();
            },
            historyByteLimit);
    } catch (const std::exception &e) {
        d->historyWritable = false;
        ok = d->fail(tr("Listening history could not be loaded: %1").arg(QString::fromUtf8(e.what())));
    }
    try {
        d->settings = {{"recordingEnabled", false},
                       {"timeshiftEnabled", false},
                       {"language", "system"},
                       {"quickSlots", QJsonArray{QJsonValue::Null, QJsonValue::Null, QJsonValue::Null,
                                                 QJsonValue::Null, QJsonValue::Null}}};
        d->settingsBytes = d->recover("settings.json", d->settingsWritable, [&](const QByteArray &b) {
            QJsonParseError e;
            const auto doc = QJsonDocument::fromJson(b, &e);
            require(e.error == QJsonParseError::NoError && doc.isObject());
            const auto saved = validateSettings(doc.object());
            for (auto it = saved.begin(); it != saved.end(); ++it)
                d->settings.insert(it.key(), it.value());
        });
    } catch (const std::exception &e) {
        d->settingsWritable = false;
        ok = d->fail(tr("Settings could not be loaded: %1").arg(QString::fromUtf8(e.what())));
    }
    if (d->historyBytes.isNull())
        d->history.clear();
    if (locked && d->historyWritable && !d->history.isEmpty()) {
        auto next = d->history;
        if (!next.last().endedAt.isValid())
            next.last().endedAt = qMax(next.last().receivedAt, QDateTime::currentDateTimeUtc());
        next.erase(std::remove_if(next.begin(), next.end(),
                                  [](const Track &t) {
                                      return t.endedAt.isValid() && t.receivedAt.msecsTo(t.endedAt) < 20000;
                                  }),
                   next.end());
        if (bytes([&] {
                Json a = Json::array();
                for (const auto &t : next)
                    a.push_back(historyJson(t));
                return a;
            }()) != d->historyBytes &&
            !d->writeHistory(next))
            ok = false;
    }
    if (!locked)
        ok = d->fail(tr("Another instance is using this library. Changes are disabled."));
    emit libraryChanged();
    emit bookmarksChanged();
    emit historyChanged();
    emit settingsChanged();
    return ok;
}
bool LibraryStore::saveStation(Station s) {
    try {
        if (s.id.isEmpty())
            s.id = newID();
        s = parseStation(stationJson(s));
        auto next = d->library;
        int i = byID(next.stations, s.id);
        if (i < 0)
            next.stations.append(s);
        else
            next.stations[i] = s;
        if (!d->commit(next))
            return false;
        emit libraryChanged();
        return true;
    } catch (const std::exception &e) {
        return d->fail(QString::fromUtf8(e.what()));
    }
}
bool LibraryStore::removeStation(QString id) {
    auto next = d->library;
    int i = byID(next.stations, id);
    if (i < 0)
        return false;
    next.stations.removeAt(i);
    for (auto &g : next.groups)
        g.stationIDs.removeAll(id);
    if (!d->commit(next))
        return false;
    emit libraryChanged();
    return true;
}
bool LibraryStore::setStationOrder(QStringList ids) {
    if (ids.size() != d->library.stations.size() ||
        QSet<QString>(ids.begin(), ids.end()).size() != ids.size())
        return d->fail(tr("The station order is invalid."));
    auto next = d->library;
    next.stations.clear();
    for (const auto &id : ids) {
        int i = byID(d->library.stations, id);
        if (i < 0)
            return d->fail(tr("The station order is invalid."));
        next.stations.append(d->library.stations[i]);
    }
    if (!d->commit(next))
        return false;
    emit libraryChanged();
    return true;
}
bool LibraryStore::saveGroup(Group g) {
    try {
        if (g.id.isEmpty())
            g.id = newID();
        g = parseGroup(groupJson(g));
        auto next = d->library;
        int i = byID(next.groups, g.id);
        if (i < 0)
            next.groups.append(g);
        else
            next.groups[i] = g;
        if (!d->commit(next))
            return false;
        emit libraryChanged();
        return true;
    } catch (const std::exception &e) {
        return d->fail(QString::fromUtf8(e.what()));
    }
}
bool LibraryStore::removeGroup(QString id) {
    auto next = d->library;
    int i = byID(next.groups, id);
    if (i < 0)
        return false;
    next.groups.removeAt(i);
    if (!d->commit(next))
        return false;
    emit libraryChanged();
    return true;
}
bool LibraryStore::saveSettings(QJsonObject patch) {
    if (!d->settingsWritable)
        return d->fail(tr("Settings are read-only."));
    try {
        require(readFile(d->path("settings.json")) == d->settingsBytes, "Settings changed on disk.");
        auto next = d->settings;
        patch = validateSettings(patch);
        for (auto it = patch.begin(); it != patch.end(); ++it)
            next.insert(it.key(), it.value());
        auto b = QJsonDocument(next).toJson(QJsonDocument::Indented);
        require(saveFile(d->path("settings.json"), b), "Settings could not be saved.");
        d->settings = next;
        d->settingsBytes = b;
        emit settingsChanged();
        return true;
    } catch (const std::exception &e) {
        return d->fail(QString::fromUtf8(e.what()));
    }
}
bool LibraryStore::bookmark(Track t) {
    try {
        require(!t.placeholder && !t.raw.trimmed().isEmpty(), "This entry contains no song title.");
        if (t.id.isEmpty())
            t.id = newID();
        if (!t.receivedAt.isValid())
            t.receivedAt = QDateTime::currentDateTimeUtc();
        if (!t.heardAt.isValid())
            t.heardAt = t.receivedAt;
        if (!t.savedAt.isValid())
            t.savedAt = QDateTime::currentDateTimeUtc();
        t = parseBookmark(bookmarkJson(t));
        for (const auto &existing : d->library.bookmarks)
            if (bookmarkIdentity(existing) == bookmarkIdentity(t))
                return true;
        auto next = d->library;
        if (byID(next.bookmarks, t.id) >= 0)
            t.id = newID();
        next.bookmarks.append(t);
        if (!d->commit(next))
            return false;
        emit bookmarksChanged();
        return true;
    } catch (const std::exception &e) {
        return d->fail(QString::fromUtf8(e.what()));
    }
}
bool LibraryStore::removeBookmark(QString id) {
    auto next = d->library;
    int i = byID(next.bookmarks, id);
    if (i < 0)
        return false;
    next.bookmarks.removeAt(i);
    if (!d->commit(next))
        return false;
    emit bookmarksChanged();
    return true;
}
bool LibraryStore::clearHistory() { return d->writeHistory({}); }
void LibraryStore::receiveTrack(Track t) {
    if (t.raw.trimmed().isEmpty() && !t.placeholder)
        return;
    if (!t.receivedAt.isValid())
        t.receivedAt = QDateTime::currentDateTimeUtc();
    auto next = d->history;
    if (!next.isEmpty()) {
        auto &last = next.last();
        if (!last.endedAt.isValid() && last.station == t.station && last.raw == t.raw &&
            last.sessionID == t.sessionID)
            return;
        if (!last.endedAt.isValid())
            last.endedAt = qMax(last.receivedAt, t.receivedAt);
        if (last.receivedAt.msecsTo(last.endedAt) < 5000)
            next.removeLast();
    }
    if (t.id.isEmpty())
        t.id = newID();
    if (!t.heardAt.isValid())
        t.heardAt = t.receivedAt;
    next.append(t);
    while (next.size() > 2000)
        next.removeFirst();
    d->writeHistory(next);
}
void LibraryStore::endReception(QDateTime at) {
    if (d->history.isEmpty() || d->history.last().endedAt.isValid())
        return;
    auto next = d->history;
    auto &t = next.last();
    t.endedAt = qMax(t.receivedAt, at.isValid() ? at : QDateTime::currentDateTimeUtc());
    if (t.receivedAt.msecsTo(t.endedAt) < 5000)
        next.removeLast();
    d->writeHistory(next);
}
QJsonObject LibraryStore::previewImport(QString path) {
    if (!d->writable) {
        d->fail(tr("The library is read-only."));
        return {};
    }
    try {
        require(readFile(d->path("library.json")) == d->libraryBytes,
                "The library changed on disk. Reload it before importing.");
        d->previews.clear();
        Impl::Preview plan;
        plan.incoming = decodeExchange(readFile(path, 8 * 1024 * 1024));
        plan.rows.reserve(plan.incoming.stations.size() + plan.incoming.groups.size() +
                          plan.incoming.bookmarks.size());
        plan.fingerprint = d->fingerprint();
        QJsonArray items;
        QJsonObject counts{{"new", 0}, {"unchanged", 0}, {"conflict", 0}};
        QHash<QString, QString> stationMap;
        stationMap.reserve(d->library.stations.size());
        auto append = [&](QString kind, int index, QString id, int localIndex, const Json &incoming,
                          const Json &local, QString incomingText, QString localText) {
            Impl::Row r;
            r.key = kind + ":" + id;
            r.kind = kind;
            r.incomingIndex = index;
            if (localIndex < 0)
                r.status = "new";
            else {
                r.localID = requiredString(local, "id");
                auto comparable = incoming;
                comparable["id"] = str(r.localID);
                r.status = comparable == local ? "unchanged" : "conflict";
            }
            if (r.status == "conflict")
                r.duplicateID = newID();
            plan.rows.append(r);
            counts[r.status] = counts[r.status].toInt() + 1;
            items.append(QJsonObject{{"key", r.key},
                                     {"kind", kind},
                                     {"status", r.status},
                                     {"local", QJsonObject{{"text", localText}}},
                                     {"incoming", QJsonObject{{"text", incomingText}}},
                                     {"defaultChoice", r.status == "new" ? "incoming" : "local"}});
        };
        const auto &inc = plan.incoming;
        const auto stationIdentity = [](const Station &station) { return normalizedStreamURL(station.url); };
        const auto localStations = indexRecords(d->library.stations, stationIdentity);
        const auto incomingStations = indexRecords(inc.stations, stationIdentity);
        for (int i = 0; i < inc.stations.size(); ++i) {
            const auto &station = inc.stations[i];
            const int match =
                matchedIndex(d->library.stations, localStations, incomingStations, i, station.id);
            stationMap.insert(station.id, match < 0 ? station.id : d->library.stations[match].id);
            append("station", i, station.id, match, stationJson(station),
                   match < 0 ? Json() : stationJson(d->library.stations[match]), description(station),
                   match < 0 ? QString() : description(d->library.stations[match]));
        }
        const auto groupKey = [](const Group &group) { return groupIdentity(group.name); };
        const auto localGroups = indexRecords(d->library.groups, groupKey);
        const auto incomingGroups = indexRecords(inc.groups, groupKey);
        for (int i = 0; i < inc.groups.size(); ++i) {
            const auto &group = inc.groups[i];
            const int match = matchedIndex(d->library.groups, localGroups, incomingGroups, i, group.id);
            auto mapped = group;
            for (auto &id : mapped.stationIDs)
                id = stationMap.value(id);
            append("group", i, group.id, match, groupJson(mapped),
                   match < 0 ? Json() : groupJson(d->library.groups[match]), description(group),
                   match < 0 ? QString() : description(d->library.groups[match]));
        }
        const auto bookmarkKey = [](const Track &track) { return bookmarkIdentity(track); };
        const auto localBookmarks = indexRecords(d->library.bookmarks, bookmarkKey);
        const auto incomingBookmarks = indexRecords(inc.bookmarks, bookmarkKey);
        for (int i = 0; i < inc.bookmarks.size(); ++i) {
            const auto &track = inc.bookmarks[i];
            const int match =
                matchedIndex(d->library.bookmarks, localBookmarks, incomingBookmarks, i, track.id);
            append("bookmark", i, track.id, match, comparableBookmarkJson(track),
                   match < 0 ? Json() : comparableBookmarkJson(d->library.bookmarks[match]),
                   description(track), match < 0 ? QString() : description(d->library.bookmarks[match]));
        }
        const auto token = newID();
        d->previews.clear();
        d->previews.insert(token, std::move(plan));
        return {{"token", token}, {"items", items}, {"counts", counts}};
    } catch (const std::exception &e) {
        d->fail(tr("The import could not be previewed: %1").arg(QString::fromUtf8(e.what())));
        return {};
    }
}
void LibraryStore::discardImport(QJsonObject preview) {
    d->previews.remove(preview.value("token").toString());
}
bool LibraryStore::applyImport(QJsonObject preview, QJsonObject choices) {
    const auto token = preview.value("token").toString();
    if (!d->previews.contains(token))
        return d->fail(tr("The import preview has expired. Open a new preview."));
    try {
        const auto planIterator = d->previews.constFind(token);
        const auto &plan = planIterator.value();
        require(plan.fingerprint == d->fingerprint() && readFile(d->path("library.json")) == d->libraryBytes,
                "The library changed after preview. Open a new preview.");
        QSet<QString> knownKeys;
        for (const auto &row : plan.rows)
            knownKeys.insert(row.key);
        for (auto it = choices.begin(); it != choices.end(); ++it) {
            require(it.value().isString() && knownKeys.contains(it.key()), "Invalid import choice.");
        }
        auto next = d->library;
        QHash<QString, QString> stationMap;
        stationMap.reserve(plan.incoming.stations.size());
        const auto stationPositions = idIndex(next.stations);
        const auto groupPositions = idIndex(next.groups);
        const auto bookmarkPositions = idIndex(next.bookmarks);
        QHash<QString, int> groupNames;
        for (const auto &group : next.groups)
            ++groupNames[groupIdentity(group.name)];
        for (const auto &r : plan.rows) {
            QString choice = choices.value(r.key).toString(r.status == "new" ? "incoming" : "local");
            require(choice == "skip" || choice == "local" || choice == "incoming" || choice == "both",
                    "Invalid import choice.");
            if (r.status == "unchanged")
                choice = "local";
            if (r.kind == "station") {
                auto s = plan.incoming.stations[r.incomingIndex];
                if (!r.localID.isEmpty()) {
                    s.id = choice == "both" ? r.duplicateID : r.localID;
                    stationMap[plan.incoming.stations[r.incomingIndex].id] = s.id;
                    if (choice == "incoming")
                        next.stations[stationPositions.value(r.localID)] = s;
                    else if (choice == "both")
                        next.stations.append(s);
                } else if (choice == "incoming" || choice == "both") {
                    stationMap[s.id] = s.id;
                    next.stations.append(s);
                }
            } else if (r.kind == "group") {
                if (choice == "skip" || choice == "local")
                    continue;
                auto g = plan.incoming.groups[r.incomingIndex];
                QStringList ids;
                for (const auto &id : g.stationIDs)
                    if (stationMap.contains(id))
                        ids.append(stationMap[id]);
                g.stationIDs = ids;
                g.id = choice == "both" && !r.localID.isEmpty() ? r.duplicateID
                       : r.localID.isEmpty()                    ? g.id
                                                                : r.localID;
                if (!r.localID.isEmpty() && choice == "incoming") {
                    const int position = groupPositions.value(r.localID);
                    --groupNames[groupIdentity(next.groups[position].name)];
                    next.groups[position] = g;
                    ++groupNames[groupIdentity(g.name)];
                } else {
                    const auto used = [&](const QString &name) {
                        return groupNames.value(groupIdentity(name)) > 0;
                    };
                    if (used(g.name)) {
                        const auto original = g.name;
                        int n = 1;
                        do {
                            QString base = original, suffix = QString(" (Import %1)").arg(n++);
                            while ((base + suffix).toUtf8().size() > 256 && !base.isEmpty())
                                base.chop(1);
                            g.name = base + suffix;
                        } while (used(g.name));
                    }
                    next.groups.append(g);
                    ++groupNames[groupIdentity(g.name)];
                }
            } else {
                if (choice == "skip" || choice == "local")
                    continue;
                auto t = plan.incoming.bookmarks[r.incomingIndex];
                t.id = choice == "both" && !r.localID.isEmpty() ? r.duplicateID
                       : r.localID.isEmpty()                    ? t.id
                                                                : r.localID;
                if (!r.localID.isEmpty() && choice == "incoming")
                    next.bookmarks[bookmarkPositions.value(r.localID)] = t;
                else
                    next.bookmarks.append(t);
            }
        }
        if (!d->commit(next))
            return false;
        d->previews.clear();
        emit libraryChanged();
        emit bookmarksChanged();
        return true;
    } catch (const std::exception &e) {
        return d->fail(tr("The import could not be saved: %1").arg(QString::fromUtf8(e.what())));
    }
}
namespace {
bool protectedDestination(const QString &path, const QStringList &directories) {
    const QFileInfo target(path);
    QString canonical = target.canonicalFilePath();
    if (canonical.isEmpty())
        canonical = QDir(target.absolutePath()).canonicalPath() + "/" + target.fileName();
    if (target.isSymLink() || (target.exists() && !target.isFile()))
        return true;
    struct stat targetStat{};
    const bool exists = ::stat(QFile::encodeName(path).constData(), &targetStat) == 0;
    for (const auto &directory : directories) {
        QString root = QFileInfo(directory).canonicalFilePath();
        if (root.isEmpty())
            root = QDir::cleanPath(QFileInfo(directory).absoluteFilePath());
        if (canonical == root || canonical.startsWith(root + "/"))
            return true;
        if (!exists)
            continue;
        // Auch ein außerhalb liegender Hardlink darf keine Nutzerdaten ersetzen.
        QDirIterator files(directory, QDir::Files | QDir::Hidden | QDir::NoSymLinks,
                           QDirIterator::Subdirectories);
        while (files.hasNext()) {
            struct stat sourceStat{};
            const auto source = files.next();
            if (::stat(QFile::encodeName(source).constData(), &sourceStat) == 0 &&
                sourceStat.st_dev == targetStat.st_dev && sourceStat.st_ino == targetStat.st_ino)
                return true;
        }
    }
    return false;
}
QString recordingDirectory(const QJsonObject &settings) {
    const auto configured = settings.value("recordingsDirectory").toString();
    if (!configured.isEmpty())
        return configured;
    auto music = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    if (music.isEmpty())
        music = QDir::homePath() + "/Music";
    return music + "/MuckeBaby/Aufnahmen";
}
} // namespace
bool LibraryStore::exportLibrary(QString path) {
    try {
        require(!protectedDestination(path, {d->dir, recordingDirectory(d->settings)}),
                "Choose an export destination outside the application data and recording directories.");
        auto j = arrays(d->library);
        parseLibrary(j);
        j["format"] = "mucke-baby-library";
        j["formatVersion"] = version(d->library);
        j["exportedAt"] = timestamp(QDateTime::currentDateTimeUtc());
        auto b = bytes(j);
        require(b.size() <= 8 * 1024 * 1024, "The exchange file exceeds 8 MiB.");
        require(saveFile(path, b), "The export could not be saved.");
        return true;
    } catch (const std::exception &e) {
        return d->fail(QString::fromUtf8(e.what()));
    }
}
bool LibraryStore::exportBookmarks(QString path, bool csv, const QStringList *selection) {
    try {
        require(!protectedDestination(path, {d->dir, recordingDirectory(d->settings)}),
                "Choose an export destination outside the application data and recording directories.");
        const auto &bookmarks = d->library.bookmarks;
        QVector<qsizetype> indices;
        if (selection) {
            QHash<QString, qsizetype> indexByID;
            for (qsizetype i = 0; i < bookmarks.size(); ++i) indexByID.insert(bookmarks.at(i).id, i);
            QSet<QString> seen;
            for (const auto &id : *selection) {
                if (indexByID.contains(id) && !seen.contains(id)) {
                    seen.insert(id);
                    indices.append(indexByID.value(id));
                }
            }
        } else {
            for (qsizetype i = 0; i < bookmarks.size(); ++i) indices.append(i);
        }
        QString text;
        bool recognition = false, listening = false;
        for (const auto index : indices) {
            const auto &t = bookmarks.at(index);
            if (!t.recognition.is_null()) {
                recognition = true;
                if (t.recognition.contains("listening") && !t.recognition["listening"].is_null())
                    listening = true;
            }
        }
        auto quote = [](QString s) {
            const auto trimmed = s.trimmed();
            if (!trimmed.isEmpty() && QString("=+-@").contains(trimmed.front()))
                s.prepend('\'');
            s.replace('"', "\"\"");
            return '"' + s + '"';
        };
        if (csv)
            text = "artist,title,original,station,heard_at,saved_at" +
                   QString(recognition
                               ? ",source,recognized_at,station_id,original_icy,shazam_id,apple_music_url"
                               : "") +
                   QString(listening ? ",output_id,output_revision,buffer_position,audio_received_at" : "") +
                   "\r\n";
        for (const auto index : indices) {
            const auto &t = bookmarks.at(index);
            QStringList fields;
            if (csv)
                fields = {t.artist,
                          t.title.isEmpty() ? t.raw : t.title,
                          t.raw,
                          t.station,
                          t.heardAt.toUTC().toString(Qt::ISODate),
                          t.savedAt.toUTC().toString(Qt::ISODate)};
            else
                fields = {t.raw, t.station, t.heardAt.toUTC().toString(Qt::ISODate),
                          t.savedAt.toUTC().toString(Qt::ISODate)};
            if (recognition) {
                QStringList extra;
                const auto &r = t.recognition;
                for (const auto *key :
                     {"source", "recognizedAt", "stationID", "originalICY", "shazamID", "appleMusicURL"})
                    extra.append(r.is_object() ? optionalString(r, key) : QString());
                if (csv)
                    fields += extra;
                else if (!r.is_null()) {
                    fields.prepend(t.artist + " – " + t.title);
                    for (int i = 0; i < extra.size(); ++i)
                        fields.append(QStringList{"source", "recognized_at", "station_id", "original_icy",
                                                  "shazam_id", "apple_music_url"}[i] +
                                      ": " + extra[i]);
                }
            }
            if (listening) {
                QStringList extra;
                const auto &r = t.recognition;
                const Json l = r.is_object() && r.contains("listening") ? r["listening"] : Json();
                extra.append(l.is_object() ? optionalString(l, "outputID") : QString());
                extra.append(l.is_object() ? QString::fromStdString(l["revision"].dump()) : QString());
                extra.append(l.is_object() && l.contains("position") && !l["position"].is_null()
                                 ? QString::fromStdString(l["position"].dump())
                                 : QString());
                extra.append(l.is_object() ? optionalString(l, "receivedAt") : QString());
                if (csv)
                    fields += extra;
                else if (l.is_object()) {
                    for (int i = 0; i < extra.size(); ++i)
                        fields.append(QStringList{"output_id", "output_revision", "buffer_position",
                                                  "audio_received_at"}[i] +
                                      ": " + extra[i]);
                }
            }
            if (csv) {
                for (auto &f : fields)
                    f = quote(f);
                text += fields.join(',') + "\r\n";
            } else
                text += fields.join('\n') + "\n\n";
        }
        require(saveFile(path, text.toUtf8()), "The bookmark export could not be saved.");
        return true;
    } catch (const std::exception &e) {
        return d->fail(QString::fromUtf8(e.what()));
    }
}
} // namespace Mucke
