#pragma once

#include <QDir>
#include <QJsonObject>
#include <QLockFile>
#include <QSqlDatabase>
#include <QVariant>

class TaskStore final {
public:
    struct Record {
        QVariantMap view;
        QJsonObject request;
    };

    explicit TaskStore(const QString &directory);
    ~TaskStore();
    TaskStore(const TaskStore &) = delete;
    TaskStore &operator=(const TaskStore &) = delete;

    static QString newId();
    static bool hasPassword(const QJsonObject &request);

    bool available() const { return m_ready; }
    QString error() const { return m_error; }
    bool migrate(const QList<Record> &records);
    QList<Record> load();
    QVariantList events(const QString &taskId);
    bool save(const Record &record, bool inFlight);
    bool clearHistory();

private:
    bool write(const Record &record, bool inFlight, bool imported = false);
    bool addEvent(const QVariantMap &view, bool imported, bool inFlight);
    bool importSnapshots();
    bool importArtifacts();
    bool writeArtifacts(const QVariantMap &view);
    QVariantList readArtifacts(const QString &taskId);
    bool commit();
    bool prune();
    bool fail(QString error);

    QDir m_directory;
    const QString m_session;
    QLockFile m_lock;
    QSqlDatabase m_database;
    QString m_error;
    bool m_ready = false;
};
