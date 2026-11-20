#pragma once

#include <QLocale>
#include <QString>

namespace Mucke {
inline QString germanOrEnglish(const char *german, const char *english) {
    return QString::fromUtf8(QLocale().language() == QLocale::German ? german : english);
}
} // namespace Mucke
