#pragma once

#include <QObject>
#include <QProcess>
#include <QVariant>
#include <functional>

class ToolRegistry final : public QObject {
    Q_OBJECT

public:
    using ConfigureProcess = std::function<void(QProcess &)>;

    explicit ToolRegistry(ConfigureProcess configureProcess);
    ~ToolRegistry() override;

    const QVariantList &tools() const { return m_tools; }
    QVariantMap find(const QString &id) const;
    void reload();

signals:
    void loading();
    void changed();
    void loadFailed(const QString &details);
    void startFailed(const QString &details);

private:
    void schedulePendingReload();

    const ConfigureProcess m_configureProcess;
    QProcess m_catalogue;
    QVariantList m_tools;
    bool m_reloadPending = false;
};
