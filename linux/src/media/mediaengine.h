#pragma once
#include "../types.h"
#include <QJsonObject>
#include <QObject>
#include <memory>
namespace Mucke {
class MediaEngine : public QObject {
    Q_OBJECT
public:
    explicit MediaEngine(QString recordingsDirectory, QString cacheDirectory, QObject *parent = nullptr);
    ~MediaEngine() override;
    PlaybackSnapshot snapshot() const;
    QVector<Recording> recordings() const;
    QString recordingsDirectory() const;
    void play(Station);
    void previewStation(Station);
    void stop();
    void togglePause();
    void setVolume(int);
    void setRecordingEnabled(bool);
    void setTimeshiftEnabled(bool);
    void seekDelay(double seconds);
    void goLive();
    void setEqualizer(bool enabled, QVector<double> bands, double preampDB);
    void setStationGain(QString stationID, double decibels);
    void setSleepTimer(int seconds);
    void setVisualizationActive(bool);
    void previewRecording(QString recordingID);
    void previewFile(QString path);
    void stopPreview();
    void removeRecording(QString recordingID);
    void removeCompletedRecordings();
    void exportClip(QString jobID, QString recordingID, double start, double duration,
                    double fadeIn, double fadeOut, QJsonObject metadata, QString destination);
    void cancelExport(QString jobID);
    void prepareSongExports(QString requestID, QVector<Track> tracks);
    void cancelSongPreparation(QString requestID);
    void exportPreparedSong(QString jobID, SongExportProposal proposal, double startAdjustment,
                            double endAdjustment, double fadeIn, double fadeOut, QString destination);
    void prepareForSleep(bool sleeping);
    void shutdown();
signals:
    void snapshotChanged(Mucke::PlaybackSnapshot);
    void receivedTrack(Mucke::Track);
    void receptionEnded(QDateTime);
    void recordingsChanged();
    void visualization(QVector<float> waveform, QVector<float> spectrum, float rms);
    void positionDiscontinuity(double positionSeconds);
    void exportFinished(QString jobID, QString path, QString error);
    void songExportsPrepared(QString requestID, QVector<Mucke::SongExportProposal> proposals);
    void songPreparationProgress(QString requestID, int finishedFiles, int totalFiles);
    void error(QString);
private:
    class Impl;
    std::unique_ptr<Impl> d;
};
}
