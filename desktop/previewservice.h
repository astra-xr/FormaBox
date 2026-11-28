#pragma once

#include <QObject>
#include <QTemporaryDir>
#include <QUrl>
#include <QVariant>
#include <memory>

class InspectionRunner;
class QJsonObject;
class QJsonValue;

class PreviewService final : public QObject {
    Q_OBJECT

public:
    struct SavedPdf {
        QString error;
        QString path;
        QVariantMap details;
    };

    explicit PreviewService(InspectionRunner &inspection);
    ~PreviewService() override;

    void previewPdf(const QVariantList &inputs, int remaining);
    void previewPdfCompression(const QVariantList &inputs, const QString &pages, int targetKiB, int page);
    void previewRename(const QVariantList &inputs, const QVariantMap &params);
    void previewStudio(const QString &tool, const QVariantList &inputs, const QVariantMap &params,
                       const QVariantMap &options);
    void clearPdfPreview();
    void clearPdfCompression();
    void clearStudioPreview();
    void playStudioSample(const QUrl &url) const;
    SavedPdf savePdfCompression(const QString &output) const;

signals:
    void pdfPreviewReady(QVariantList pages, QString error);
    void pdfCompressionReady(QVariantMap preview, QString error);
    void renamePreviewReady(QVariantList rows, QString plan, QString error);
    void studioPreviewReady(QVariantMap preview, QString error);

private:
    bool makeBatch(std::unique_ptr<QTemporaryDir> &root);
    void finish(const QString &command, const QJsonObject &request, const QJsonValue &result, const QString &error);
    void finishPdf(const QJsonObject &request, const QJsonValue &result, QString error);
    void finishCompression(const QJsonValue &result, QString error);
    void finishStudio(const QJsonValue &result, QString error);

    InspectionRunner &m_inspection;
    std::unique_ptr<QTemporaryDir> m_pdfRoot;
    std::unique_ptr<QTemporaryDir> m_studioRoot;
    std::unique_ptr<QTemporaryDir> m_batch;
    std::unique_ptr<QTemporaryDir> m_compression;
    QVariantMap m_compressionDetails;
    qint64 m_compressionSize = 0;
    bool m_discardPending = false;
};
