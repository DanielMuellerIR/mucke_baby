#pragma once

#include <QByteArray>
#include <QJsonObject>

namespace Mucke::LibrarySettings {
QJsonObject defaults();
QJsonObject decode(const QByteArray &bytes);
QJsonObject applyPatch(QJsonObject settings, QJsonObject patch);
QByteArray encode(const QJsonObject &settings);
} // namespace Mucke::LibrarySettings
