#pragma once
#include <QtWidgets>

namespace Mucke::Console {
struct Colors {
    QColor bg, panel, stage, fg, muted, accent, secondary, divider;
    QString font, titleFont;
};
Colors colors(const QString &theme);
void initializeFonts();
enum class Surface { Window, Panel, History, Stage, Header, Footer };
void paintSurface(QPainter &, QRect, const QString &, Surface);
enum ItemRole { SubtitleRole = Qt::UserRole + 20, ActiveRole, FavoriteRole, PlayingRole };
enum class Symbol {
    Search,
    Add,
    Edit,
    Settings,
    Audio,
    History,
    Palette,
    Mini,
    Fullscreen,
    More,
    Folder,
    List,
    Heart,
    Bookmarks,
    Record,
    Timer,
    Back,
    Forward,
    Speaker,
    Music,
    Spotify,
    Lyrics,
    Export,
    Play,
    Stop,
    Pin,
    Waveform,
    Recognition
};
QIcon icon(Symbol, QColor, int size = 18);

class ActionButton final : public QPushButton {
  public:
    QColor ink;
    explicit ActionButton(QString caption, QWidget *parent = nullptr);

  protected:
    void paintEvent(QPaintEvent *) override;
};

class SurfaceWidget final : public QWidget {
  public:
    QString theme = "schlicht";
    Surface surface;
    explicit SurfaceWidget(Surface, QWidget *parent = nullptr);

  protected:
    void paintEvent(QPaintEvent *) override;
};

class Columns final : public QWidget {
    QWidget *stations, *stage, *history;
    bool historyVisible = true;
    void arrange();

  public:
    Columns(QWidget *stations, QWidget *stage, QWidget *history, QWidget *parent = nullptr);
    void showHistory(bool);
    bool hasHistory() const { return historyVisible; }

  protected:
    void resizeEvent(QResizeEvent *) override;
};

class ItemDelegate final : public QStyledItemDelegate {
  public:
    enum class Kind { Station, Track };
    QString theme = "schlicht";
    Kind kind;
    explicit ItemDelegate(Kind, QObject *parent = nullptr);
    void paint(QPainter *, const QStyleOptionViewItem &, const QModelIndex &) const override;
    QSize sizeHint(const QStyleOptionViewItem &, const QModelIndex &) const override;
};

class Visualizer final : public QWidget {
    QPixmap background;
    QString backgroundTheme;
    QSize backgroundSize;
    quint64 backgroundPalette = 0;
    QVector<QVector<float>> noteHistory;
    QVector<float> noteValues;
    qint64 lastNotePush = -1;
    double meterLevel = 0;
    QElapsedTimer elapsed;
    qint64 previousFrame = 0;
    void paintMeter(QPainter &, QRectF, int channel, double level);

  public:
    QString theme = "schlicht";
    QVector<float> wave, spectrum;
    float rms = 0;
    explicit Visualizer(QWidget *parent = nullptr);

  protected:
    void paintEvent(QPaintEvent *) override;
    void hideEvent(QHideEvent *) override;
};

class VolumeKnob final : public QSlider {
    QPoint dragOrigin;
    int dragValue = 0;

  public:
    QColor tint;
    explicit VolumeKnob(QWidget *parent = nullptr);

  protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
};
} // namespace Mucke::Console
