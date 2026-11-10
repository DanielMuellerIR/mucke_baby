#include "media/timeshift.h"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QUuid>
#include <chrono>
#include <cmath>
#include <limits>
#include <cstring>
#include <fcntl.h>
#include <future>
#include <iostream>
#include <stdexcept>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
using namespace Mucke;
using namespace Mucke::MediaPrivate;
static void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
static QByteArray mp3(int bitrateIndex = 9, bool mpeg2 = false, bool mono = false) {
    const int bitrate1[] = {0,32,40,48,56,64,80,96,112,128,160,192,224,256,320};
    const int bitrate2[] = {0,8,16,24,32,40,48,56,64,80,96,112,128,144,160};
    const int rate = mpeg2 ? 24000 : 48000;
    const int bytes = (mpeg2 ? 72 : 144) * (mpeg2 ? bitrate2 : bitrate1)[bitrateIndex] * 1000 / rate;
    QByteArray frame(bytes, char(0));
    frame[0] = char(0xff); frame[1] = char(mpeg2 ? 0xf3 : 0xfb); frame[2] = char((bitrateIndex << 4) | 4); frame[3] = char(mono ? 0xc0 : 0);
    return frame;
}
static QByteArray aac(int rateIndex = 3, int channels = 2, int blocks = 0) {
    const int bytes = 128;
    QByteArray frame(bytes, char(0));
    frame[0] = char(0xff); frame[1] = char(0xf1); frame[2] = char(0x40 | (rateIndex << 2) | (channels >> 2));
    frame[3] = char(((channels & 3) << 6) | (bytes >> 11)); frame[4] = char(bytes >> 3); frame[5] = char((bytes & 7) << 5 | 31); frame[6] = char(0xfc | blocks);
    return frame;
}
static DecoderProfile mp3Profile() { return {"mp3", 48000, 2, true}; }
static DecoderProfile aacProfile() { return {"aac", 48000, 0, true}; }
static TimeshiftLimits limits(double seconds = 8) { TimeshiftLimits l; l.seconds = seconds; l.segmentSeconds = .48; l.segmentBytes = 8192; l.minimumFreeBytes = 0; return l; }
static Track title(QString raw) { Track t; t.id = raw; t.raw = raw; t.title = raw; return t; }
static void feed(TimeshiftBuffer &buffer, const QByteArray &frame, int count, QDateTime date = QDateTime::fromMSecsSinceEpoch(1000)) {
    for (int i = 0; i < count; ++i) require(buffer.append(frame, date), "append valid frame");
}
static void storageAndReaders(const QString &root) {
    TimeshiftBuffer buffer(root, limits());
    require(buffer.begin("audio/mpeg; charset=x", "test", mp3Profile()), "begin mp3");
    buffer.noteTitle(title("440"));
    feed(buffer, mp3(), 180);
    auto view = buffer.view(); require(view.phase == BufferPhase::Ready && view.segments > 1, "ready after warmup/reserve");
    auto reader = buffer.readerAt(1.9); require(bool(reader), "reader frame aligned");
    require(reader->inputStart() <= reader->outputStart() - 1 + .000001, "one second decoder preroll");
    require(reader->mediaOptions().contains(":demux=mpga"), "mp3 demux option");
    QByteArray read;
    unsigned char bytes[777];
    const qint64 expected = qint64(std::llround((view.live - reader->inputStart()) / .024)) * mp3().size();
    while (read.size() < expected) { const auto count = reader->read(bytes, sizeof(bytes)); require(count > 0, "read available data"); read.append(reinterpret_cast<char *>(bytes), count); }
    require(read.size() == expected && read == mp3().repeated(int(expected / mp3().size())), "cross-segment frames exactly once");
    auto waiting = std::async(std::launch::async, [&] { return reader->read(bytes, sizeof(bytes)); });
    require(waiting.wait_for(std::chrono::milliseconds(80)) == std::future_status::timeout, "growing end must wait instead of EOF");
    buffer.noteTitle(title("880")); feed(buffer, mp3(), 1);
    require(waiting.wait_for(std::chrono::seconds(1)) == std::future_status::ready && waiting.get() == mp3().size(), "append wakes reader");
    auto cancelled = std::async(std::launch::async, [&] { return reader->read(bytes, sizeof(bytes)); });
    require(cancelled.wait_for(std::chrono::milliseconds(80)) == std::future_status::timeout, "second growing end wait");
    const auto before = std::chrono::steady_clock::now(); reader->cancel(); reader->cancel();
    require(cancelled.wait_for(std::chrono::seconds(1)) == std::future_status::ready && cancelled.get() == 0, "cancel wakes reader");
    require(std::chrono::steady_clock::now() - before < std::chrono::seconds(1), "cancel under one second");
    require(buffer.trackAt(view.live-.001).raw == "440" && buffer.trackAt(view.live+.001).raw == "880", "title belongs to original frame");
    buffer.endReception();
}
static void warmupBoundary(const QString &root) {
    TimeshiftBuffer buffer(root, limits()); require(buffer.begin("audio/mpeg", "x", DecoderProfile{"mp3"}), "warmup begin");
    feed(buffer, mp3(), 125);
    require(buffer.view().phase == BufferPhase::Warming && !buffer.readerAt(0) && !buffer.readerLive(), "three seconds alone never ready");
    feed(buffer, mp3(), 41);
    require(buffer.view().phase == BufferPhase::Warming, "full decoder warmup plus reserve required");
    feed(buffer, mp3(), 1);
    require(buffer.view().phase == BufferPhase::Ready, "first admissible ready frame");
    auto edge = buffer.readerAt(0), live = buffer.readerLive();
    require(edge && live && std::abs(edge->outputStart()-1.008)<.000001 && std::abs(live->outputStart()-1.008)<.000001, "oldest/live clamp to warmed frame");
    require(edge->inputStart()==0 && live->inputStart()==0, "initial preroll starts at stream origin");
}
static void partialMetadata(const QString &root) {
    TimeshiftBuffer buffer(root, limits()); require(buffer.begin("audio/mpeg", "test", mp3Profile()), "partial begin");
    const auto old = QDateTime::fromMSecsSinceEpoch(1000), recent = QDateTime::fromMSecsSinceEpoch(2000);
    const auto frame = mp3(); buffer.noteTitle(title("440"));
    require(buffer.append(frame.left(2), old), "append partial header"); buffer.noteTitle(title("880"));
    require(buffer.append(frame.mid(2) + frame, recent), "complete old frame then new frame");
    require(buffer.trackAt(0).raw == "440" && buffer.receivedAt(0) == old, "partial frame keeps old title/receipt");
    require(buffer.trackAt(.024).raw == "880" && buffer.receivedAt(.024) == recent, "next frame gets new title/receipt");
    buffer.endReception(); require(buffer.view().phase == BufferPhase::Warming, "complete end accepted");
}
static void bounds(const QString &root) {
    auto l = limits(6); l.bytes = 100000; l.segments = 12;
    TimeshiftBuffer buffer(root, l); require(buffer.begin("audio/mpeg", "test", mp3Profile()), "bounded begin");
    feed(buffer, mp3(), 1000);
    const auto view = buffer.view();
    require(view.bytes <= l.bytes && view.segments <= l.segments && view.live - view.oldest <= l.seconds, "byte/time/count limits held");
    auto reader = buffer.readerAt(view.oldest); require(bool(reader), "bounded reader");
    bool failed = false;
    for (int i = 0; i < 1000; ++i) if (!buffer.append(mp3(), QDateTime::currentDateTimeUtc())) { failed = true; break; }
    require(failed && buffer.view().phase == BufferPhase::ReaderOverrun && buffer.view().bytes <= l.bytes, "pinned overrun visible and bounded");
    unsigned char output[1024]; require(reader->read(output, sizeof(output)) < 0, "overrun fails reader without jumping");
    reader->cancel();
}
static void closeAndLifetime(const QString &root) {
    auto buffer = std::make_unique<TimeshiftBuffer>(root, limits());
    require(buffer->begin("audio/mpeg", "x", mp3Profile()), "lifetime begin"); feed(*buffer, mp3(), 180);
    auto reader = buffer->readerLive(); require(bool(reader), "lifetime reader");
    const auto sessions = QDir(root).entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    require(sessions.size() == 1, "one private session");
    const auto directory = root+'/'+sessions.first();
    buffer.reset();
    unsigned char bytes[10]; require(reader->read(bytes, sizeof(bytes)) == 0, "buffer destruction wakes/closes surviving reader");
    require(QFileInfo::exists(directory), "reader owns session until after VLC stop");
    { TimeshiftBuffer other(root, limits()); require(QFileInfo::exists(directory), "crash cleanup respects surviving reader lock"); }
    reader.reset(); require(!QFileInfo::exists(directory), "last reader releases temporary files");
}
static void formats(const QString &root) {
    auto make = [&](const QString &name) { return std::make_unique<TimeshiftBuffer>(root+'/'+name, limits()); };
    require(verifiedTimeshiftProfile("mp3",32000).clockCorrectionFrames == 1, "measured 32kHz correction");
    require(verifiedTimeshiftProfile("aac",32000).clockCorrectionFrames == 1, "measured AAC 32kHz correction");
    require(!verifiedTimeshiftProfile("mp3",96000).verified && !verifiedTimeshiftProfile("aac",24000).verified, "unmeasured profiles unavailable");
    auto wrongCorrection = make("wrong-correction"); auto wrong = mp3Profile(); wrong.clockCorrectionFrames = 0;
    require(!wrongCorrection->begin("audio/mpeg", "x", wrong), "wrong clock profile rejected");
    auto deferred = make("deferred"); require(deferred->begin("audio/mpeg", "x", DecoderProfile{"mp3"}), "MP3 deferred header profile");
    require(deferred->append(mp3(), {}), "MP3 header selects measured profile");
    auto deferredUnknown = make("deferred-unknown"); require(deferredUnknown->begin("audio/mpeg", "x", DecoderProfile{"mp3"}), "unknown MP3 deferred begin");
    auto lowRate = mp3(9,true); lowRate[1] = char(0xe3);
    require(!deferredUnknown->append(lowRate, {}) && deferredUnknown->view().phase == BufferPhase::Unsupported, "unmeasured MPEG2.5 rate rejected");
    auto deferredAAC = make("deferred-aac"); require(!deferredAAC->begin("audio/aac", "x", DecoderProfile{"aac"}), "AAC requires actual decoder rate");
    require(encodedAACSampleRate(aac()) == 48000 && encodedAACSampleRate(aac(6)) == 24000, "ADTS core rate probe");
    require(encodedAACSampleRate(aac().left(6)) == 0 && encodedAACSampleRate(aac(3,2,1)) == 0, "AAC probe rejects incomplete/invalid header");
    QByteArray probeTag("ID3\4\0\0\0\0\0\4",10); probeTag += "test";
    require(encodedAACSampleRate(probeTag+aac()) == 48000 && encodedAACSampleRate(probeTag.left(9)) == 0, "AAC probe shares bounded ID3 policy");
    auto unverified = make("unverified"); auto p = mp3Profile(); p.verified = false;
    require(!unverified->begin("audio/mpeg", "x", p) && unverified->view().phase == BufferPhase::Unsupported, "unverified decoder rejected");
    auto invalid = make("invalid"); require(invalid->begin("audio/mpeg", "x", mp3Profile()), "invalid begin");
    require(!invalid->append(QByteArray("not audio"), {}) && invalid->view().phase == BufferPhase::InvalidAudio, "bad header rejected");
    auto changed = make("changed"); require(changed->begin("audio/mpeg", "x", mp3Profile()), "format-change begin"); feed(*changed, mp3(), 1);
    require(!changed->append(mp3(9,false,true), {}) && changed->view().phase == BufferPhase::FormatChanged, "channel change rejected");
    for (const auto &index : {QByteArray("Xing"), QByteArray("Info"), QByteArray("VBRI")}) {
        auto indexed = make(QString::fromLatin1(index)); require(indexed->begin("audio/mpeg", "x", mp3Profile()), "indexed MP3 begin");
        auto frame = mp3(); frame.replace(36,4,index);
        require(!indexed->append(frame, {}) && indexed->view().phase == BufferPhase::Unsupported, "MP3 file index rejects unverified gapless timing");
    }
    auto vbr = make("vbr"); require(vbr->begin("audio/mpeg", "x", mp3Profile()), "vbr begin");
    require(vbr->append(mp3(7)+mp3(9)+mp3(11), {}), "VBR bitrate changes allowed");
    auto he = make("he"); require(he->begin("audio/aacp", "x", aacProfile()), "HE probe begin");
    require(!he->append(aac(6), {}) && he->view().phase == BufferPhase::Unsupported, "HE doubled decoder rate rejected");
    auto blocks = make("blocks"); require(blocks->begin("audio/aac", "x", aacProfile()), "aac blocks begin");
    require(!blocks->append(aac(3,2,1), {}) && blocks->view().phase == BufferPhase::InvalidAudio, "ADTS multiple blocks rejected");
    auto channels = make("channels"); require(channels->begin("audio/aac", "x", aacProfile()), "aac channels begin");
    require(!channels->append(aac(3,0), {}), "ADTS unverified channel config rejected");
    auto good = make("aac"); require(good->begin("audio/aac", "x", aacProfile()), "AAC begin"); feed(*good, aac(), 220); require(good->readerLive() != nullptr, "AAC reader ready");
    auto tag = make("tag"); require(tag->begin("audio/mpeg", "x", mp3Profile()), "id3 begin");
    QByteArray id3("ID3\4\0\0\0\0\0\4", 10); id3 += "test";
    require(tag->append(id3.left(5), {}) && tag->append(id3.mid(5)+mp3(), {}), "bounded split ID3 skipped");
    require(std::abs(tag->view().live-.024) < .000001, "ID3 not audio time");
    auto big = make("big-tag"); require(big->begin("audio/mpeg", "x", mp3Profile()), "big id3 begin");
    require(!big->append(QByteArray("ID3\4\0\0\0\4\0\0",10), {}), "oversized ID3 rejected before allocation");
    auto truncated = make("truncated"); require(truncated->begin("audio/mpeg", "x", mp3Profile()), "truncated begin");
    require(truncated->append(mp3().left(30), {}), "partial body buffered"); truncated->endReception();
    require(truncated->view().phase == BufferPhase::InvalidAudio, "truncated end explicit");
    auto truncatedTag = make("truncated-tag"); require(truncatedTag->begin("audio/mpeg", "x", mp3Profile()), "truncated tag begin");
    require(truncatedTag->append(QByteArray("ID3\4\0\0\0\0\1\0", 10), {}), "partial tag accepted provisionally");
    truncatedTag->endReception(); require(truncatedTag->view().phase == BufferPhase::InvalidAudio, "truncated ID3 end explicit");
}
static void ownership(const QString &root) {
    QDir().mkpath(root); chmod(QFile::encodeName(root).constData(),0700);
    const auto name = QUuid::createUuid().toString(QUuid::WithoutBraces), orphan = root+'/'+name;
    QDir().mkpath(orphan); chmod(QFile::encodeName(orphan).constData(),0700);
    { QFile owner(orphan+"/owner"); require(owner.open(QIODevice::WriteOnly), "create marker"); owner.write("MuckeLinuxTimeshift-v1\n"); }
    const int fd = ::open(QFile::encodeName(orphan+"/owner.lock").constData(),O_CREAT|O_RDWR,0600);
    require(fd >= 0 && flock(fd, LOCK_EX|LOCK_NB)==0, "own orphan lock");
    { TimeshiftBuffer active(root,limits()); require(QFileInfo::exists(orphan), "locked session survives cleanup"); }
    flock(fd,LOCK_UN); ::close(fd);
    { TimeshiftBuffer cleanup(root,limits()); require(!QFileInfo::exists(orphan), "unlocked recognized session removed"); }
    const auto unsafe = root+'/'+QUuid::createUuid().toString(QUuid::WithoutBraces);
    QDir().mkpath(unsafe); chmod(QFile::encodeName(unsafe).constData(),0700);
    { QFile owner(unsafe+"/owner"); owner.open(QIODevice::WriteOnly); owner.write("MuckeLinuxTimeshift-v1\n"); }
    { QFile lock(unsafe+"/owner.lock"); lock.open(QIODevice::WriteOnly); }
    require(QFile::link("/tmp", unsafe+"/segment-00000000.data"), "create symlink fixture");
    { TimeshiftBuffer cleanup(root,limits()); require(QFileInfo::exists(unsafe), "symlink-bearing session untouched"); }
    const auto target = root+"-target", link = root+"-link";
    QDir().mkpath(target); chmod(QFile::encodeName(target).constData(),0700); require(QFile::link(target,link), "root symlink fixture");
    TimeshiftBuffer symlink(link,limits()); require(symlink.view().phase == BufferPhase::IOError, "symlink root rejected");
}
static void errors(const QString &root) {
    auto low = limits(); low.minimumFreeBytes = std::numeric_limits<qint64>::max();
    TimeshiftBuffer disk(root+"/low",low); require(!disk.begin("audio/mpeg","x",mp3Profile()) && disk.view().phase == BufferPhase::LowDisk,"low disk rejected");
    TimeshiftBuffer writes(root+"/writes",limits()); require(writes.begin("audio/mpeg","x",mp3Profile()),"write failure begin");
    const auto session = QDir(root+"/writes").entryList(QDir::Dirs|QDir::NoDotAndDotDot).first();
    const auto path = root+"/writes/"+session;
    require(QDir(path).mkdir("segment-00000000.data"),"block segment creation");
    require(!writes.append(mp3(),{}) && writes.view().phase == BufferPhase::IOError,"exclusive segment write error visible");
}
int main(int argc,char **argv) {
    QCoreApplication app(argc,argv);
    try {
        QTemporaryDir directory; require(directory.isValid(),"temporary root");
        storageAndReaders(directory.path()+"/readers"); warmupBoundary(directory.path()+"/warmup"); partialMetadata(directory.path()+"/partial"); bounds(directory.path()+"/bounds");
        formats(directory.path()+"/formats"); closeAndLifetime(directory.path()+"/lifetime"); ownership(directory.path()+"/ownership"); errors(directory.path()+"/errors");
        std::cout << "timeshift: frames, bounds, metadata, growing reader, cancel, format, disk, writes and ownership passed\n";
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
