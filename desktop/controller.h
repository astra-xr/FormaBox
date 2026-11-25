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
class Controller final : public QObject {
 Q_OBJECT
 Q_PROPERTY(QVariantList tools READ tools NOTIFY toolsChanged)
 Q_PROPERTY(QVariantList jobs READ jobs NOTIFY jobsChanged)
 Q_PROPERTY(QString status READ status NOTIFY statusChanged)
 Q_PROPERTY(bool busy READ busy NOTIFY jobsChanged)
 Q_PROPERTY(QString outputDefault READ outputDefault CONSTANT)
 Q_PROPERTY(bool systemDark READ systemDark NOTIFY systemThemeChanged)
public:
 explicit Controller(QObject *parent=nullptr);
 QVariantList tools() const {return m_tools;}
 QVariantList jobs() const {return m_jobs;}
 QString status() const {return m_status;}
 bool busy() const {return active>=0 || !pending.isEmpty();}
 QString outputDefault() const;
 bool systemDark() const;
 Q_INVOKABLE void reload();
 Q_INVOKABLE QString localPath(const QUrl &url) const;
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
private:
 struct Request {int index; QJsonObject json;};
 QVariantList m_tools,m_jobs; QString m_status; QProcess catalogue,worker; QByteArray buffer; QQueue<Request> pending; int active=-1;
 std::unique_ptr<QTemporaryDir> temp;
 QJsonObject activeRequest, outcome;
 QHash<int,QJsonObject> retryRequests;
 bool protocolError=false;
 void finishJob(QVariantMap values);
 void setStatus(QString); void startNext(); void enqueue(QJsonObject,QString); void update(int,QVariantMap); void processLine(QByteArray); void finalize(int,QProcess::ExitStatus); void configure(QProcess&); void loadHistory(); void saveHistory();
};
