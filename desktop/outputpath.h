#pragma once

#include <QDir>
#include <QFileInfo>
#include <QVariant>

inline bool isTaskOutput(const QFileInfo &directory, const QFileInfo &file)
{
    if (!directory.isDir() || !directory.isAbsolute() || !file.isAbsolute() || file.isSymLink() ||
        !(file.isFile() || file.isDir()))
        return false;
    const auto root = directory.canonicalFilePath();
    const auto path = file.canonicalFilePath();
    if (root.isEmpty() || path.isEmpty() || path == root)
        return false;
    const auto relative = QDir(root).relativeFilePath(path);
    return relative != ".." && !relative.startsWith("../") && !QDir::isAbsolutePath(relative);
}

inline QVariantMap taskOutputRow(const QFileInfo &file, const QVariantMap &details = {})
{
    QVariantMap row{{"path", file.filePath()}, {"name", file.fileName()},
                    {"bytes", file.isDir() ? -1LL : file.size()}, {"folder", file.isDir()}};
    for (const auto *key : {"original_bytes", "target_bytes"}) {
        bool valid = false;
        const auto size = details.value(key).toLongLong(&valid);
        if (valid && size >= 0)
            row.insert(key, size);
    }
    return row;
}
