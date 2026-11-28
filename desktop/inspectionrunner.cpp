#include "inspectionrunner.h"

#include <QJsonDocument>
#include <utility>

InspectionRunner::InspectionRunner(ConfigureProcess configureProcess)
    : m_configureProcess(std::move(configureProcess))
{
    m_timeout.setSingleShot(true);
    connect(&m_timeout, &QTimer::timeout, this, [this] {
        m_timedOut = true;
        m_process.kill();
    });
    connect(&m_process, &QProcess::started, this, [this] {
        if (!m_request.isEmpty())
            m_process.write(QJsonDocument(m_request).toJson(QJsonDocument::Compact));
        m_process.closeWriteChannel();
    });
    connect(&m_process, &QProcess::finished, this, &InspectionRunner::finish);
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            finish(-1, QProcess::CrashExit);
    });
}

InspectionRunner::~InspectionRunner()
{
    m_process.disconnect(this);
    stop();
}

void InspectionRunner::stop()
{
    m_timeout.stop();
    m_command.clear();
    m_request = {};
    if (m_process.state() != QProcess::NotRunning) {
        m_process.kill();
        m_process.waitForFinished();
    }
}

void InspectionRunner::start(const QString &command, int timeout, const QJsonObject &request,
                             const QVariantMap *overrides)
{
    if (busy())
        return;
    m_command = command;
    m_request = request;
    m_timedOut = false;
    m_configureProcess(m_process, overrides);
    m_process.setArguments({"-B", "-m", "formabox", command});
    emit busyChanged();
    m_timeout.start(timeout);
    m_process.start();
}

void InspectionRunner::finish(int code, QProcess::ExitStatus status)
{
    if (!busy())
        return;
    m_timeout.stop();
    const auto reply = QJsonDocument::fromJson(m_process.readAllStandardOutput()).object();
    const auto diagnostics = QString::fromUtf8(m_process.readAllStandardError()).trimmed();
    const auto result = reply.value("result");
    auto error = reply.value("error").toString();
    if (m_timedOut)
        error = QStringLiteral("操作超时");
    else if (status != QProcess::NormalExit || (error.isEmpty() && (code != 0 || result.isUndefined())))
        error = diagnostics.isEmpty() ? QStringLiteral("无法运行工作进程") : diagnostics.left(500);

    const auto command = std::exchange(m_command, {});
    const auto request = std::exchange(m_request, {});
    emit finished(command, request, result, error);
    if (!busy())
        emit busyChanged();
}
