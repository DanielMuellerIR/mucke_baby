#include "consolewidgets.h"
#include <algorithm>
#include <cmath>

namespace Mucke::Console {
namespace {
QColor alpha(QColor color, double value) {
    color.setAlphaF(value);
    return color;
}
QString textureFor(const QString &theme) {
    static const QHash<QString, QString> files{{"acid", "bg-concrete.png"},     {"retro", "bg-brushed.png"},
                                               {"fanzine", "bg-newsprint.png"}, {"stack", "bg-tolex.png"},
                                               {"danish", "bg-aluminum.png"},   {"midi", "bg-cyber.png"}};
    return files.contains(theme) ? ":/themes/" + theme + "/" + files.value(theme) : QString();
}
QFont consoleFont(const QString &family, int size, QFont::Weight weight = QFont::Normal) {
    QFont result(family);
    result.setPixelSize(size);
    result.setWeight(weight);
    return result;
}
void texture(QPainter &p, QRect rect, const QString &path, double opacity) {
    if (path.isEmpty())
        return;
    QPixmap image;
    if (!QPixmapCache::find(path, &image)) {
        image.load(path);
        if (!image.isNull())
            QPixmapCache::insert(path, image);
    }
    if (image.isNull())
        return;
    p.save();
    p.setOpacity(opacity);
    const QSize scaled = image.size().scaled(rect.size(), Qt::KeepAspectRatioByExpanding);
    const QRect target(
        QPoint(rect.center().x() - scaled.width() / 2, rect.center().y() - scaled.height() / 2), scaled);
    p.setClipRect(rect);
    p.drawPixmap(target, image);
    p.restore();
}
QPainterPath sector(QPointF center, double radius, double first = 30, double last = 150) {
    QPainterPath path;
    path.moveTo(center);
    path.arcTo(QRectF(center.x() - radius, center.y() - radius, radius * 2, radius * 2), first, last - first);
    path.closeSubpath();
    return path;
}
QPainterPath sectorBand(QPointF center, double radius) {
    const auto point = [&](double angle, double r) {
        return center + QPointF(std::cos(angle * M_PI / 180) * r, -std::sin(angle * M_PI / 180) * r);
    };
    QPainterPath path;
    path.moveTo(point(30, radius));
    path.arcTo(QRectF(center.x() - radius, center.y() - radius, 2 * radius, 2 * radius), 30, 24);
    path.lineTo(point(54, radius * .55));
    path.arcTo(QRectF(center.x() - radius * .55, center.y() - radius * .55, radius * 1.1, radius * 1.1), 54,
               -24);
    path.closeSubpath();
    return path;
}
} // namespace
Colors colors(const QString &id) {
    const QString sans = "DejaVu Sans", serif = "DejaVu Serif", mono = "DejaVu Sans Mono";
    if (id == "acid")
        return {"#1A1B1E", "#121315", "#0E0F11", "#E8EBE9", "#8A8F94",
                "#39FF14", "#00E5FF", "#2A2C2F", mono,      mono};
    if (id == "retro")
        return {"#1C1A17", "#23201B", "#1A1714", "#F5F0E1", "#C9A227",
                "#FF9F0A", "#C9A227", "#3A352C", serif,     serif};
    if (id == "fanzine")
        return {"#ECEAE3", "#F4F2EC", "#F0EEE6", "#0D0D0D",    "#3A3A3A",
                "#0D0D0D", "#B5231F", "#A6A198", "Zilla Slab", "Zilla Slab"};
    if (id == "stack")
        return {"#0A0A0A", "#141414", "#0D0D0D", "#F7F4EC", "#C8A03C",
                "#C8A03C", "#E8C766", "#2A2419", sans,      serif};
    if (id == "danish")
        return {"#ECEAE6", "#F3F1EE", "#EFEDE9", "#1A1A1A", "#514C44",
                "#4C4842", "#B5894F", "#CFCBC3", sans,      sans};
    if (id == "midi")
        return {"#050507", "#0A0A12", "#060608", "#E8E8FF", "#7A7AA0",
                "#FF2EC4", "#1EE6FF", "#1A1A2E", mono,      mono};
    const bool dark = QApplication::palette().color(QPalette::Window).lightness() < 128;
    return dark ? Colors{"#202020", "#202020", "#202020", "#EAEAEA", "#A0A0A0",
                         "#008CFF", "#008CFF", "#343434", sans,      sans}
                : Colors{"#F5F5F5", "#F7F7F7", "#FFFFFF", "#252525", "#747474",
                         "#007AFF", "#007AFF", "#DDDDDD", sans,      sans};
}
void initializeFonts() {
    static const bool initialized = [] {
        QFontDatabase::addApplicationFont(":/fonts/ZillaSlab-Regular.ttf");
        QFontDatabase::addApplicationFont(":/fonts/ZillaSlab-Bold.ttf");
        return true;
    }();
    Q_UNUSED(initialized);
}
void paintSurface(QPainter &p, QRect rect, const QString &theme, Surface role) {
    const auto c = colors(theme);
    p.fillRect(rect, role == Surface::Stage ? c.stage : role == Surface::Window ? c.bg : c.panel);
    if (theme == "stack" && role == Surface::Header) {
        QLinearGradient gold(rect.topLeft(), rect.bottomLeft());
        gold.setColorAt(0, QColor("#F7D97A"));
        gold.setColorAt(.5, QColor("#D5A642"));
        gold.setColorAt(1, QColor("#94691C"));
        p.fillRect(rect, gold);
        texture(p, rect, ":/themes/stack/plate-gold.png", .25);
        p.setPen(alpha(Qt::white, .13));
        for (int y = 1; y < rect.height(); y += 2)
            p.drawLine(rect.left(), rect.top() + y, rect.right(), rect.top() + y);
        p.setPen(alpha(Qt::white, .55));
        p.drawLine(rect.topLeft(), rect.topRight());
        p.setPen(alpha(Qt::black, .5));
        p.drawLine(rect.bottomLeft(), rect.bottomRight());
        return;
    }
    if (theme == "retro" && role == Surface::History) {
        p.fillRect(rect, QColor("#EEE3C7"));
        texture(p, rect, ":/themes/retro/paper.png", .65);
        return;
    }
    if (theme == "schlicht" ||
        (theme == "danish" && role != Surface::Stage && role != Surface::Header && role != Surface::Footer))
        return;
    texture(p, rect, textureFor(theme), role == Surface::Stage ? .5 : role == Surface::Window ? .68 : .12);
    if (theme == "retro" && role != Surface::Stage) {
        p.setPen(alpha(Qt::white, .06));
        for (int y = 1; y < rect.height(); y += 3)
            p.drawLine(rect.left(), rect.top() + y, rect.right(), rect.top() + y);
    }
    if (theme == "fanzine") {
        p.setPen(Qt::NoPen);
        p.setBrush(alpha(c.muted, .08));
        for (int y = rect.top() + 2; y < rect.bottom(); y += 8)
            for (int x = rect.left() + 2; x < rect.right(); x += 8)
                p.drawEllipse(QPointF(x, y), .7, .7);
    }
    if (theme == "midi") {
        p.setPen(alpha(c.muted, theme == "midi" ? .09 : .035));
        const int step = theme == "midi" ? 20 : 4;
        for (int x = rect.left(); x < rect.right(); x += step)
            p.drawLine(x, rect.top(), x, rect.bottom());
        for (int y = rect.top(); y < rect.bottom(); y += step)
            p.drawLine(rect.left(), y, rect.right(), y);
    }
}
QIcon icon(Symbol symbol, QColor color, int size) {
    QPixmap image(size * 2, size * 2);
    image.setDevicePixelRatio(2);
    image.fill(Qt::transparent);
    QPainter p(&image);
    p.setRenderHint(QPainter::Antialiasing);
    p.scale(size / 20., size / 20.);
    p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
    p.setBrush(Qt::NoBrush);
    switch (symbol) {
    case Symbol::Search:
        p.drawEllipse(QRectF(3, 2, 11, 11));
        p.drawLine(QPointF(12, 12), QPointF(17, 17));
        break;
    case Symbol::Add:
        p.drawLine(10, 3, 10, 17);
        p.drawLine(3, 10, 17, 10);
        break;
    case Symbol::Edit:
        p.drawLine(4, 16, 14, 4);
        p.drawLine(6, 17, 16, 5);
        p.drawLine(4, 16, 3, 18);
        p.drawLine(14, 4, 16, 5);
        break;
    case Symbol::Settings:
        p.drawEllipse(QRectF(7, 7, 6, 6));
        for (int i = 0; i < 8; ++i) {
            p.save();
            p.translate(10, 10);
            p.rotate(i * 45);
            p.drawLine(0, -6, 0, -9);
            p.restore();
        }
        p.drawEllipse(QRectF(4, 4, 12, 12));
        break;
    case Symbol::Audio:
        for (int i = 0; i < 3; ++i) {
            int x = 4 + i * 6, y = 5 + (i % 2) * 7;
            p.drawLine(x, 2, x, 18);
            p.fillRect(QRectF(x - 2, y - 2, 4, 4), color);
        }
        break;
    case Symbol::History:
        p.drawRoundedRect(QRectF(2, 3, 16, 14), 1, 1);
        p.drawLine(13, 3, 13, 17);
        p.drawLine(15, 6, 16, 6);
        break;
    case Symbol::Palette:
        p.drawEllipse(QRectF(2, 3, 16, 13));
        p.drawEllipse(QRectF(5, 7, 1.5, 1.5));
        p.drawEllipse(QRectF(9, 5, 1.5, 1.5));
        p.drawEllipse(QRectF(13, 7, 1.5, 1.5));
        p.drawEllipse(QRectF(7, 11, 1.5, 1.5));
        break;
    case Symbol::Mini:
        p.drawRoundedRect(QRectF(2, 3, 16, 14), 1, 1);
        p.drawRect(QRectF(10, 10, 6, 5));
        break;
    case Symbol::Fullscreen:
        p.drawLine(3, 8, 3, 3);
        p.drawLine(3, 3, 8, 3);
        p.drawLine(12, 3, 17, 3);
        p.drawLine(17, 3, 17, 8);
        p.drawLine(3, 12, 3, 17);
        p.drawLine(3, 17, 8, 17);
        p.drawLine(12, 17, 17, 17);
        p.drawLine(17, 17, 17, 12);
        break;
    case Symbol::More:
        p.drawEllipse(QRectF(2, 2, 16, 16));
        for (int x : {6, 10, 14})
            p.drawPoint(x, 10);
        break;
    case Symbol::Folder:
        p.drawPolyline(QPolygonF{{2, 16}, {2, 5}, {8, 5}, {10, 7}, {18, 7}, {18, 16}, {2, 16}});
        break;
    case Symbol::List:
        p.drawRoundedRect(QRectF(2, 4, 16, 12), 1, 1);
        for (int y : {7, 10, 13}) {
            p.drawPoint(5, y);
            p.drawLine(8, y, 15, y);
        }
        break;
    case Symbol::Heart: {
        QPainterPath a;
        a.moveTo(10, 17);
        a.cubicTo(1, 11, 1, 6, 5, 4);
        a.cubicTo(8, 3, 10, 6, 10, 6);
        a.cubicTo(14, -1, 25, 7, 10, 17);
        p.drawPath(a);
        break;
    }
    case Symbol::Bookmarks:
        p.drawRoundedRect(QRectF(3, 2, 14, 16), 1, 1);
        p.drawLine(6, 12, 14, 12);
        p.drawLine(6, 15, 12, 15);
        p.drawEllipse(QRectF(7, 5, 6, 4));
        break;
    case Symbol::Record:
        p.setPen(Qt::NoPen);
        p.setBrush(color);
        p.drawEllipse(QRectF(4, 4, 12, 12));
        p.setBrush(QColor("#202020"));
        p.drawEllipse(QRectF(8, 8, 4, 4));
        break;
    case Symbol::Timer:
        p.drawArc(QRectF(3, 4, 14, 14), 10 * 16, 310 * 16);
        p.drawLine(10, 7, 10, 12);
        p.drawLine(10, 12, 13, 13);
        p.drawLine(7, 1, 13, 1);
        break;
    case Symbol::Back:
    case Symbol::Forward:
        p.drawArc(QRectF(3, 4, 14, 14), 20 * 16, 310 * 16);
        p.drawText(QRectF(2, 5, 16, 11), Qt::AlignCenter, "15");
        p.drawLine(4, 3, 4, 8);
        p.drawLine(4, 3, 9, 3);
        break;
    case Symbol::Speaker:
        p.drawPolygon(QPolygonF{{2, 8}, {5, 8}, {9, 4}, {9, 16}, {5, 12}, {2, 12}});
        p.drawArc(QRectF(7, 5, 9, 10), -70 * 16, 140 * 16);
        p.drawArc(QRectF(6, 2, 13, 16), -65 * 16, 130 * 16);
        break;
    case Symbol::Music:
    case Symbol::Spotify:
        p.drawLine(9, 4, 9, 15);
        p.drawLine(9, 4, 16, 2);
        p.drawLine(16, 2, 16, 13);
        p.setBrush(color);
        p.drawEllipse(QRectF(4, 13, 5, 4));
        p.drawEllipse(QRectF(11, 11, 5, 4));
        break;
    case Symbol::Lyrics:
        p.drawText(QRectF(2, 0, 18, 12), Qt::AlignLeft, "“");
        for (int y : {10, 14, 18})
            p.drawLine(3, y, 17, y);
        break;
    case Symbol::Export:
        p.drawRoundedRect(QRectF(3, 7, 14, 11), 1, 1);
        p.drawLine(10, 1, 10, 13);
        p.drawLine(6, 5, 10, 1);
        p.drawLine(10, 1, 14, 5);
        break;
    case Symbol::Play:
        p.setBrush(color);
        p.drawPolygon(QPolygonF{{5, 3}, {17, 10}, {5, 17}});
        break;
    case Symbol::Stop:
        p.setBrush(color);
        p.drawRoundedRect(QRectF(4, 4, 12, 12), 1, 1);
        break;
    case Symbol::Pin:
        p.drawPolyline(
            QPolygonF{{6, 2}, {14, 2}, {12, 5}, {12, 10}, {15, 13}, {5, 13}, {8, 10}, {8, 5}, {6, 2}});
        p.drawLine(10, 13, 10, 18);
        break;
    case Symbol::Waveform:
    case Symbol::Recognition:
        for (int i = 0; i < 5; ++i) {
            const int length = i == 2 ? 14 : i % 2 ? 9 : 4;
            const int x = 3 + i * 3;
            p.drawLine(QPointF(x, 10 - length / 2.), QPointF(x, 10 + length / 2.));
        }
        if (symbol == Symbol::Recognition) {
            p.setBrush(Qt::NoBrush);
            p.drawEllipse(QRectF(11, 10, 6, 6));
            p.drawLine(16, 15, 19, 18);
        }
        break;
    }
    return QIcon(image);
}
ActionButton::ActionButton(QString caption, QWidget *parent) : QPushButton(std::move(caption), parent) {
    setFixedSize(48, 40);
    setCursor(Qt::PointingHandCursor);
}
void ActionButton::paintEvent(QPaintEvent *) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);
    if (underMouse() || isDown())
        p.fillRect(rect(), alpha(ink, .08));
    icon().paint(&p, QRect((width() - 16) / 2, 3, 16, 16), Qt::AlignCenter,
                 isEnabled() ? QIcon::Normal : QIcon::Disabled);
    p.setPen(isEnabled() ? ink : alpha(ink, .5));
    auto labelFont = font();
    labelFont.setPixelSize(9);
    p.setFont(labelFont);
    p.drawText(QRect(0, 22, width(), 15), Qt::AlignCenter, text());
}
SurfaceWidget::SurfaceWidget(Surface role, QWidget *parent) : QWidget(parent), surface(role) {
    setAttribute(Qt::WA_OpaquePaintEvent);
}
void SurfaceWidget::paintEvent(QPaintEvent *) {
    QPainter p(this);
    paintSurface(p, rect(), theme, surface);
}
Columns::Columns(QWidget *left, QWidget *center, QWidget *right, QWidget *parent)
    : QWidget(parent), stations(left), stage(center), history(right) {
    for (auto *child : {stations, stage, history})
        child->setParent(this);
}
void Columns::arrange() {
    const bool showStage = width() >= 780;
    const int stageWidth = showStage ? std::clamp(qRound(width() * .30), 300, 520) : 0;
    const int rest = std::max(0, width() - stageWidth - int(showStage) - int(historyVisible));
    const int leftWidth = historyVisible ? rest / 2 : rest;
    stations->setGeometry(0, 0, leftWidth, height());
    stage->setVisible(showStage);
    stage->setGeometry(leftWidth + 1, 0, stageWidth, height());
    history->setVisible(historyVisible);
    history->setGeometry(leftWidth + (showStage ? stageWidth + 1 : 0) + 1, 0, rest - leftWidth, height());
}
void Columns::resizeEvent(QResizeEvent *) { arrange(); }
void Columns::showHistory(bool visible) {
    historyVisible = visible;
    arrange();
}
ItemDelegate::ItemDelegate(Kind kind, QObject *parent) : QStyledItemDelegate(parent), kind(kind) {}
QSize ItemDelegate::sizeHint(const QStyleOptionViewItem &option, const QModelIndex &index) const {
    if (kind == Kind::Station)
        return {100, index.data(SubtitleRole).toString().isEmpty() ? 33 : 49};
    const auto c = colors(theme);
    QFontMetrics metrics(consoleFont(c.font, theme == "fanzine" ? 13 : 12));
    const QString title = index.siblingAtColumn(1).data().toString();
    const auto *view = qobject_cast<const QTableView *>(parent());
    const int width = std::max(80, (view ? view->viewport()->width() : option.rect.width()) - 28);
    const int lines =
        std::clamp(metrics.boundingRect(QRect(0, 0, width, 200), Qt::TextWordWrap, title).height(),
                   metrics.height(), metrics.height() * 3);
    return {100, lines + 45};
}
void ItemDelegate::paint(QPainter *p, const QStyleOptionViewItem &option, const QModelIndex &index) const {
    if (index.column() != 0)
        return;
    p->save();
    p->setClipRect(option.rect);
    p->setRenderHint(QPainter::Antialiasing);
    const auto c = colors(theme);
    const QRect r = option.rect;
    const bool active = index.data(ActiveRole).toBool(), selected = option.state & QStyle::State_Selected;
    if (selected || active)
        p->fillRect(r, alpha(c.accent, theme == "fanzine" ? .09 : .06));
    const QColor ink = kind == Kind::Track && theme == "retro" ? QColor("#2A2018") : c.fg;
    const QColor muted = kind == Kind::Track && theme == "retro"  ? QColor("#5C4A38")
                         : kind == Kind::Track && theme == "midi" ? c.secondary
                                                                  : c.muted;
    p->setPen(alpha(c.divider, .6));
    p->drawLine(r.bottomLeft(), r.bottomRight());
    if (kind == Kind::Station) {
        const int x = r.left() + 12;
        const QString subtitle = index.data(SubtitleRole).toString();
        const int center = r.top() + (subtitle.isEmpty() ? r.height() / 2 : 16);
        if (theme == "retro" || theme == "stack") {
            p->setPen(active ? c.accent : alpha(c.muted, .6));
            p->setFont(consoleFont(c.font, 10));
            p->drawText(QRect(x - 3, center - 8, 22, 16), Qt::AlignRight,
                        QString::number(index.row() + 1) + ".");
        } else {
            p->setPen(Qt::NoPen);
            p->setBrush(active ? c.accent : alpha(c.muted, .25));
            p->drawEllipse(QPointF(x + 7, center), theme == "acid" || theme == "midi" ? 4 : 2.5,
                           theme == "acid" || theme == "midi" ? 4 : 2.5);
        }
        p->setPen(ink);
        p->setFont(consoleFont(c.font, theme == "fanzine" ? 13 : 12,
                               active              ? QFont::DemiBold
                               : theme == "danish" ? QFont::Light
                                                   : QFont::Normal));
        const QString name = (theme == "midi" ? ">>> " : QString()) + index.data().toString();
        p->drawText(QRect(x + 22, center - 9, r.width() - 65, 18), Qt::AlignVCenter,
                    p->fontMetrics().elidedText(name, Qt::ElideRight, r.width() - 65));
        if (!subtitle.isEmpty()) {
            p->setFont(consoleFont(c.font, 10));
            p->setPen(muted);
            p->drawText(QRect(x + 22, center + 10, r.width() - 55, 16), Qt::AlignVCenter,
                        p->fontMetrics().elidedText(subtitle, Qt::ElideRight, r.width() - 55));
        }
        if (index.data(FavoriteRole).toBool()) {
            p->setPen(c.accent);
            p->setFont(consoleFont(c.font, 13));
            p->drawText(QRect(r.right() - 27, center - 10, 20, 20), Qt::AlignCenter, "★");
        }
    } else {
        p->setFont(consoleFont(c.font, 10));
        p->setPen(active ? c.accent : muted);
        p->drawText(QRect(r.left() + 12, r.top() + 8, r.width() - 30, 15), Qt::AlignVCenter,
                    index.data().toString());
        p->setPen(ink);
        p->setFont(
            consoleFont(c.font, theme == "fanzine" ? 13 : 12, active ? QFont::DemiBold : QFont::Normal));
        const QRect title(r.left() + 12, r.top() + 25, r.width() - 28, r.height() - 46);
        p->drawText(title, Qt::TextWordWrap | Qt::AlignTop, index.siblingAtColumn(1).data().toString());
        p->setFont(consoleFont(c.font, 10));
        p->setPen(muted);
        p->drawText(QRect(r.left() + 12, r.bottom() - 18, r.width() - 24, 15), Qt::AlignVCenter,
                    p->fontMetrics().elidedText(index.siblingAtColumn(2).data().toString(), Qt::ElideRight,
                                                r.width() - 24));
    }
    p->restore();
}
Visualizer::Visualizer(QWidget *parent) : QWidget(parent) {
    initializeFonts();
    setAttribute(Qt::WA_OpaquePaintEvent);
    setMinimumWidth(0);
    setMinimumHeight(80);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    elapsed.start();
}
void Visualizer::paintMeter(QPainter &p, QRectF area, int channel, double level) {
    const auto c = colors(theme);
    const bool retro = theme == "retro";
    const double margin = std::min(area.width(), area.height()) * .06;
    const double radius =
        std::max(1., std::min((area.width() - 2 * margin) / 1.732, area.height() - 2 * margin));
    const QPointF center(area.center().x(), area.center().y() + radius / 2);
    QLinearGradient bezel(area.topLeft(), area.bottomRight());
    bezel.setColorAt(0, retro ? QColor("#E1D6BE") : QColor("#F6D878"));
    bezel.setColorAt(.5, retro ? QColor("#8B7B5D") : QColor("#C79B38"));
    bezel.setColorAt(1, retro ? QColor("#30281B") : QColor("#6F4D12"));
    p.setPen(Qt::NoPen);
    p.fillPath(sector(center + QPointF(1, 3), radius * 1.10), alpha(Qt::black, .3));
    p.fillPath(sector(center, radius * 1.10), bezel);
    p.fillPath(sector(center, radius * 1.04), QColor("#211C12"));
    p.fillPath(sector(center, radius), retro ? QColor("#F2E8CE") : QColor("#16140E"));
    const QColor ink = retro ? QColor("#5C4A2E") : c.muted;
    p.fillPath(sectorBand(center, radius), alpha(QColor("#FF3B30"), .35));
    p.setPen(QPen(alpha(ink, .7), 1));
    for (int i = 0; i < 11; ++i) {
        const double angle = (150 - i * 12) * M_PI / 180;
        auto point = [&](double r) { return center + QPointF(std::cos(angle) * r, -std::sin(angle) * r); };
        p.drawLine(point(radius * .8), point(radius * .94));
    }
    const QColor needle = retro ? QColor("#7A2E12") : c.accent;
    const double angle = (150 - std::clamp(level - (channel ? .03 : 0), 0., 1.) * 120) * M_PI / 180;
    p.setPen(QPen(needle, 2, Qt::SolidLine, Qt::RoundCap));
    p.drawLine(center, center + QPointF(std::cos(angle) * radius * .85, -std::sin(angle) * radius * .85));
    p.setPen(Qt::NoPen);
    QRadialGradient pivot(center - QPointF(1, 1), radius * .05);
    pivot.setColorAt(0, needle);
    pivot.setColorAt(1, QColor("#251E10"));
    p.setBrush(pivot);
    p.drawEllipse(center, std::max(3., radius * .038), std::max(3., radius * .038));
    p.setPen(ink);
    p.setFont(consoleFont(c.titleFont, std::max(13, int(radius * .23)), QFont::Bold));
    p.drawText(QRectF(center.x() - radius * .3, center.y() - radius * .6, radius * .6, radius * .3),
               Qt::AlignCenter, channel ? "R" : "L");
}
void Visualizer::paintEvent(QPaintEvent *) {
    if (width() < 2 || height() < 2)
        return;
    const auto paletteKey = QApplication::palette().cacheKey();
    if (backgroundSize != size() || backgroundTheme != theme || backgroundPalette != paletteKey) {
        background = QPixmap(size());
        QPainter b(&background);
        paintSurface(b, rect(), theme, Surface::Stage);
        backgroundTheme = theme;
        backgroundSize = size();
        backgroundPalette = paletteKey;
    }
    QPainter p(this);
    p.drawPixmap(0, 0, background);
    p.setRenderHint(QPainter::Antialiasing);
    const auto c = colors(theme);
    QRectF area = QRectF(rect()).adjusted(20, 20, -20, -20);
    if (area.width() <= 0 || area.height() <= 0)
        return;
    const auto timestamp = elapsed.elapsed();
    const double dt = previousFrame ? std::clamp((timestamp - previousFrame) / 1000., 0., .1) : .04;
    previousFrame = timestamp;
    const double target = std::clamp(std::sqrt(std::max(0., double(rms))), 0., 1.);
    if (wave.isEmpty() && spectrum.isEmpty() && rms <= 0)
        meterLevel = 0;
    meterLevel += (target - meterLevel) * (1 - std::exp(-(target > meterLevel ? 38. : 8.) * dt));
    if (theme == "retro" || theme == "stack") {
        const bool stacked = area.width() < area.height() * 1.8;
        const double gap = 8;
        for (int channel = 0; channel < 2; ++channel) {
            QRectF cell = area;
            if (stacked) {
                cell.setHeight((area.height() - gap) / 2);
                cell.moveTop(area.top() + channel * (cell.height() + gap));
            } else {
                cell.setWidth((area.width() - 14) / 2);
                cell.moveLeft(area.left() + channel * (cell.width() + 14));
            }
            paintMeter(p, cell, channel, meterLevel);
        }
    } else if (theme == "midi") {
        constexpr int lanes = 24, rows = 48;
        if (spectrum.isEmpty())
            noteHistory.clear();
        else if (dt > 0) {
            QVector<float> frame(lanes);
            for (int i = 0; i < lanes; ++i)
                if (!spectrum.isEmpty())
                    frame[i] =
                        spectrum[std::min(spectrum.size() - 1, qsizetype(i * spectrum.size() / lanes))];
            noteHistory.prepend(frame);
            if (noteHistory.size() > rows)
                noteHistory.resize(rows);
        }
        const double lane = area.width() / lanes, row = (area.height() * .78) / rows;
        p.setPen(QPen(alpha(c.muted, .2), .5));
        for (int i = 0; i <= lanes; ++i)
            p.drawLine(QPointF(area.left() + lane * i, area.top()),
                       QPointF(area.left() + lane * i, area.bottom()));
        for (int i = 0; i < rows; i += 4)
            p.drawLine(QPointF(area.left(), area.top() + row * i),
                       QPointF(area.right(), area.top() + row * i));
        p.setPen(Qt::NoPen);
        for (int y = 0; y < noteHistory.size(); ++y)
            for (int x = 0; x < lanes; ++x) {
                double value = noteHistory[y][x];
                if (value < .015)
                    continue;
                QColor col = value > .5 ? c.accent : c.secondary;
                col.setAlphaF(std::clamp(value * 2, .15, 1.));
                p.fillRect(QRectF(area.left() + x * lane + lane * .18, area.top() + y * row, lane * .64,
                                  std::max(1., row - .5)),
                           col);
            }
        for (int i = 0; i < lanes; ++i) {
            const double value =
                spectrum.isEmpty()
                    ? 0
                    : std::clamp(double(spectrum[std::min(spectrum.size() - 1,
                                                          qsizetype(i * spectrum.size() / lanes))]),
                                 0., 1.);
            QLinearGradient grad(area.bottomLeft(), area.topLeft());
            grad.setColorAt(0, c.secondary);
            grad.setColorAt(1, c.accent);
            p.setBrush(grad);
            const double h = value * area.height() * .18;
            p.drawRoundedRect(QRectF(area.left() + i * lane + lane * .2, area.bottom() - std::max(1., h),
                                     lane * .6, std::max(1., h)),
                              1, 1);
        }
    } else if (theme == "danish") {
        constexpr int count = 18;
        const double step = area.width() / count;
        p.setPen(Qt::NoPen);
        for (int i = 0; i < count; ++i) {
            const double value =
                spectrum.isEmpty()
                    ? 0
                    : std::clamp(double(spectrum[std::min(spectrum.size() - 1,
                                                          qsizetype(i * spectrum.size() / count))]),
                                 0., 1.);
            const double h = std::max(2., value * area.height() * .92);
            QLinearGradient grad(QPointF(0, area.center().y() - h / 2),
                                 QPointF(0, area.center().y() + h / 2));
            grad.setColorAt(0, QColor("#57534B"));
            grad.setColorAt(.5, c.secondary);
            grad.setColorAt(1, QColor("#57534B"));
            p.setBrush(grad);
            p.drawRoundedRect(QRectF(area.left() + i * step, area.center().y() - h / 2, step * .65, h), 2, 2);
        }
    } else {
        const QColor first = theme == "acid" ? c.secondary : c.accent;
        QLinearGradient gradient(area.topLeft(), area.topRight());
        gradient.setColorAt(0, first);
        gradient.setColorAt(1, c.accent);
        p.setPen(QPen(alpha(first, .12), 1));
        p.drawLine(QPointF(area.left(), area.center().y()), QPointF(area.right(), area.center().y()));
        QPainterPath trace;
        const int count = std::min(512, int(wave.size()));
        for (int i = 0; i < std::max(2, count); ++i) {
            const double x = area.left() + area.width() * i / std::max(1, count - 1);
            const double sample = count ? wave[i] : 0;
            const double y = area.center().y() - sample * area.height() * .45;
            if (i == 0)
                trace.moveTo(x, y);
            else
                trace.lineTo(x, y);
        }
        if (theme != "fanzine") {
            p.setPen(QPen(alpha(first, .16), 6));
            p.drawPath(trace);
        }
        p.setPen(QPen(QBrush(gradient), theme == "fanzine" ? 1.5 : 2));
        p.drawPath(trace);
        p.setPen(alpha(first, .45));
        p.setFont(consoleFont("DejaVu Sans Mono", 8, QFont::Bold));
        p.drawText(QPointF(area.left() + 4, area.bottom() - 4), theme == "fanzine" ? "OSC" : "SCOPE");
    }
}
VolumeKnob::VolumeKnob(QWidget *parent) : QSlider(Qt::Horizontal, parent) {
    setRange(0, 100);
    setFixedSize(42, 44);
    setAccessibleName(tr("Volume"));
}
void VolumeKnob::paintEvent(QPaintEvent *) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);
    const QPointF center(width() / 2., 17);
    const double radius = 15;
    QConicalGradient gold(center, 90);
    gold.setColorAt(0, tint);
    gold.setColorAt(.22, Qt::white);
    gold.setColorAt(.4, tint.darker(180));
    gold.setColorAt(.7, tint.lighter(130));
    gold.setColorAt(1, tint);
    p.setPen(Qt::NoPen);
    p.setBrush(gold);
    p.drawEllipse(center, radius, radius);
    QRadialGradient body(center - QPointF(4, 4), radius);
    body.setColorAt(0, QColor("#4C4A47"));
    body.setColorAt(1, QColor("#050505"));
    p.setBrush(body);
    p.drawEllipse(center, radius * .76, radius * .76);
    const double angle = (135 + value() * 2.7) * M_PI / 180;
    p.setPen(QPen(tint.lighter(140), 2, Qt::SolidLine, Qt::RoundCap));
    p.drawLine(center + QPointF(std::cos(angle) * 5, std::sin(angle) * 5),
               center + QPointF(std::cos(angle) * 12, std::sin(angle) * 12));
    p.setPen(tint);
    p.setFont(consoleFont("DejaVu Sans", 8, QFont::DemiBold));
    p.drawText(QRectF(0, 34, width(), 10), Qt::AlignCenter, "VOL");
}
void VolumeKnob::mousePressEvent(QMouseEvent *event) {
    if (event->button() == Qt::LeftButton) {
        setFocus(Qt::MouseFocusReason);
        dragOrigin = event->position().toPoint();
        dragValue = value();
        setSliderDown(true);
        event->accept();
    } else
        QSlider::mousePressEvent(event);
}
void VolumeKnob::mouseMoveEvent(QMouseEvent *event) {
    if (isSliderDown()) {
        const auto delta = event->position().toPoint() - dragOrigin;
        setValue(std::clamp(dragValue + (delta.x() - delta.y()) * 100 / 120, 0, 100));
        update();
        event->accept();
    } else
        QSlider::mouseMoveEvent(event);
}
void VolumeKnob::mouseReleaseEvent(QMouseEvent *event) {
    if (event->button() == Qt::LeftButton) {
        setSliderDown(false);
        event->accept();
    } else
        QSlider::mouseReleaseEvent(event);
}
} // namespace Mucke::Console
