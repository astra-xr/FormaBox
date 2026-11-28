#include "taskstore.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <algorithm>
#include <utility>

namespace {
QString lockPath(const QDir &directory, const QString &session)
{
    return directory.filePath("session-" + session + ".lock");
}

bool collectPasswords(const QJsonValue &value, QStringList &secrets)
{
    bool protectedRequest = false;
    if (value.isArray()) {
        for (const auto &item : value.toArray())
            protectedRequest |= collectPasswords(item, secrets);
    } else if (value.isObject()) {
        const auto object = value.toObject();
        for (auto it = object.constBegin(); it != object.constEnd(); ++it) {
            if (it.key().compare("password", Qt::CaseInsensitive) == 0) {
                protectedRequest = true;
                const auto secret = it.value().toVariant().toString();
                if (!secret.isEmpty())
                    secrets.append(secret);
            } else {
                protectedRequest |= collectPasswords(it.value(), secrets);
            }
        }
    }
    return protectedRequest;
}

QString redact(QString text, const QStringList &secrets)
{
    for (const auto &secret : secrets)
        text.replace(secret, QStringLiteral("[已隐藏]"));
    return text;
}

QByteArray snapshot(QVariantMap fields, const QStringList &secrets = {})
{
    fields.remove("canRetry");
    fields.remove("canResume");
    if (!secrets.isEmpty()) {
        for (const auto *key : {"title", "message", "directory"}) {
            if (fields.contains(key))
                fields[key] = redact(fields.value(key).toString(), secrets);
        }
        auto outputs = fields.value("outputs").toList();
        for (auto &value : outputs) {
            auto output = value.toMap();
            for (const auto *key : {"name", "path"})
                output[key] = redact(output.value(key).toString(), secrets);
            value = output;
        }
        if (fields.contains("outputs"))
            fields["outputs"] = outputs;
    }
    return QJsonDocument::fromVariant(fields).toJson(QJsonDocument::Compact);
}
}

QString TaskStore::newId()
{
    return QUuid::createUuid().toString(QUuid::Id128);
}

TaskStore::TaskStore(const QString &directory)
    : m_directory(directory), m_session(newId()), m_lock(lockPath(m_directory, m_session))
{
    if (directory.isEmpty() || !QDir().mkpath(directory)) {
        fail(QStringLiteral("无法创建任务数据目录"));
        return;
    }
    m_lock.setStaleLockTime(0);
    if (!m_lock.tryLock(0)) {
        fail(QStringLiteral("无法登记任务会话"));
        return;
    }
    m_database = QSqlDatabase::addDatabase("QSQLITE", m_session);
    m_database.setConnectOptions("QSQLITE_BUSY_TIMEOUT=2000");
    m_database.setDatabaseName(m_directory.filePath("tasks.sqlite"));
    if (!m_database.open()) {
        fail(m_database.lastError().text());
        return;
    }

    QSqlQuery query(m_database);
    if (!query.exec("PRAGMA user_version") || !query.next()) {
        fail(query.lastError().text());
        return;
    }
    const auto version = query.value(0).toInt();
    query.finish();
    if (version > 1) {
        fail(QStringLiteral("任务数据库版本高于当前程序支持的版本"));
        return;
    }
    if (!query.exec("CREATE TABLE IF NOT EXISTS tasks (sequence INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, "
                    "owner TEXT, snapshot BLOB NOT NULL, request BLOB)") ||
        !query.exec("CREATE TABLE IF NOT EXISTS task_meta (key TEXT PRIMARY KEY)") ||
        (version == 0 && !query.exec("PRAGMA user_version=1"))) {
        fail(query.lastError().text());
        return;
    }
    m_ready = true;
}

TaskStore::~TaskStore()
{
    const auto connection = m_database.connectionName();
    m_database.close();
    m_database = QSqlDatabase();
    if (!connection.isEmpty())
        QSqlDatabase::removeDatabase(connection);
}

bool TaskStore::fail(QString error)
{
    m_error = error.isEmpty() ? QStringLiteral("任务数据库不可用") : std::move(error);
    return false;
}

bool TaskStore::hasPassword(const QJsonObject &request)
{
    QStringList secrets;
    return collectPasswords(request, secrets);
}

