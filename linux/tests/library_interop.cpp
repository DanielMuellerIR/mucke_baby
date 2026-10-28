#include "../src/data/librarystore.h"
#include <QCoreApplication>
#include <QFile>
#include <QTemporaryDir>
#include <QDir>
#include <iostream>
int main(int argc,char **argv) {
    QCoreApplication app(argc,argv);
    if(argc!=3)return 2;
    QTemporaryDir root;
    const auto data=root.filePath("library");QDir().mkpath(data);
    QFile file(data+"/library.json");
    if(!file.open(QIODevice::WriteOnly))return 3;
    file.write("{\"format\":\"mucke-baby-linux-library\",\"formatVersion\":1,\"stations\":[],\"groups\":[],\"bookmarks\":[]}");file.close();
    Mucke::LibraryStore store(data);
    QObject::connect(&store,&Mucke::LibraryStore::error,[](const QString &error){std::cerr<<error.toStdString()<<'\n';});
    if(!store.load())return 4;
    const auto preview=store.previewImport(QString::fromLocal8Bit(argv[1]));
    if(preview.isEmpty()||!store.applyImport(preview,{}))return 5;
    if(!store.exportLibrary(QString::fromLocal8Bit(argv[2])))return 6;
    return 0;
}
