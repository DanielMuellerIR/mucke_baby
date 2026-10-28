#pragma once
#include <QObject>

namespace Mucke {
class MediaEngine;
class SleepMonitor final : public QObject {
    Q_OBJECT
public:
    explicit SleepMonitor(MediaEngine *, QObject *parent = nullptr);
private slots:
    void prepareForSleep(bool sleeping);
private:
    MediaEngine *engine;
    bool asleep = false;
};
}
