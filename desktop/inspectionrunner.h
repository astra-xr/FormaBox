#pragma once

#include <QJsonObject>
#include "workerprocess.h"
#include <QTimer>
#include <QVariant>
#include <functional>

class InspectionRunner final : public QObject {
    Q_OBJECT

public:
    using ConfigureProcess = std::function<void(QProcess &, const QVariantMap *)>;

    explicit InspectionRunner(ConfigureProcess configureProcess);
    ~InspectionRunner() override;

    bool busy() const { return !m_command.isEmpty(); }
    const QString &command() const { return m_command; }
    void start(const QString &command, int timeout, const QJsonObject &request = {},
               const QVariantMap *overrides = nullptr);
    void stop();

signals:
    void busyChanged();
    void finished(const QString &command, const QJsonObject &request, const QJsonValue &result, const QString &error);

private:
    void finish(int code, QProcess::ExitStatus status);

    const ConfigureProcess m_configureProcess;
    WorkerProcess m_process;
    QTimer m_timeout;
    QString m_command;
    QJsonObject m_request;
    bool m_timedOut = false;
};
