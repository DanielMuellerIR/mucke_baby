#pragma once

#include "../i18n.h"
#include <QBoxLayout>
#include <QDialogButtonBox>
#include <QPushButton>
#include <functional>

namespace Mucke::DialogWidgets {
inline QPushButton *button(QString label, QBoxLayout *layout, const std::function<void()> &action) {
    auto *b = new QPushButton(label);
    b->setMinimumHeight(32);
    layout->addWidget(b);
    QObject::connect(b, &QPushButton::clicked, b, action);
    return b;
}
inline QDialogButtonBox *dialogButtons(QDialogButtonBox::StandardButtons buttons) {
    auto *box = new QDialogButtonBox(buttons);
    const QList<QPair<QDialogButtonBox::StandardButton, QString>> captions = {
        {QDialogButtonBox::Save, germanOrEnglish("Speichern", "Save")},
        {QDialogButtonBox::Cancel, germanOrEnglish("Abbrechen", "Cancel")},
        {QDialogButtonBox::Close, germanOrEnglish("Schließen", "Close")},
        {QDialogButtonBox::Ok, QString("OK")}};
    for (const auto &caption : captions)
        if (auto *button = box->button(caption.first))
            button->setText(caption.second);
    return box;
}
} // namespace Mucke::DialogWidgets
