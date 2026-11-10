#include "data/librarystore.h"
#include "data/catalogservice.h"
#include "media/mediaengine.h"
#include "ui/mainwindow.h"
#include "integration/mpris.h"
#include "integration/sleepmonitor.h"
#include "version.h"
#include <QApplication>
#include <QCommandLineParser>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <algorithm>
#include <QIcon>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QMenu>
#include <QMessageBox>
#include <QSaveFile>
#include <QStandardPaths>
#include <QSystemTrayIcon>
#include <QTimer>
#include <QUrl>
#include <QTranslator>
#include <QLibraryInfo>
#include <cstdio>
#include <memory>
#include <unistd.h>

using namespace Mucke;
namespace {
QString stateName(PlaybackState value) {
    switch(value) {
    case PlaybackState::Stopped:return QStringLiteral("stopped");
    case PlaybackState::Resolving:return QStringLiteral("resolving");
    case PlaybackState::Buffering:return QStringLiteral("buffering");
    case PlaybackState::Playing:return QStringLiteral("playing");
    case PlaybackState::Paused:return QStringLiteral("paused");
    case PlaybackState::Error:return QStringLiteral("error");
    }
    return QStringLiteral("unknown");
}
QString localText(const char *de, const char *en) { return QString::fromUtf8(QLocale().language()==QLocale::German?de:en); }
QJsonObject statusObject(MediaEngine &engine, LibraryStore &store) {
    const auto s=engine.snapshot();
    return {{"version",MUCKE_VERSION},{"pid",double(QCoreApplication::applicationPid())},{"state",stateName(s.state)},
        {"stationID",s.stationID},{"station",s.stationName},{"title",s.heardTrack.raw},{"volume",s.volume},
        {"recordRequested",s.recordRequested},{"recordActive",s.recordActive},{"recordStatus",s.recordStatus},
        {"timeshiftAvailable",s.timeshiftAvailable},{"delaySeconds",s.delaySeconds},{"bufferSeconds",s.bufferSeconds},
        {"visualizerStatus",s.visualizerStatus},{"error",s.error},{"recordings",engine.recordings().size()},
        {"history",store.history().size()},{"at",QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)}};
}
class ClosePolicy : public QObject {
public:
    LibraryStore *store;
    QSystemTrayIcon *tray;
    ClosePolicy(LibraryStore *s,QSystemTrayIcon *t,QObject *parent):QObject(parent),store(s),tray(t){}
    bool eventFilter(QObject *object,QEvent *event) override {
        if(event->type()==QEvent::Close && tray->isVisible() && store->settings().value("closeToTray").toBool()) {
            if(auto *widget=qobject_cast<QWidget*>(object)) {widget->hide();event->ignore();return true;}
        }
        return false;
    }
};
}
int main(int argc,char **argv) {
    QApplication app(argc,argv);
    QCoreApplication::setApplicationName(QStringLiteral("MuckeBaby"));
    QCoreApplication::setOrganizationName(QStringLiteral("MuckeBaby"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("de.danielmuller"));
    QCoreApplication::setApplicationVersion(QStringLiteral(MUCKE_VERSION));
    QGuiApplication::setDesktopFileName(QStringLiteral("de.danielmuller.muckebaby"));
    QApplication::setApplicationDisplayName(QStringLiteral("Mucke, Baby!"));
    QApplication::setWindowIcon(QIcon(QStringLiteral(":/icon.png")));
    qRegisterMetaType<Station>();qRegisterMetaType<QVector<Station>>();qRegisterMetaType<Track>();qRegisterMetaType<PlaybackSnapshot>();
    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Mucke, Baby! — Linux internet radio"));
    parser.addHelpOption();parser.addVersionOption();
    parser.addOption({"data-dir","Separate application data directory","directory"});
    parser.addOption({"recordings-dir","Recording directory (default: Music/MuckeBaby/Aufnahmen)","directory"});
    parser.addOption({"cache-dir","Separate cache directory","directory"});
    parser.addOption({"no-autoplay","Suppress saved startup playback"});
    parser.addOption({"no-window","Run without showing a window"});
    parser.addOption({"screenshots","Render synthetic theme screenshots","directory"});
    parser.addOption({"quit-after","Quit after the given number of milliseconds","milliseconds"});
    parser.addOption({"state-file","Write bounded diagnostic state snapshots to this file","file"});
    parser.addOption({"event-log","Write bounded diagnostic state transitions to this file","file"});
    parser.addOption({"play","Play a saved station ID or HTTP(S) stream URL","station"});
    parser.addOption({"stop","Stop an already running instance"});
    parser.addOption({"pause","Pause or resume an already running instance"});
    parser.addOption({"status","Print JSON status of an already running instance"});
    parser.addOption({"volume","Set volume, from 0 to 100","percent"});
    parser.addOption({"recording","Explicitly enable or disable stream recording","on|off"});
    parser.process(app);
    const bool hidden=parser.isSet("no-window");
    const QString dataDir=QDir::cleanPath(parser.isSet("data-dir")?QFileInfo(parser.value("data-dir")).absoluteFilePath():QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)+QStringLiteral("/MuckeBaby"));
    const QString cacheDir=QDir::cleanPath(parser.isSet("cache-dir")?QFileInfo(parser.value("cache-dir")).absoluteFilePath():QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation)+QStringLiteral("/MuckeBaby"));
    QString music=QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    if(music.isEmpty()) music=QDir::homePath()+QStringLiteral("/Music");
    const QString recordingsDir=QDir::cleanPath(parser.isSet("recordings-dir")?QFileInfo(parser.value("recordings-dir")).absoluteFilePath():music+QStringLiteral("/MuckeBaby/Aufnahmen"));
    if(!QDir().mkpath(dataDir)||!QDir().mkpath(cacheDir)) {std::fprintf(stderr,"Cannot create application directories\n");return 1;}
    const QString serverName=QStringLiteral("mucke-baby-%1-%2").arg(getuid()).arg(QString::fromLatin1(QCryptographicHash::hash(dataDir.toUtf8(),QCryptographicHash::Sha256).toHex().left(20)));
    QJsonObject command;
    if(parser.isSet("play")) command.insert("play",parser.value("play"));
    if(parser.isSet("stop")) command.insert("stop",true);
    if(parser.isSet("pause")) command.insert("pause",true);
    if(parser.isSet("volume")) {bool ok=false;int value=parser.value("volume").toInt(&ok);if(!ok||value<0||value>100){std::fprintf(stderr,"Volume must be 0..100\n");return 2;}command.insert("volume",value);}
    if(parser.isSet("recording")) {const auto value=parser.value("recording");if(value!="on"&&value!="off"){std::fprintf(stderr,"Recording must be on or off\n");return 2;}command.insert("recording",value=="on");}
    if(parser.isSet("status")) command.insert("status",true);
    QLocalSocket client;
    client.connectToServer(serverName);
    if(client.waitForConnected(350)) {
        if(command.isEmpty()) command.insert("raise",true);
        client.write(QJsonDocument(command).toJson(QJsonDocument::Compact)+'\n');
        if(!client.waitForBytesWritten(1000)||!client.waitForReadyRead(3000))return 1;
        const auto result=client.readAll();
        if(parser.isSet("status"))std::fwrite(result.constData(),1,size_t(result.size()),stdout);
        return 0;
    }
    if(parser.isSet("status")||parser.isSet("stop")||parser.isSet("pause")){std::fprintf(stderr,"No running MuckeBaby instance\n");return 1;}
    QLockFile instanceLock(dataDir+QStringLiteral("/.instance.lock"));
    instanceLock.setStaleLockTime(0);
    if(!instanceLock.tryLock(0)){std::fprintf(stderr,"Application data are already in use\n");return 1;}
    LibraryStore store(dataDir);
    QObject::connect(&store,&LibraryStore::error,&app,[](const QString &message){std::fprintf(stderr,"Data: %s\n",qPrintable(message));});
    store.load();
    const auto language=store.settings().value("language").toString();
    if(language=="de")QLocale::setDefault(QLocale(QLocale::German));
    else if(language=="en")QLocale::setDefault(QLocale(QLocale::English));
    QTranslator qtTranslator;
    if (qtTranslator.load(QLocale(), QStringLiteral("qtbase"), QStringLiteral("_"), QLibraryInfo::path(QLibraryInfo::TranslationsPath))) app.installTranslator(&qtTranslator);
    store.saveSettings({{"recordingsDirectory",recordingsDir}});
    CatalogService catalog(cacheDir+QStringLiteral("/catalog"));
    MediaEngine engine(recordingsDir,cacheDir);
    QObject::connect(&engine,&MediaEngine::receivedTrack,&store,&LibraryStore::receiveTrack);
    QObject::connect(&engine,&MediaEngine::receptionEnded,&store,&LibraryStore::endReception);
    QObject::connect(&engine,&MediaEngine::error,&app,[](const QString &message){std::fprintf(stderr,"Media: %s\n",qPrintable(message));});
    std::unique_ptr<MainWindow> window;
    if(!hidden) window=std::make_unique<MainWindow>(&store,&catalog,&engine);
    SleepMonitor sleepMonitor(&engine, &app);
    MprisBridge mpris(&engine,&store,window.get());
    QSystemTrayIcon tray(QIcon(QStringLiteral(":/icon.png")));
    QMenu trayMenu;
    auto *showAction=trayMenu.addAction(localText("Mucke, Baby! öffnen","Open Mucke, Baby!"));
    QObject::connect(showAction,&QAction::triggered,&app,[&]{if(window){window->showNormal();window->raise();window->activateWindow();}});
    trayMenu.addSeparator();
    QObject::connect(trayMenu.addAction(localText("Wiedergabe / Pause","Play / Pause")),&QAction::triggered,&app,[&]{if(engine.snapshot().state==PlaybackState::Playing||engine.snapshot().state==PlaybackState::Paused)engine.togglePause();else mpris.play();});
    QObject::connect(trayMenu.addAction(localText("Stoppen","Stop")),&QAction::triggered,&engine,&MediaEngine::stop);
    trayMenu.addSeparator();
    QObject::connect(trayMenu.addAction(localText("Beenden","Quit")),&QAction::triggered,&app,&QApplication::quit);
    tray.setContextMenu(&trayMenu);tray.setToolTip(QStringLiteral("Mucke, Baby!"));
    QObject::connect(&tray,&QSystemTrayIcon::activated,&app,[&](QSystemTrayIcon::ActivationReason why){if(why==QSystemTrayIcon::Trigger&&window){window->showNormal();window->raise();}});
    ClosePolicy closePolicy(&store,&tray,&app);if(window)window->installEventFilter(&closePolicy);
    QByteArray appliedAudio;
    auto applySettings=[&]{
        const auto settings=store.settings();
        const bool useTray=!hidden&&QSystemTrayIcon::isSystemTrayAvailable()&&(settings.value("showTrayIcon").toBool()||settings.value("closeToTray").toBool());
        tray.setVisible(useTray);app.setQuitOnLastWindowClosed(!hidden&&!useTray);
        QJsonObject audio;
        for(const auto &key:{"volume","equalizerEnabled","equalizerBands","equalizerPreamp","stationGains","recordingEnabled","timeshiftEnabled"})audio.insert(key,settings.value(key));
        const auto bytes=QJsonDocument(audio).toJson(QJsonDocument::Compact);
        if(bytes==appliedAudio)return;
        appliedAudio=bytes;
        engine.setVolume(settings.value("volume").toInt(70));
        engine.setRecordingEnabled(settings.value("recordingEnabled").toBool(false));
        engine.setTimeshiftEnabled(settings.value("timeshiftEnabled").toBool(false));
        QVector<double> bands;for(const auto &value:settings.value("equalizerBands").toArray())bands.append(value.toDouble());
        if(bands.size()!=10)bands=QVector<double>(10,0.0);
        engine.setEqualizer(settings.value("equalizerEnabled").toBool(),bands,settings.value("equalizerPreamp").toDouble());
        const auto gains=settings.value("stationGains").toObject();
        for(auto it=gains.begin();it!=gains.end();++it)engine.setStationGain(it.key(),it.value().toDouble());
    };
    QObject::connect(&store,&LibraryStore::settingsChanged,&app,applySettings);
    applySettings();
    QTimer settingsTimer;settingsTimer.setSingleShot(true);settingsTimer.setInterval(350);
    auto currentSettingsPatch=[&]{
        const auto settings=store.settings();
        const auto state=engine.snapshot();
        QJsonObject patch;
        if(state.volume!=settings.value("volume").toInt(70))patch.insert("volume",state.volume);
        if(state.recordRequested!=settings.value("recordingEnabled").toBool())patch.insert("recordingEnabled",state.recordRequested);
        if(!state.stationID.isEmpty()&&state.stationID!=settings.value("lastStationID").toString())patch.insert("lastStationID",state.stationID);
        return patch;
    };
    auto flushSettings=[&]{const auto patch=currentSettingsPatch();if(!patch.isEmpty())store.saveSettings(patch);};
    QObject::connect(&settingsTimer,&QTimer::timeout,&app,flushSettings);
    auto writeState=[&]{
        if(!parser.isSet("state-file"))return;
        QSaveFile target(parser.value("state-file"));
        const auto bytes=QJsonDocument(statusObject(engine,store)).toJson(QJsonDocument::Compact);
        if(target.open(QIODevice::WriteOnly)&&target.write(bytes)==bytes.size())target.commit();
    };
    QString lastTransition;
    QObject::connect(&engine,&MediaEngine::snapshotChanged,&app,[&](const PlaybackSnapshot &s){
        if(currentSettingsPatch().isEmpty())settingsTimer.stop();
        else if(!settingsTimer.isActive())settingsTimer.start();
        tray.setToolTip((s.stationName+QStringLiteral("\n")+s.heardTrack.raw).left(512));
        writeState();
        const QString transition=stateName(s.state)+s.stationID+s.heardTrack.raw+QString::number(s.recordActive);
        if(parser.isSet("event-log")&&transition!=lastTransition){QFile log(parser.value("event-log"));if(log.size()<256*1024&&log.open(QIODevice::Append))log.write(QJsonDocument(statusObject(engine,store)).toJson(QJsonDocument::Compact)+'\n');}
        lastTransition=transition;
    });
    QObject::connect(&engine,&MediaEngine::recordingsChanged,&app,writeState);
    QObject::connect(&app,&QApplication::aboutToQuit,&app,[&]{settingsTimer.stop();flushSettings();catalog.cancel();engine.shutdown();store.endReception(QDateTime::currentDateTimeUtc());writeState();});
    auto execute=[&](const QJsonObject &request){
        if(request.value("stop").toBool())engine.stop();
        if(request.value("pause").toBool())engine.togglePause();
        if(request.contains("volume"))engine.setVolume(std::clamp(request.value("volume").toInt(),0,100));
        if(request.contains("recording"))engine.setRecordingEnabled(request.value("recording").toBool());
        if(request.contains("play")){
            const auto name=request.value("play").toString();auto station=store.station(name);
            if(station.id.isEmpty()&&validStreamURL(name))station=Station{newID(),QUrl(name).host(),name,QString(),true,false};
            if(!station.id.isEmpty()&&station.enabled)engine.play(station);
        }
        if(request.value("raise").toBool()&&window){window->showNormal();window->raise();window->activateWindow();}
    };
    QLocalServer server;server.setSocketOptions(QLocalServer::UserAccessOption);QLocalServer::removeServer(serverName);
    if(!server.listen(serverName)){std::fprintf(stderr,"Cannot create local control socket\n");return 1;}
    QObject::connect(&server,&QLocalServer::newConnection,&app,[&]{
        while(auto *socket=server.nextPendingConnection()){
            socket->setReadBufferSize(8193);
            auto buffer=std::make_shared<QByteArray>();
            auto read=[&,socket,buffer]{
                buffer->append(socket->readAll());
                if(buffer->size()>8192){socket->disconnectFromServer();return;}
                if(!buffer->contains('\n'))return;
                const auto document=QJsonDocument::fromJson(buffer->left(buffer->indexOf('\n')));
                if(document.isObject())execute(document.object());
                socket->write(QJsonDocument(statusObject(engine,store)).toJson(QJsonDocument::Compact)+'\n');socket->flush();socket->disconnectFromServer();
            };
            QObject::connect(socket,&QLocalSocket::readyRead,&app,read);
            QObject::connect(socket,&QLocalSocket::disconnected,socket,&QObject::deleteLater);
            QTimer::singleShot(5000,socket,[socket]{socket->disconnectFromServer();});
            read();
        }
    });
    if(window){window->show();if(!store.lastError().isEmpty())QTimer::singleShot(0,window.get(),[&]{QMessageBox::warning(window.get(),localText("Daten geschützt","Protected data"),store.lastError());});}
    if(parser.isSet("screenshots")){
        if(hidden||!window){std::fprintf(stderr,"Screenshots require a window\n");return 2;}
        QTimer::singleShot(100,window.get(),[&]{window->captureScreenshots(parser.value("screenshots"));QApplication::quit();});
    }else if(!command.isEmpty())QTimer::singleShot(0,&app,[&]{execute(command);});
    else if(!parser.isSet("no-autoplay")){
        const auto settings=store.settings();const auto mode=settings.value("autostart").toString("none");
        const auto target=store.station(settings.value(mode=="selected"?"selectedStationID":"lastStationID").toString());
        if(mode!="none"&&!target.id.isEmpty()&&target.enabled)QTimer::singleShot(0,&app,[&,target]{engine.play(target);});
    }
    if(parser.isSet("quit-after")){bool ok=false;int duration=parser.value("quit-after").toInt(&ok);if(!ok||duration<1||duration>86400000)return 2;QTimer::singleShot(duration,&app,&QApplication::quit);}
    writeState();
    return app.exec();
}
