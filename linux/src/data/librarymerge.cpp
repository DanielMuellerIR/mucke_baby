#include "librarymerge_p.h"
#include "codec_p.h"
#include "messages_p.h"
#include <QHash>
#include <QJsonArray>
#include <QObject>
#include <QSet>

namespace Mucke::LibraryMerge {
namespace {
using namespace DataCodec;

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
} // namespace

Draft prepare(const Library &library, Library incoming) {
    Plan plan{std::move(incoming), {}};
    plan.rows.reserve(plan.incoming.stations.size() + plan.incoming.groups.size() +
                      plan.incoming.bookmarks.size());
    QJsonArray items;
    QJsonObject counts{{"new", 0}, {"unchanged", 0}, {"conflict", 0}};
    QHash<QString, QString> stationMap;
    stationMap.reserve(library.stations.size());
    auto append = [&](QString kind, int index, QString id, int localIndex, const Json &incoming,
                      const Json &local, QString incomingText, QString localText) {
        Row r;
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
    const auto localStations = indexRecords(library.stations, stationIdentity);
    const auto incomingStations = indexRecords(inc.stations, stationIdentity);
    for (int i = 0; i < inc.stations.size(); ++i) {
        const auto &station = inc.stations[i];
        const int match =
            matchedIndex(library.stations, localStations, incomingStations, i, station.id);
        stationMap.insert(station.id, match < 0 ? station.id : library.stations[match].id);
        append("station", i, station.id, match, stationJson(station),
               match < 0 ? Json() : stationJson(library.stations[match]), description(station),
               match < 0 ? QString() : description(library.stations[match]));
    }
    const auto groupKey = [](const Group &group) { return groupIdentity(group.name); };
    const auto localGroups = indexRecords(library.groups, groupKey);
    const auto incomingGroups = indexRecords(inc.groups, groupKey);
    for (int i = 0; i < inc.groups.size(); ++i) {
        const auto &group = inc.groups[i];
        const int match = matchedIndex(library.groups, localGroups, incomingGroups, i, group.id);
        auto mapped = group;
        for (auto &id : mapped.stationIDs)
            id = stationMap.value(id);
        append("group", i, group.id, match, groupJson(mapped),
               match < 0 ? Json() : groupJson(library.groups[match]), description(group),
               match < 0 ? QString() : description(library.groups[match]));
    }
    const auto bookmarkKey = [](const Track &track) { return bookmarkIdentity(track); };
    const auto localBookmarks = indexRecords(library.bookmarks, bookmarkKey);
    const auto incomingBookmarks = indexRecords(inc.bookmarks, bookmarkKey);
    for (int i = 0; i < inc.bookmarks.size(); ++i) {
        const auto &track = inc.bookmarks[i];
        const int match =
            matchedIndex(library.bookmarks, localBookmarks, incomingBookmarks, i, track.id);
        append("bookmark", i, track.id, match, comparableBookmarkJson(track),
               match < 0 ? Json() : comparableBookmarkJson(library.bookmarks[match]),
               description(track), match < 0 ? QString() : description(library.bookmarks[match]));
    }
    return {std::move(plan), {{"items", items}, {"counts", counts}}};
}

Library apply(const Library &library, const Plan &plan, const QJsonObject &choices) {
    QSet<QString> knownKeys;
    for (const auto &row : plan.rows)
        knownKeys.insert(row.key);
    for (auto it = choices.begin(); it != choices.end(); ++it) {
        require(it.value().isString() && knownKeys.contains(it.key()), "Invalid import choice.");
    }
    auto next = library;
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
    return next;
}
} // namespace Mucke::LibraryMerge
