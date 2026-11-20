#pragma once

#include <QJsonObject>
#include <optional>

class QWidget;

namespace Mucke {
std::optional<QJsonObject> reviewLibraryImport(QWidget *parent, const QJsonObject &preview);
} // namespace Mucke
