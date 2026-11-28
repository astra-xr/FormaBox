#include "committedoutput.h"
#include "outputpath.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>

namespace CommittedOutput {
QVariantMap Receipt::recoveredState() const
{
    return {{"state", QStringLiteral("完成")}, {"directory", directory}, {"outputs", files},
            {"progress", 1.0}, {"message", QStringLiteral("已恢复 %1 项已提交的输出").arg(files.size())}};
}

Receipt read(const QVariantMap &task)
{
    const auto id = task.value("taskId").toString();
    const auto rootPath = task.value("commitRoot").toString();
    static const QRegularExpression idPattern("^[a-f0-9]{32}$");
    if (!idPattern.match(id).hasMatch() || !QDir::isAbsolutePath(rootPath))
        return {};

    const QFileInfo root(rootPath);
    const QFileInfo directory(QDir(rootPath).filePath("Omnora-" + id));
    if (root.isSymLink() || root.isJunction() || !directory.isDir() || directory.isJunction() ||
        !isTaskOutput(root, directory))
        return {};
    const QDir output(directory.absoluteFilePath());
    const QFileInfo marker(output.filePath(".omnora-commit.json"));
    if (!marker.isFile() || !isTaskOutput(directory, marker) || marker.size() > 16 * 1024 * 1024)
        return {};
    QFile receipt(marker.absoluteFilePath());
    if (!receipt.open(QIODevice::ReadOnly))
        return {};
    const auto document = QJsonDocument::fromJson(receipt.read(16 * 1024 * 1024 + 1)).object();
    const auto outputs = document.value("outputs").toArray();
    if (document.value("version").toInt() != 1 || document.value("task_id").toString() != id || outputs.isEmpty())
        return {};

    QVariantList files;
    QSet<QString> seen;
    for (const auto &value : outputs) {
        const auto entry = value.toObject();
        const auto relative = entry.value("path").toString();
        if (relative.isEmpty() || QDir::isAbsolutePath(relative) || relative == "." || relative == ".." ||
            relative.startsWith("../") || relative.contains('\\') || relative.contains(':') ||
            relative.contains(QChar::Null) || relative != QDir::cleanPath(relative))
            return {};
        const QFileInfo file(output.filePath(relative));
        const auto folder = entry.value("folder");
        const auto size = entry.value("bytes").toInteger(-2);
        if (!isTaskOutput(directory, file) || file.isJunction() || file == marker || !folder.isBool() ||
            folder.toBool() != file.isDir() || size != (file.isDir() ? -1 : file.size()))
            return {};
        const auto canonical = file.canonicalFilePath();
        if (seen.contains(canonical))
            return {};
        seen.insert(canonical);
        files.append(taskOutputRow(file, entry.value("details").toObject().toVariantMap()));
    }
    return {marker.absoluteFilePath(), directory.absoluteFilePath(), files};
}

void acknowledge(const QVariantMap &task)
{
    if (task.value("state").toString() != QStringLiteral("完成"))
        return;
    const auto receipt = read(task);
    if (receipt && QFileInfo(receipt.directory) == QFileInfo(task.value("directory").toString()))
        QFile::remove(receipt.path);
}
}
