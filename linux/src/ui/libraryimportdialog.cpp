#include "libraryimportdialog.h"
#include "dialogwidgets_p.h"
#include <QApplication>
#include <QComboBox>
#include <QDialog>
#include <QHeaderView>
#include <QJsonArray>
#include <QLabel>
#include <QStyledItemDelegate>
#include <QStyleOptionComboBox>
#include <QTableWidget>
#include <algorithm>

namespace Mucke {
namespace {
constexpr int ImportChoiceRole = Qt::UserRole + 1;
constexpr int ImportConflictRole = Qt::UserRole + 2;
QString importChoiceCaption(QString key) {
    if (key == "local")
        return germanOrEnglish("Lokal behalten", "Keep local");
    if (key == "both")
        return germanOrEnglish("Beide behalten", "Keep both");
    if (key == "skip")
        return germanOrEnglish("Überspringen", "Skip");
    return germanOrEnglish("Import", "Incoming");
}
class ImportChoiceDelegate final : public QStyledItemDelegate {
  public:
    explicit ImportChoiceDelegate(QObject *parent) : QStyledItemDelegate(parent) {}
    void paint(QPainter *painter, const QStyleOptionViewItem &option,
               const QModelIndex &index) const override {
        QStyleOptionComboBox combo;
        combo.rect =
            QRect(option.rect.left() + 4, option.rect.center().y() - 16, option.rect.width() - 8, 32);
        combo.state = option.state;
        combo.palette = option.palette;
        combo.currentText = index.data().toString();
        combo.subControls = QStyle::SC_All;
        combo.frame = true;
        QStyle *style = option.widget ? option.widget->style() : QApplication::style();
        style->drawComplexControl(QStyle::CC_ComboBox, &combo, painter, option.widget);
        style->drawControl(QStyle::CE_ComboBoxLabel, &combo, painter, option.widget);
    }
    QWidget *createEditor(QWidget *parent, const QStyleOptionViewItem &,
                          const QModelIndex &index) const override {
        auto *combo = new QComboBox(parent);
        combo->setObjectName("importChoice");
        for (const auto &key : {QString("incoming"), QString("local"), QString("both"), QString("skip")}) {
            if (key == "both" && !index.data(ImportConflictRole).toBool())
                continue;
            combo->addItem(importChoiceCaption(key), key);
        }
        return combo;
    }
    void setEditorData(QWidget *editor, const QModelIndex &index) const override {
        auto *combo = qobject_cast<QComboBox *>(editor);
        combo->setCurrentIndex(std::max(0, combo->findData(index.data(ImportChoiceRole))));
    }
    void setModelData(QWidget *editor, QAbstractItemModel *model, const QModelIndex &index) const override {
        auto *combo = qobject_cast<QComboBox *>(editor);
        model->setData(index, combo->currentData(), ImportChoiceRole);
        model->setData(index, combo->currentText(), Qt::DisplayRole);
    }
    void updateEditorGeometry(QWidget *editor, const QStyleOptionViewItem &option,
                              const QModelIndex &) const override {
        editor->setGeometry(
            QRect(option.rect.left() + 4, option.rect.center().y() - 16, option.rect.width() - 8, 32));
    }
};
} // namespace

std::optional<QJsonObject> reviewLibraryImport(QWidget *parent, const QJsonObject &preview) {
    const auto items = preview.value("items").toArray();
    QDialog dialog(parent);
    dialog.setObjectName("importPreview");
    dialog.setWindowTitle(germanOrEnglish("Import prüfen", "Review import"));
    dialog.resize(830, 540);
    auto *layout = new QVBoxLayout(&dialog);
    auto counts = preview["counts"].toObject();
    auto *label = new QLabel(QString("%1 %2 · %3 %4 · %5 %6")
                                 .arg(counts["new"].toInt())
                                 .arg(germanOrEnglish("neu", "new"))
                                 .arg(counts["unchanged"].toInt())
                                 .arg(germanOrEnglish("unverändert", "unchanged"))
                                 .arg(counts["conflict"].toInt())
                                 .arg(germanOrEnglish("Konflikte", "conflicts")));
    layout->addWidget(label);
    auto *table = new QTableWidget(items.size(), 4);
    table->setHorizontalHeaderLabels({germanOrEnglish("Typ / Status", "Type / status"), germanOrEnglish("Lokal", "Local"),
                                      germanOrEnglish("Import", "Incoming"), germanOrEnglish("Übernehmen", "Choice")});
    table->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
    table->setEditTriggers(QAbstractItemView::DoubleClicked | QAbstractItemView::SelectedClicked |
                           QAbstractItemView::EditKeyPressed);
    table->setItemDelegateForColumn(3, new ImportChoiceDelegate(table));
    table->verticalHeader()->setSectionResizeMode(QHeaderView::Fixed);
    table->verticalHeader()->setDefaultSectionSize(100);
    const QHash<QString, QString> kinds = {{"station", germanOrEnglish("Sender", "Station")},
                                           {"group", germanOrEnglish("Gruppe", "Group")},
                                           {"bookmark", germanOrEnglish("Merkeintrag", "Bookmark")}};
    const QHash<QString, QString> states = {{"new", germanOrEnglish("Neu", "New")},
                                            {"unchanged", germanOrEnglish("Unverändert", "Unchanged")},
                                            {"conflict", germanOrEnglish("Konflikt", "Conflict")}};
    for (int i = 0; i < items.size(); ++i) {
        auto item = items[i].toObject();
        table->setItem(
            i, 0,
            new QTableWidgetItem(kinds.value(item["kind"].toString(), item["kind"].toString()) + " / " +
                                 states.value(item["status"].toString(), item["status"].toString())));
        table->setItem(i, 1, new QTableWidgetItem(item["local"].toObject()["text"].toString()));
        table->setItem(i, 2, new QTableWidgetItem(item["incoming"].toObject()["text"].toString()));
        for (int column = 0; column < 3; ++column)
            table->item(i, column)->setToolTip(table->item(i, column)->text());
        for (int column = 0; column < 3; ++column)
            table->item(i, column)->setFlags(table->item(i, column)->flags() & ~Qt::ItemIsEditable);
        const QString key = item["defaultChoice"].toString("incoming");
        auto *choice = new QTableWidgetItem(importChoiceCaption(key));
        choice->setData(ImportChoiceRole, key);
        choice->setData(ImportConflictRole, item["status"].toString() == "conflict");
        table->setItem(i, 3, choice);
    }
    layout->addWidget(table, 1);
    auto *buttons = DialogWidgets::dialogButtons(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    layout->addWidget(buttons);
    QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    if (dialog.exec() != QDialog::Accepted)
        return std::nullopt;

    QJsonObject selected;
    for (int i = 0; i < items.size(); ++i)
        selected[items[i].toObject()["key"].toString()] =
            table->item(i, 3)->data(ImportChoiceRole).toString();
    return selected;
}
} // namespace Mucke
