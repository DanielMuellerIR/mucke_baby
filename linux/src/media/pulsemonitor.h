#pragma once
#include <QObject>
#include <QVector>
#include <QString>
#include <functional>
#include <memory>
namespace Mucke::MediaPrivate {
class PulseMonitor : public QObject {
public:
    explicit PulseMonitor(QObject *parent = nullptr);
    ~PulseMonitor() override;
    void setActive(bool);
    std::function<void(QVector<float>, QVector<float>, float)> frames;
    std::function<void(QString)> status;
private:
    class Impl;
    std::unique_ptr<Impl> d;
};
}
