#pragma once
#include "../types.h"
#include <QTimeZone>
namespace Mucke::HistoryFilter {
inline QDate presetStart(int preset, QDate today) {
    return today.addDays(preset == 2 ? -6 : preset == 3 ? -29 : 0);
}
inline bool overlaps(const Track &track, QDate first, QDate last, QDateTime now,
                     QTimeZone zone = QTimeZone::systemTimeZone()) {
    const QDateTime start = track.heardAt.isValid() ? track.heardAt : track.receivedAt;
    if (!start.isValid() || !first.isValid() || !last.isValid() || last < first)
        return false;
    const QDateTime from(first, QTime(0, 0), zone), through(last.addDays(1), QTime(0, 0), zone);
    const QDateTime end = track.endedAt.isValid() ? track.endedAt : now;
    return start < through && (end > start ? end > from : start >= from);
}
} // namespace Mucke::HistoryFilter
