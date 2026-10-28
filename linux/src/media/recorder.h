#pragma once
#include "../types.h"
#include <QByteArray>
#include <QJsonArray>
#include <functional>
#include <optional>
namespace Mucke::MediaPrivate {
class Recorder {
public:
    explicit Recorder(QString directory, std::function<QDateTime()> clock = {});
    ~Recorder();
    void initialize();
    QVector<Recording> list() const { return entries; }
    QString directory() const { return root; }
    QString status() const { return message; }
    bool active() const { return fileFD >= 0 && activeIndex >= 0 && entries[activeIndex].bytes > 0; }
    bool needsFreshHeader() const { return headerRequired && (extension == "ogg" || extension == "flac"); }
    bool rolloverNeedsHeader() const { return rolloverHeaderPending; }
    QVector<RecordingBoundary> songBoundaries() const { return boundaries; }
    void beginSession(QString station, QString session);
    void setEnabled(bool);
    void audio(const QByteArray &);
    void title(const QString &);
    void title(const Track &);
    void finish();
    void checkDisk();
    bool remove(QString id);
    QString checkedPath(QString id) const;
    // Der Aufrufer besitzt den zurückgegebenen Descriptor und muss ihn schließen.
    int openReadFD(QString id) const;
    std::function<void()> changed;
private:
    bool persist();
    bool startFile(bool partialStart = true);
    void appendBoundary(RecordingBoundary);
    RecordingBoundary boundary(const Track &, qint64 offset, bool captureStart, bool partialStart) const;
    QDateTime now() const;
    void fail(QString);
    bool load();
    QString root, station, session, extension, message;
    int rootFD = -1, fileFD = -1, activeIndex = -1;
    bool requested = false, initialAudio = true, headerRequired = false, indexReady = false;
    qint64 sinceDiskCheck = 0;
    QByteArray prefix;
    QVector<Recording> entries;
    QVector<RecordingBoundary> boundaries;
    Track currentTrack;
    bool firstTitle = true;
    bool rolloverHeaderPending = false;
    std::optional<RecordingBoundary> pendingCapture;
    std::function<QDateTime()> clock;
};
}
