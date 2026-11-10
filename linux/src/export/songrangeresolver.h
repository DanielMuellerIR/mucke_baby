#pragma once
#include "../types.h"
#include <QObject>
#include <memory>

namespace Mucke {
class SongRangeResolver : public QObject {
    Q_OBJECT
public:
    explicit SongRangeResolver(QString recordingsDirectory, QObject *parent = nullptr);
    ~SongRangeResolver() override;
    void prepare(QString requestID, QVector<Track> tracks, QVector<Recording> recordings,
                 QVector<RecordingBoundary> boundaries);
    void cancel(QString requestID);
    bool validate(const SongExportProposal &, QString *error = nullptr) const;
    void shutdown();
signals:
    void prepared(QString requestID, QVector<Mucke::SongExportProposal> proposals);
    void progress(QString requestID, int finishedFiles, int totalFiles);
private:
    class Impl;
    std::unique_ptr<Impl> d;
};
}
