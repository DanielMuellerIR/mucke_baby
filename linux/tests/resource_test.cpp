#include <QCoreApplication>
#include <QCryptographicHash>
#include <QFile>
#include <QTextStream>
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QFile seed(QStringLiteral(":/Resources/seed-stations.example.json"));
    if (!seed.open(QIODevice::ReadOnly) ||
        QCryptographicHash::hash(seed.readAll(), QCryptographicHash::Sha256).toHex() != QByteArray(MUCKE_PUBLIC_SEED_HASH) ||
        QFile::exists(QStringLiteral(":/Resources/seed-stations.json"))) {
        QTextStream(stderr) << "Embedded public seed check failed\n";
        return 1;
    }
    QTextStream(stdout) << "Embedded resource matches public seed; private alias absent\n";
}
