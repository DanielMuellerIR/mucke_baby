#include "../src/data/librarystore.h"
#include <QCoreApplication>
#include <QFile>
#include <QTemporaryDir>
#include <QDir>
#include <stdexcept>
using namespace Mucke;
static QByteArray read(const QString &name) { QFile file(name); if(!file.open(QIODevice::ReadOnly))throw std::runtime_error("read"); return file.readAll(); }
int main(int argc,char **argv) {
    QCoreApplication app(argc,argv);
    QTemporaryDir temporary;
    const auto data=temporary.filePath("data");QDir().mkpath(data);
    const QString first="11111111-1111-4111-8111-111111111111",second="22222222-2222-4222-8222-222222222222";
    const auto book=[&](QString id,const char *raw){return Json{{"id",id.toStdString()},{"station","Fixture"},{"raw",raw},{"artist","Artist"},{"title",raw},{"heardAt","2026-10-28T12:00:00.000Z"},{"savedAt","2026-10-28T12:00:00.000Z"}};};
    Json document={{"format","mucke-baby-linux-library"},{"formatVersion",1},{"stations",Json::array()},{"groups",Json::array()},{"bookmarks",Json::array({book(first,"First track"),book(second,"=Second track")})}};
    QFile file(data+"/library.json");if(!file.open(QIODevice::WriteOnly))return 1;file.write(QByteArray::fromStdString(document.dump()));file.close();
    const auto original=read(data+"/library.json");
    LibraryStore store(data);if(!store.load())return 2;
    QStringList selected{second};
    const auto output=temporary.filePath("selected.csv");
    if(!store.exportBookmarks(output,true,&selected))return 3;
    auto text=read(output);
    if(text.contains("First track")||!text.contains("'=Second track"))return 4;
    QStringList ordered{second,first};
    if(!store.exportBookmarks(output,true,&ordered))return 5;
    text=read(output);if(text.indexOf("Second track")>text.indexOf("First track"))return 6;
    QStringList empty;
    if(!store.exportBookmarks(output,true,&empty))return 7;
    text=read(output);if(text.contains("First track")||text.contains("Second track"))return 8;
    if(read(data+"/library.json")!=original)return 9;
    return 0;
}
