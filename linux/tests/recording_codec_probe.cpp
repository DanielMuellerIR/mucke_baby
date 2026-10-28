#include "../src/media/recorder.h"
#include "../src/media/streamprotocol.h"
#include <QCoreApplication>
#include <QFile>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <iostream>
using namespace Mucke::MediaPrivate;
int main(int argc,char **argv) {
    QCoreApplication app(argc,argv);if(argc!=3)return 2;
    QFile input(QString::fromLocal8Bit(argv[1]));if(!input.open(QIODevice::ReadOnly))return 3;
    const auto source=input.readAll();
    Recorder recorder(QString::fromLocal8Bit(argv[2]));recorder.initialize();
    recorder.beginSession("Codec fixture","11111111-1111-4111-8111-111111111111");recorder.setEnabled(true);
    constexpr int interval=997;QByteArray wire;
    const QByteArray title("StreamTitle='Fixture - Codec';");const int units=(title.size()+15)/16;
    for(qsizetype position=0;position<source.size();position+=interval){const auto part=source.mid(position,interval);wire.append(part);if(part.size()==interval){wire.append(char(units));wire.append(title);wire.append(QByteArray(units*16-title.size(),char(0)));}}
    ICYParser parser(interval);const int chunks[]={1,13,4096,7,63,511};qsizetype position=0;int index=0;
    while(position<wire.size()) {const auto part=wire.mid(position,chunks[index++%6]);position+=part.size();parser.feed(part,[&](const QByteArray &bytes){recorder.audio(bytes);},[&](const QString &value){recorder.title(value);});}
    recorder.finish();const auto recordings=recorder.list();
    if(recordings.size()!=1)return 4;
    const auto path=recorder.checkedPath(recordings.first().id);QFile recorded(path);
    if(!recorded.open(QIODevice::ReadOnly)||recorded.readAll()!=source)return 5;
    QJsonObject result{{"file",path},{"bytes",double(source.size())},{"extension",recordings.first().ext},{"exactAudioBytes",true}};
    std::cout<<QJsonDocument(result).toJson(QJsonDocument::Compact).toStdString()<<'\n';return 0;
}
