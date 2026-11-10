#include "../src/media/recorder.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <sys/statvfs.h>
#include <iostream>
static qint64 availableBytes = -1;
extern "C" int __real_fstatvfs(int, struct statvfs *);
extern "C" int __wrap_fstatvfs(int fd, struct statvfs *space) {
    const int result = __real_fstatvfs(fd, space);
    if (result == 0 && availableBytes >= 0) { space->f_frsize = 1; space->f_bavail = availableBytes; }
    return result;
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); QTemporaryDir directory;
    Mucke::MediaPrivate::Recorder recorder(directory.path()); recorder.initialize(); recorder.beginSession("Fixture", "disk-fixture");
    constexpr qint64 minimum = 10LL * 1024 * 1024 * 1024;
    availableBytes = minimum + 1; recorder.setEnabled(true); recorder.audio(QByteArray::fromHex("fffb") + QByteArray(100, 'a'));
    if (!recorder.active()) return 1;
    availableBytes = minimum; recorder.checkDisk(); if (!recorder.active()) return 1;
    availableBytes = minimum - 1; recorder.checkDisk(); if (recorder.active() || recorder.list().first().active) return 1;
    const qint64 bytes = recorder.list().first().bytes;
    recorder.audio(QByteArray(100, 'a')); if (recorder.list().first().bytes != bytes) return 1;
    std::cout << "media disk threshold: above/exactly/below10GiB passed\n";
}
