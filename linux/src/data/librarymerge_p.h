#pragma once

#include "codec_p.h"
#include <QJsonObject>

namespace Mucke::LibraryMerge {
using DataCodec::Library;

struct Row {
    QString key, kind, status, localID, duplicateID;
    int incomingIndex;
};

struct Plan {
    Library incoming;
    QVector<Row> rows;
};

struct Draft {
    Plan plan;
    QJsonObject presentation;
};

Draft prepare(const Library &library, Library incoming);
Library apply(const Library &library, const Plan &plan, const QJsonObject &choices);
} // namespace Mucke::LibraryMerge
