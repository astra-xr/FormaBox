#include "previewservice.h"
#include "inspectionrunner.h"
#include "outputpath.h"

#include <QDesktopServices>
#include <QFile>
#include <QJsonArray>
#include <QSaveFile>
#include <utility>

namespace {
QUrl previewFile(const QTemporaryDir &directory, const QString &name)
{
    if (name.isEmpty() || QFileInfo(name).fileName() != name)
        return {};
    const QFileInfo file(directory.filePath(name));
    if (!file.isFile() || !isTaskOutput(QFileInfo(directory.path()), file))
        return {};
    return QUrl::fromLocalFile(file.filePath());
}
}

PreviewService::PreviewService(InspectionRunner &inspection) : m_inspection(inspection)
{
    connect(&m_inspection, &InspectionRunner::finished, this, &PreviewService::finish);
}

PreviewService::~PreviewService()
{
    if (m_inspection.command().startsWith("preview-"))
        m_inspection.stop();
}

bool PreviewService::makeBatch(std::unique_ptr<QTemporaryDir> &root)
{
    if (!root)
        root = std::make_unique<QTemporaryDir>();
    if (!root->isValid()) {
        root.reset();
        return false;
    }
    auto batch = std::make_unique<QTemporaryDir>(root->filePath("preview-XXXXXX"));
    if (!batch->isValid())
        return false;
    m_batch = std::move(batch);
    return true;
}

void PreviewService::previewPdf(const QVariantList &inputs, int remaining)
{
    if (m_inspection.busy())
        return;
    if (!makeBatch(m_pdfRoot)) {
        emit pdfPreviewReady({}, QStringLiteral("无法创建预览目录"));
        return;
    }
    m_inspection.start("preview-pdf", 60000, QJsonObject::fromVariantMap(
        {{"inputs", inputs}, {"limit", remaining}, {"output", m_batch->path()}}));
}

void PreviewService::previewPdfCompression(const QVariantList &inputs, const QString &pages, int targetKiB, int page)
{
    if (m_inspection.busy())
        return;
    clearPdfCompression();
    m_compression = std::make_unique<QTemporaryDir>();
    if (!m_compression->isValid()) {
        m_compression.reset();
        emit pdfCompressionReady({}, QStringLiteral("无法创建压缩预览目录"));
        return;
    }
    m_inspection.start("preview-pdf-compression", 180000, QJsonObject::fromVariantMap(
        {{"inputs", inputs}, {"pages", pages}, {"output", m_compression->path()},
         {"target_kib", targetKiB}, {"page", page}}));
}

void PreviewService::previewRename(const QVariantList &inputs, const QVariantMap &params)
{
    m_inspection.start("preview-rename", 60000, QJsonObject::fromVariantMap({{"inputs", inputs}, {"params", params}}));
}

void PreviewService::previewStudio(const QString &tool, const QVariantList &inputs, const QVariantMap &params,
                                   const QVariantMap &options)
{
    if (m_inspection.busy())
        return;
    if (!makeBatch(m_studioRoot)) {
        emit studioPreviewReady({}, QStringLiteral("无法创建预览目录"));
        return;
    }
    auto request = options;
    request.insert("tool", tool);
    request.insert("inputs", inputs);
    request.insert("params", params);
    request.insert("output", m_batch->path());
    m_inspection.start("preview-tool", 180000, QJsonObject::fromVariantMap(request));
}

void PreviewService::clearPdfPreview()
{
    if (m_inspection.command() == "preview-pdf")
        m_discardPending = true;
    else
        m_pdfRoot.reset();
}

void PreviewService::clearPdfCompression()
{
    if (m_inspection.command() == "preview-pdf-compression") {
        m_discardPending = true;
        return;
    }
    m_compression.reset();
    m_compressionDetails.clear();
    m_compressionSize = 0;
}

void PreviewService::clearStudioPreview()
{
    if (m_inspection.command() == "preview-tool")
        m_discardPending = true;
    else
        m_studioRoot.reset();
}

void PreviewService::playStudioSample(const QUrl &url) const
{
    const QFileInfo file(url.toLocalFile());
    if (m_studioRoot && file.suffix() == "wav" && file.isFile() &&
        isTaskOutput(QFileInfo(m_studioRoot->path()), file))
        QDesktopServices::openUrl(url);
}

PreviewService::SavedPdf PreviewService::savePdfCompression(const QString &output) const
{
    if (!m_compression || m_inspection.busy())
        return {QStringLiteral("请先生成压缩预览"), {}, {}};
    const auto directory = QDir::cleanPath(output.trimmed());
    if (!QDir::isAbsolutePath(directory) || !QDir().mkpath(directory))
        return {QStringLiteral("无法创建输出目录"), {}, {}};
    QFile preview(previewFile(*m_compression, "compressed.pdf").toLocalFile());
    if (!preview.open(QIODevice::ReadOnly) || m_compressionSize <= 0 || preview.size() != m_compressionSize)
        return {QStringLiteral("压缩预览已失效"), {}, {}};

    QTemporaryDir result(QDir(directory).filePath("Omnora-XXXXXX"));
    if (!result.isValid())
        return {QStringLiteral("无法创建任务目录"), {}, {}};
    const auto path = result.filePath("workbench.pdf");
    QSaveFile destination(path);
    if (!destination.open(QIODevice::WriteOnly))
        return {QStringLiteral("无法保存 PDF：") + destination.errorString(), {}, {}};
    qint64 remaining = m_compressionSize;
    while (remaining > 0) {
        const auto bytes = preview.read(qMin<qint64>(remaining, 1024 * 1024));
        if (bytes.isEmpty() || destination.write(bytes) != bytes.size())
            return {QStringLiteral("无法写入 PDF"), {}, {}};
        remaining -= bytes.size();
    }
    if (!preview.atEnd() || !destination.commit())
        return {QStringLiteral("无法保存 PDF：") + destination.errorString(), {}, {}};
    result.setAutoRemove(false);
    return {{}, path, m_compressionDetails};
}

