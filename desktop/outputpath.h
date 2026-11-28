#pragma once

#include <QDir>
#include <QFileInfo>

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
