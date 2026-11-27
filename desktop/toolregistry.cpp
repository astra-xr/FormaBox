#include "toolregistry.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QTimer>
#include <utility>

ToolRegistry::ToolRegistry(ConfigureProcess configureProcess)
    : m_configureProcess(std::move(configureProcess))
{
    connect(&m_catalogue, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        const auto document = QJsonDocument::fromJson(m_catalogue.readAllStandardOutput());
        const auto diagnostics = QString::fromUtf8(m_catalogue.readAllStandardError()).left(500);
        if (code == 0 && status == QProcess::NormalExit && document.isArray()) {
            m_tools = document.array().toVariantList();
            emit changed();
        } else {
            emit loadFailed(diagnostics);
        }
        schedulePendingReload();
    });
    connect(&m_catalogue, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        emit startFailed(m_catalogue.errorString());
        if (error == QProcess::FailedToStart)
            schedulePendingReload();
    });
}

ToolRegistry::~ToolRegistry()
{
    // QProcess can emit finished while stopping an active child in its destructor.
    m_catalogue.disconnect(this);
}

QVariantMap ToolRegistry::find(const QString &id) const
{
    for (const auto &entry : m_tools) {
        const auto spec = entry.toMap();
        if (spec.value("id").toString() == id)
            return spec;
    }
    return {};
}

void ToolRegistry::reload()
{
    if (m_catalogue.state() != QProcess::NotRunning) {
        m_reloadPending = true;
        return;
    }
    m_configureProcess(m_catalogue);
    m_catalogue.setArguments({"-B", "-m", "formabox", "list", "--check-engines"});
    emit loading();
    m_catalogue.start();
}

void ToolRegistry::schedulePendingReload()
{
    if (std::exchange(m_reloadPending, false))
        QTimer::singleShot(0, this, &ToolRegistry::reload);
}