void PreviewService::finish(const QString &command, const QJsonObject &request, const QJsonValue &result,
                            const QString &error)
{
    if (command == "preview-pdf") {
        finishPdf(request, result, error);
    } else if (command == "preview-pdf-compression") {
        finishCompression(result, error);
    } else if (command == "preview-tool") {
        finishStudio(result, error);
    } else if (command == "preview-rename") {
        const auto details = result.toObject().toVariantMap();
        const auto rows = details.value("rows").toList();
        const auto plan = details.value("plan").toString();
        const auto message = error.isEmpty() && (rows.isEmpty() || plan.size() != 64)
                                 ? QStringLiteral("改名预览结果无效") : error;
        emit renamePreviewReady(rows, plan, message);
    }
}

void PreviewService::finishPdf(const QJsonObject &request, const QJsonValue &result, QString error)
{
    const bool discard = std::exchange(m_discardPending, false);
    if (discard)
        error = QStringLiteral("预览已清除");
    QVariantList pages;
    if (error.isEmpty()) {
        const auto inputs = request.value("inputs").toArray();
        for (const auto &value : result.toArray()) {
            const auto row = value.toObject();
            const auto source = row.value("source").toInt(-1);
            const auto page = row.value("page").toInt(-1);
            const auto name = row.value("thumbnail").toString();
            const auto thumbnail = previewFile(*m_batch, name);
            if (source < 0 || source >= inputs.size() || page < 0 || !name.endsWith(".png") || thumbnail.isEmpty()) {
                error = QStringLiteral("预览结果无效");
                break;
            }
            const auto path = inputs.at(source).toString();
            pages.append(QVariantMap{{"path", path}, {"name", QFileInfo(path).fileName()}, {"page", page},
                                     {"thumbnail", thumbnail}, {"rotation", 0}});
        }
        if (pages.isEmpty() && error.isEmpty())
            error = QStringLiteral("文件没有可用页面");
    }
    if (error.isEmpty())
        m_batch->setAutoRemove(false);
    else
        pages.clear();
    m_batch.reset();
    if (discard)
        m_pdfRoot.reset();
    emit pdfPreviewReady(pages, error);
}

void PreviewService::finishCompression(const QJsonValue &result, QString error)
{
    if (std::exchange(m_discardPending, false))
        error = QStringLiteral("预览已清除");
    auto details = result.toObject().toVariantMap();
    if (error.isEmpty()) {
        const auto candidate = previewFile(*m_compression, "compressed.pdf");
        const auto before = previewFile(*m_compression, "before.png");
        const auto after = previewFile(*m_compression, "after.png");
        const auto size = details.value("size").toLongLong();
        if (candidate.isEmpty() || before.isEmpty() || after.isEmpty() || size <= 0 ||
            size != QFileInfo(candidate.toLocalFile()).size() || !details.contains("met")) {
            error = QStringLiteral("压缩结果无效");
        } else {
            details.insert("before", before);
            details.insert("after", after);
            m_compressionDetails = {{"original_bytes", details.value("original")}, {"target_bytes", details.value("target")}};
            m_compressionSize = size;
        }
    }
    if (!error.isEmpty()) {
        clearPdfCompression();
        details.clear();
    }
    emit pdfCompressionReady(details, error);
}

void PreviewService::finishStudio(const QJsonValue &result, QString error)
{
    const bool discard = std::exchange(m_discardPending, false);
    if (discard)
        error = QStringLiteral("预览已清除");
    auto details = result.toObject().toVariantMap();
    if (error.isEmpty() && !result.isObject())
        error = QStringLiteral("预览结果无效");
    if (error.isEmpty()) {
        const auto resolve = [&](const QVariant &name) {
            const auto path = previewFile(*m_batch, name.toString());
            if (path.isEmpty())
                error = QStringLiteral("预览文件无效");
            return path;
        };
        for (const auto *key : {"image", "sample"})
            if (details.contains(key))
                details[key] = resolve(details.value(key));
        if (details.contains("pictures")) {
            QVariantList pictures;
            for (const auto &file : details.value("pictures").toList())
                pictures.append(resolve(file));
            details["pictures"] = pictures;
        }
        if (details.contains("rows")) {
            QVariantList rows;
            for (const auto &value : details.value("rows").toList()) {
                auto row = value.toMap();
                if (row.contains("thumbnail"))
                    row["thumbnail"] = resolve(row.value("thumbnail"));
                rows.append(row);
            }
            details["rows"] = rows;
        }
    }
    if (error.isEmpty())
        m_batch->setAutoRemove(false);
    else
        details.clear();
    m_batch.reset();
    if (discard)
        m_studioRoot.reset();
    emit studioPreviewReady(details, error);
}
