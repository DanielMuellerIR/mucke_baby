#include "librarysettings_p.h"
#include "codec_p.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <cmath>

namespace Mucke::LibrarySettings {
namespace {
using DataCodec::require;
using DataCodec::uuid;

QJsonObject validateSettings(QJsonObject patch) {
    if (patch.contains("windowGeometry"))
        require(patch["windowGeometry"].isString() && patch["windowGeometry"].toString().size() <= 4096,
                "Invalid window geometry setting.");
    for (const auto *key : {"recordingEnabled", "timeshiftEnabled", "equalizerEnabled", "closeToTray", "updateChecks"})
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
} // namespace

QJsonObject defaults() {
    return {{"recordingEnabled", false},
            {"timeshiftEnabled", false},
            {"language", "system"},
            {"quickSlots", QJsonArray{QJsonValue::Null, QJsonValue::Null, QJsonValue::Null,
                                      QJsonValue::Null, QJsonValue::Null}}};
}

QJsonObject decode(const QByteArray &bytes) {
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(bytes, &error);
    require(error.error == QJsonParseError::NoError && document.isObject());
    return applyPatch(defaults(), document.object());
}

QJsonObject applyPatch(QJsonObject settings, QJsonObject patch) {
    patch = validateSettings(std::move(patch));
    for (auto it = patch.constBegin(); it != patch.constEnd(); ++it)
        settings.insert(it.key(), it.value());
    return settings;
}

QByteArray encode(const QJsonObject &settings) {
    return QJsonDocument(settings).toJson(QJsonDocument::Indented);
}
} // namespace Mucke::LibrarySettings
