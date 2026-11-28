#pragma once

#include <QProcessEnvironment>
#include <QVariant>

class EngineRegistry final {
public:
    explicit EngineRegistry(const QString &applicationDirectory);

    bool hasBundledEngines() const { return m_hasBundledEngines; }
    QVariantList options() const;
    QVariantMap savedPaths() const;
    void configure(QProcessEnvironment &environment, const QVariantMap *candidates = nullptr) const;
    QString validate(const QVariantMap &paths, QVariantMap &candidates) const;
    QString saveTested(const QVariantMap &candidates, const QVariantMap &checks) const;

private:
    QString m_engineDirectory;
    QVariantMap m_bundledPaths;
    bool m_hasBundledEngines = true;
};
