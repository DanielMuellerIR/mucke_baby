#pragma once
#include "../types.h"
#include <QFile>
#include <QRegularExpression>
#include <QUrl>
#include <QUuid>
#include <QSet>
#include <cmath>
#include <stdexcept>
namespace Mucke::DataCodec {
inline std::string str(const QString &s) { return s.toUtf8().toStdString(); }
inline QString qs(const Json &v) { return QString::fromUtf8(v.get<std::string>()); }
inline void require(bool condition, const char *message = "Invalid library data.") {
    if (!condition)
        throw std::runtime_error(message);
}
inline QString requiredString(const Json &j, const char *key) {
    require(j.contains(key) && j[key].is_string());
    return qs(j[key]);
}
inline QString optionalString(const Json &j, const char *key) {
    if (!j.contains(key) || j[key].is_null())
        return {};
    require(j[key].is_string());
    return qs(j[key]);
}
inline bool flag(const Json &j, const char *key, bool fallback) {
    if (!j.contains(key) || j[key].is_null())
        return fallback;
    require(j[key].is_boolean());
    return j[key].get<bool>();
}
inline QString uuid(const QString &s) {
    static const QRegularExpression re(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    require(re.match(s).hasMatch());
    return s.toLower();
}
inline bool textValid(const QString &s, int limit, bool nonempty = false, bool multiline = true) {
    if (s.toUtf8().size() > limit || (nonempty && s.trimmed().isEmpty()))
        return false;
    for (const auto c : s)
        if (c.category() == QChar::Other_Control && !(multiline && (c == '\t' || c == '\r' || c == '\n')))
            return false;
    return true;
}
inline QDateTime date(const QString &s) {
    static const QRegularExpression re("^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]{"
                                       "1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$");
    const auto m = re.match(s);
    require(m.hasMatch());
    require(QDate::fromString(m.captured(1), Qt::ISODate).isValid());
    require(QTime::fromString(m.captured(2), "HH:mm:ss").isValid());
    if (m.captured(4) != "Z")
        require(m.captured(4).mid(1, 2).toInt() <= 23 && m.captured(4).right(2).toInt() <= 59);
    auto dt = QDateTime::fromString(s, Qt::ISODateWithMs);
    require(dt.isValid() && dt.toSecsSinceEpoch() >= -62135596800LL &&
            dt.toSecsSinceEpoch() <= 253402300799LL);
    return dt;
}
inline QDateTime optionalDate(const Json &j, const char *key) {
    const auto s = optionalString(j, key);
    return s.isEmpty() ? QDateTime{} : date(s);
}
inline std::string timestamp(QDateTime d) {
    require(d.isValid());
    return str(d.toUTC().toString(Qt::ISODateWithMs));
}
inline QString widthFolded(const QString &s) {
    QString result, run;
    auto flush = [&] {
        result += run.normalized(QString::NormalizationForm_KC);
        run.clear();
    };
    for (const auto c : s) {
        if (c.unicode() >= 0xff00 && c.unicode() <= 0xffef)
            run += c;
        else {
            flush();
            result += c;
        }
    }
    flush();
    return result.toCaseFolded();
}
inline QString normalizedText(QString s) { return widthFolded(s.simplified()); }
inline QString groupIdentity(QString s) { return widthFolded(s.trimmed()); }
inline void validateRecognition(const Json &j) {
    require(j.is_object());
    require(requiredString(j, "source") == "shazam");
    date(requiredString(j, "recognizedAt"));
    uuid(requiredString(j, "stationID"));
    require(textValid(requiredString(j, "originalICY"), 4096));
    if (j.contains("shazamID") && !j["shazamID"].is_null())
        require(textValid(requiredString(j, "shazamID"), 256, true, false));
    if (j.contains("appleMusicURL") && !j["appleMusicURL"].is_null()) {
        const QString s = requiredString(j, "appleMusicURL");
        const QUrl u(s, QUrl::StrictMode);
        require(textValid(s, 4096, false, false) && u.isValid() && u.scheme().toLower() == "https" &&
                u.host().toLower() == "music.apple.com" && u.userInfo().isEmpty() &&
                !u.authority(QUrl::FullyEncoded).contains('@') && (u.port() == -1 || u.port() == 443));
    }
    if (j.contains("listening") && !j["listening"].is_null()) {
        const auto &l = j["listening"];
        require(l.is_object());
        uuid(requiredString(l, "outputID"));
        require(l.contains("revision") &&
                (l["revision"].is_number_unsigned() ||
                 (l["revision"].is_number_integer() && l["revision"].get<qint64>() >= 0)));
        bool p = l.contains("position") && !l["position"].is_null(),
             r = l.contains("receivedAt") && !l["receivedAt"].is_null();
        require(p == r);
        if (p) {
            require(l["position"].is_number());
            const auto value = l["position"].get<double>();
            require(std::isfinite(value) && value >= 0);
            date(requiredString(l, "receivedAt"));
        }
    }
}
inline Json stationJson(const Station &s) {
    Json j = {{"id", str(s.id)},
              {"name", str(s.name)},
              {"url", str(s.url)},
              {"enabled", s.enabled},
              {"favorite", s.favorite}};
    if (!s.radioBrowserID.isEmpty())
        j["radioBrowserID"] = str(s.radioBrowserID);
    return j;
}
inline Station parseStation(const Json &j, bool needID = true) {
    require(j.is_object());
    Station s;
    s.id =
        j.contains("id") && !j["id"].is_null() ? uuid(requiredString(j, "id")) : (require(!needID), newID());
    s.name = requiredString(j, "name");
    s.url = requiredString(j, "url");
    require(textValid(s.name, 256, true, false) && s.url.toUtf8().size() <= 4096 && validStreamURL(s.url));
    s.url = normalizedStreamURL(s.url);
    s.enabled = flag(j, "enabled", true);
    s.favorite = flag(j, "favorite", false);
    s.radioBrowserID = optionalString(j, "radioBrowserID");
    if (!s.radioBrowserID.isEmpty())
        s.radioBrowserID = uuid(s.radioBrowserID);
    return s;
}
inline Json groupJson(const Group &g) {
    Json ids = Json::array();
    for (const auto &id : g.stationIDs)
        ids.push_back(str(id));
    return {{"id", str(g.id)}, {"name", str(g.name)}, {"stationIDs", ids}};
}
inline Group parseGroup(const Json &j) {
    Group g;
    g.id = uuid(requiredString(j, "id"));
    g.name = requiredString(j, "name");
    require(textValid(g.name, 256, true, false));
    require(j.contains("stationIDs") && j["stationIDs"].is_array() && j["stationIDs"].size() <= 2000);
    for (const auto &v : j["stationIDs"]) {
        require(v.is_string());
        auto id = uuid(qs(v));
        require(!g.stationIDs.contains(id));
        g.stationIDs.append(id);
    }
    return g;
}
inline Json bookmarkJson(const Track &t) {
    Json j = {{"id", str(t.id)},
              {"station", str(t.station)},
              {"raw", str(t.raw)},
              {"heardAt", timestamp(t.heardAt.isValid() ? t.heardAt : t.receivedAt)},
              {"savedAt", timestamp(t.savedAt)}};
    if (!t.artist.isEmpty())
        j["artist"] = str(t.artist);
    if (!t.title.isEmpty())
        j["title"] = str(t.title);
    if (!t.recognition.is_null())
        j["recognition"] = t.recognition;
    return j;
}
inline Track parseBookmark(const Json &j) {
    Track t;
    t.id = uuid(requiredString(j, "id"));
    t.station = requiredString(j, "station");
    t.raw = requiredString(j, "raw");
    t.artist = optionalString(j, "artist");
    t.title = optionalString(j, "title");
    t.heardAt = date(requiredString(j, "heardAt"));
    t.receivedAt = t.heardAt;
    t.savedAt = date(requiredString(j, "savedAt"));
    require(textValid(t.raw, 4096, true) && textValid(t.station, 256) && textValid(t.artist, 1024) &&
            textValid(t.title, 1024));
    if (j.contains("recognition") && !j["recognition"].is_null()) {
        validateRecognition(j["recognition"]);
        require(!t.title.trimmed().isEmpty());
        t.recognition = j["recognition"];
    }
    return t;
}
inline Json comparableBookmarkJson(const Track &t) {
    auto record = bookmarkJson(t);
    if (t.recognition.is_null())
        return record;
    const auto &r = t.recognition;
    Json normalized = {{"source", r["source"]},
                       {"recognizedAt", timestamp(date(requiredString(r, "recognizedAt")))},
                       {"stationID", str(uuid(requiredString(r, "stationID")))},
                       {"originalICY", r["originalICY"]}};
    for (const auto *key : {"shazamID", "appleMusicURL"})
        if (r.contains(key) && !r[key].is_null())
            normalized[key] = r[key];
    if (r.contains("listening") && !r["listening"].is_null()) {
        const auto &l = r["listening"];
        Json listening = {{"outputID", str(uuid(requiredString(l, "outputID")))},
                          {"revision", l["revision"]}};
        if (l.contains("position") && !l["position"].is_null()) {
            listening["position"] = l["position"];
            listening["receivedAt"] = timestamp(date(requiredString(l, "receivedAt")));
        }
        normalized["listening"] = listening;
    }
    record["recognition"] = normalized;
    return record;
}
inline QString bookmarkIdentity(const Track &t) {
    const QString a = normalizedText(t.artist), title = normalizedText(t.title);
    Json key = Json::array({str(a.isEmpty() || title.isEmpty() ? QString{} : a),
                            str(a.isEmpty() || title.isEmpty() ? normalizedText(t.raw) : title)});
    key.push_back(t.recognition.is_null() ? Json(nullptr)
                                          : Json(str(normalizedText(qs(t.recognition["originalICY"])))));
    return QString::fromStdString(key.dump());
}
struct Library {
    QVector<Station> stations;
    QVector<Group> groups;
    QVector<Track> bookmarks;
};
inline int version(const Library &l) {
    int v = 1;
    for (const auto &t : l.bookmarks)
        if (!t.recognition.is_null()) {
            v = qMax(v, 2);
            if (t.recognition.contains("listening") && !t.recognition["listening"].is_null())
                v = 3;
        }
    return v;
}
inline Json arrays(const Library &l) {
    Json j = {{"stations", Json::array()}, {"groups", Json::array()}, {"bookmarks", Json::array()}};
    for (const auto &s : l.stations)
        j["stations"].push_back(stationJson(s));
    for (const auto &g : l.groups)
        j["groups"].push_back(groupJson(g));
    for (const auto &t : l.bookmarks)
        j["bookmarks"].push_back(bookmarkJson(t));
    return j;
}
inline Library parseLibrary(const Json &j, bool legacyArray = false) {
    Library l;
    const Json &ss = legacyArray ? j : j.at("stations");
    require(ss.is_array() && ss.size() <= 2000);
    QSet<QString> ids;
    for (const auto &v : ss) {
        auto s = parseStation(v, !legacyArray);
        require(!ids.contains(s.id));
        ids.insert(s.id);
        l.stations.append(s);
    }
    if (!legacyArray && j.contains("groups")) {
        require(j["groups"].is_array() && j["groups"].size() <= 200);
        QSet<QString> gs;
        for (const auto &v : j["groups"]) {
            auto g = parseGroup(v);
            require(!gs.contains(g.id));
            gs.insert(g.id);
            for (const auto &id : g.stationIDs)
                require(ids.contains(id));
            l.groups.append(g);
        }
    }
    if (!legacyArray && j.contains("bookmarks")) {
        require(j["bookmarks"].is_array() && j["bookmarks"].size() <= 20000);
        QSet<QString> bs;
        for (const auto &v : j["bookmarks"]) {
            auto t = parseBookmark(v);
            require(!bs.contains(t.id));
            bs.insert(t.id);
            l.bookmarks.append(t);
        }
    }
    return l;
}
inline Library decodeExchange(const QByteArray &bytes) {
    require(bytes.size() <= 8 * 1024 * 1024, "The exchange file exceeds 8 MiB.");
    const auto j = Json::parse(bytes.constData(), bytes.constData() + bytes.size());
    if (j.is_array())
        return parseLibrary(j, true);
    require(j.is_object() && j.contains("formatVersion") && j["formatVersion"].is_number_integer());
    require(j["formatVersion"] == 1 || j["formatVersion"] == 2 || j["formatVersion"] == 3,
            "Unsupported library version.");
    const auto v = j["formatVersion"].get<int>();
    if (!j.contains("format") || j["format"].is_null()) {
        require(v == 2, "Unsupported library version.");
        return parseLibrary(j);
    }
    require(requiredString(j, "format") == "mucke-baby-library" && v >= 1 && v <= 3,
            "Unsupported library version.");
    date(requiredString(j, "exportedAt"));
    require(j.contains("groups") && j.contains("bookmarks"));
    auto l = parseLibrary(j);
    require(version(l) <= v);
    return l;
}
inline QByteArray bytes(const Json &j) {
    const auto s = j.dump(2);
    return QByteArray(s.data(), int(s.size()));
}
} // namespace Mucke::DataCodec
