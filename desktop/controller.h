#pragma once
#include <QObject>
#include <QUrl>
#include <QProcess>
#include <QVariant>
#include <QQueue>
#include <QHash>
#include <QTemporaryDir>
#include <QJsonObject>
#include <memory>
#include "engineregistry.h"
#include "inspectionrunner.h"
#include "previewservice.h"
#include "taskstore.h"
#include "toolregistry.h"
class Controller final : public QObject {
 Q_OBJECT
 Q_PROPERTY(QVariantList tools READ tools NOTIFY toolsChanged)
 Q_PROPERTY(QVariantList jobs READ jobs NOTIFY jobsChanged)
 Q_PROPERTY(QString status READ status NOTIFY statusChanged)
 Q_PROPERTY(QString historyWarning READ historyWarning NOTIFY historyWarningChanged)
 Q_PROPERTY(bool busy READ busy NOTIFY jobsChanged)
 Q_PROPERTY(QString outputDefault READ outputDefault CONSTANT)
 Q_PROPERTY(bool systemDark READ systemDark NOTIFY systemThemeChanged)
 Q_PROPERTY(bool inspecting READ inspecting NOTIFY inspectionChanged)
 Q_PROPERTY(QVariantList presets READ presets NOTIFY presetsChanged)
 Q_PROPERTY(QStringList favorites READ favorites NOTIFY favoritesChanged)
 Q_PROPERTY(bool hasBundledEngines READ hasBundledEngines CONSTANT)
 Q_PROPERTY(QVariantList engineOptions READ engineOptions CONSTANT)
public:
 explicit Controller(const QString &taskDirectory, QObject *parent=nullptr);
 QVariantList tools() const {return toolRegistry.tools();}
 QVariantList jobs() const {return m_jobs;}
 QString status() const {return m_status;}
 QString historyWarning() const { return m_historyWarning; }
 bool busy() const {return active>=0 || !pending.isEmpty();}
 QString outputDefault() const;
 bool systemDark() const;
 bool inspecting() const { return inspection.busy(); }
 QVariantList presets() const { return m_presets; }
 QStringList favorites() const { return m_favorites; }
 Q_INVOKABLE bool setFavorites(const QStringList &ids);
 Q_INVOKABLE void previewStudio(const QString &tool, const QVariantList &inputs, const QVariantMap &params,
                                const QVariantMap &options);
 Q_INVOKABLE void clearStudioPreview();
 Q_INVOKABLE void playStudioSample(const QUrl &url);
 Q_INVOKABLE void copyText(const QString &text);
 bool hasBundledEngines() const { return engineRegistry.hasBundledEngines(); }
 QVariantList engineOptions() const { return engineRegistry.options(); }
 Q_INVOKABLE QString savePreset(QString name, const QString &tool, const QVariantMap &params,
                                const QVariantList &inputs);
 Q_INVOKABLE QString removePreset(const QString &name);
 Q_INVOKABLE QString saveWorkflowPreset(QString name, const QVariantList &steps, const QVariantList &inputs);
 Q_INVOKABLE QVariantList resultItems(int index) const;
 Q_INVOKABLE QVariantList useResults(int index, const QVariantList &paths) const;
 Q_INVOKABLE bool openResult(int index, const QString &path);
 Q_INVOKABLE QVariantList taskEvents(const QString &taskId);
 Q_INVOKABLE void previewRename(const QVariantList &inputs, const QVariantMap &params);
 Q_INVOKABLE void reload();
 Q_INVOKABLE QString localPath(const QUrl &url) const;
 Q_INVOKABLE QStringList inputSuffixes(const QVariantList &paths) const;
 Q_INVOKABLE QVariantMap enginePaths() const;
 Q_INVOKABLE void checkEngines(const QVariantMap &paths, bool save);
 Q_INVOKABLE void previewPdf(const QVariantList &inputs, int remaining);
 Q_INVOKABLE void clearPdfPreview();
 Q_INVOKABLE void previewPdfCompression(const QVariantList &inputs, const QString &pages, int targetKiB, int page);
 Q_INVOKABLE void clearPdfCompression();
 Q_INVOKABLE QString savePdfCompression(const QString &output);
 Q_INVOKABLE void submit(QString tool,QVariantList inputs,QVariantMap params,QString output);
 Q_INVOKABLE void submitWorkflow(QVariantList steps,QVariantList inputs,QString output);
 Q_INVOKABLE void cancel(int index);
 Q_INVOKABLE void retry(int index);
 Q_INVOKABLE QString readWorkflow(const QUrl &url);
 Q_INVOKABLE bool writeWorkflow(const QUrl &url, const QString &text);
 Q_INVOKABLE void openFolder(QString path);
 Q_INVOKABLE void clearHistory();
signals:
 void toolsChanged(); void jobsChanged(); void statusChanged(); void systemThemeChanged();
 void historyWarningChanged();
 void taskEventsChanged(const QString &taskId);
 void inspectionChanged();
 void presetsChanged();
 void favoritesChanged();
 void studioPreviewReady(QVariantMap preview, QString error);
 void enginesChecked(QVariantMap results, QString message);
 void pdfPreviewReady(QVariantList pages, QString error);
 void pdfCompressionReady(QVariantMap preview, QString error);
 void renamePreviewReady(QVariantList rows, QString plan, QString error);
private:
 struct Request {int index; QJsonObject json;};
 const EngineRegistry engineRegistry;
 ToolRegistry toolRegistry;
 InspectionRunner inspection;
 PreviewService previews;
 TaskStore taskStore;
 QString m_historyWarning;
 QVariantList m_jobs; QString m_status; QProcess worker; QByteArray buffer; QQueue<Request> pending; int active=-1;
 QVariantList m_presets;
 QStringList m_favorites;
 QString storePreset(QString name, QVariantMap preset, const QVariantList &inputs);
 QString presetParameters(const QString &tool, const QVariantMap &params, QVariantMap &values) const;
 QString writePresets(const QVariantList &presets);
 std::unique_ptr<QTemporaryDir> temp;
 QJsonObject activeRequest, outcome;
 QHash<int,QJsonObject> retryRequests;
 QString protocolError;
 QVariantMap candidateEngines;
 bool saveEngines = false;
 void finishEngineCheck(const QJsonValue &result, QString error);
 void finishJob(QVariantMap values);
 bool storeTask(const QVariantMap &row, const QJsonObject &request, bool inFlight);
 void reportHistoryError(const QString &error);
 void enqueue(QJsonObject request, QString title, int existing = -1);
 void update(int index, QVariantMap values, const QJsonObject *request = nullptr, bool inFlight = false);
 void setStatus(QString); void startNext(); void processLine(QByteArray); void finalize(int,QProcess::ExitStatus); void configure(QProcess&, const QVariantMap *overrides = nullptr); void loadHistory();
};
