#include "sleepmonitor.h"
#include "../media/mediaengine.h"
#include <QDBusConnection>

namespace Mucke {
SleepMonitor::SleepMonitor(MediaEngine *value, QObject *parent) : QObject(parent), engine(value) {
    QDBusConnection::systemBus().connect(
        QStringLiteral("org.freedesktop.login1"), QStringLiteral("/org/freedesktop/login1"),
        QStringLiteral("org.freedesktop.login1.Manager"), QStringLiteral("PrepareForSleep"),
        this, SLOT(prepareForSleep(bool)));
}
void SleepMonitor::prepareForSleep(bool sleeping) {
    if (sleeping == asleep) return;
    asleep = sleeping;
    engine->prepareForSleep(sleeping);
}
}