bool TaskStore::migrate(const QList<Record> &records)
{
    if (!available())
        return false;
    if (!m_database.transaction())
        return fail(m_database.lastError().text());
    QSqlQuery marker(m_database);
    if (!marker.exec("INSERT OR IGNORE INTO task_meta(key) VALUES('qsettings-history')")) {
        m_database.rollback();
        return fail(marker.lastError().text());
    }
    if (marker.numRowsAffected() == 1) {
        for (const auto &record : records) {
            if (!save(record, false)) {
                m_database.rollback();
                return false;
            }
        }
    }
    if (!m_database.commit()) {
        const auto error = m_database.lastError().text();
        m_database.rollback();
        return fail(error);
    }
    return true;
}

bool TaskStore::save(const Record &record, bool inFlight)
{
    if (!available())
        return false;
    QStringList secrets;
    const bool protectedRequest = collectPasswords(record.request, secrets);
    std::sort(secrets.begin(), secrets.end(), [](const auto &a, const auto &b) { return a.size() > b.size(); });
    auto request = record.request;
    request.remove("cancel");
    const bool retainRequest = !protectedRequest && !request.isEmpty() &&
                               (inFlight || record.view.value("canRetry").toBool());
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO tasks(id, owner, snapshot, request) VALUES(?, ?, ?, ?) "
                  "ON CONFLICT(id) DO UPDATE SET owner=excluded.owner, snapshot=excluded.snapshot, request=excluded.request "
                  "WHERE tasks.owner=? OR (tasks.owner IS NULL AND tasks.request IS NOT NULL)");
    query.addBindValue(record.view.value("taskId"));
    query.addBindValue(inFlight ? QVariant(m_session) : QVariant());
    query.addBindValue(snapshot(record.view, secrets));
    query.addBindValue(retainRequest ? QVariant(QJsonDocument(request).toJson(QJsonDocument::Compact)) : QVariant());
    query.addBindValue(m_session);
    if (!query.exec())
        return fail(query.lastError().text());
    if (query.numRowsAffected() != 1)
        return fail(QStringLiteral("任务正在另一个万象窗口运行或已处理"));
    return inFlight || prune();
}

bool TaskStore::prune()
{
    QSqlQuery query(m_database);
    return query.exec("DELETE FROM tasks WHERE owner IS NULL AND sequence NOT IN "
                      "(SELECT sequence FROM tasks WHERE owner IS NULL ORDER BY sequence DESC LIMIT 100)") ||
           fail(query.lastError().text());
}

QList<TaskStore::Record> TaskStore::load()
{
    struct Row { Record record; QString owner; };
    QList<Row> rows;
    QSqlQuery query(m_database);
    if (!available() || !query.exec("SELECT id, owner, snapshot, request FROM tasks ORDER BY sequence")) {
        if (available())
            fail(query.lastError().text());
        return {};
    }
    while (query.next()) {
        auto view = QJsonDocument::fromJson(query.value(2).toByteArray()).object().toVariantMap();
        if (view.isEmpty())
            continue;
        view["taskId"] = query.value(0).toString();
        rows.append({{view, QJsonDocument::fromJson(query.value(3).toByteArray()).object()}, query.value(1).toString()});
    }
    query.finish();

    static const QRegularExpression ownerId("^[a-f0-9]{32}$");
    QList<Record> history;
    for (auto &row : rows) {
        if (!row.owner.isEmpty()) {
            if (row.owner == m_session || !ownerId.match(row.owner).hasMatch())
                continue;
            QLockFile previous(lockPath(m_directory, row.owner));
            previous.setStaleLockTime(0);
            if (!previous.tryLock(0))
                continue;
            row.record.view["state"] = QStringLiteral("已中断");
            row.record.view["progress"] = 0.0;
            row.record.view["message"] = row.record.request.isEmpty()
                ? QStringLiteral("上次运行中断，请重新提交此任务")
                : QStringLiteral("上次运行中断，可手动再次处理");
            row.record.view["errorCode"] = "interrupted";
            query.prepare("UPDATE tasks SET owner=NULL, snapshot=? WHERE id=? AND owner=?");
            query.addBindValue(snapshot(row.record.view));
            query.addBindValue(row.record.view.value("taskId"));
            query.addBindValue(row.owner);
            if (!query.exec()) {
                fail(query.lastError().text());
                continue;
            }
            if (query.numRowsAffected() != 1)
                continue;
        }
        history.append(std::move(row.record));
    }
    prune();
    while (history.size() > 100)
        history.removeFirst();
    return history;
}

bool TaskStore::clearHistory()
{
    if (!available())
        return false;
    QSqlQuery query(m_database);
    return query.exec("DELETE FROM tasks WHERE owner IS NULL") || fail(query.lastError().text());
}
