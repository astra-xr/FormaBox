#pragma once

#include <QVariant>

namespace CommittedOutput {
struct Receipt {
    QString path;
    QString directory;
    QVariantList files;

    explicit operator bool() const { return !path.isEmpty(); }
    QVariantMap recoveredState() const;
};

Receipt read(const QVariantMap &task);
void acknowledge(const QVariantMap &task);
}
