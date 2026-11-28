#include "taskstore.h"
#include "committedoutput.h"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <algorithm>
#include <memory>
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

QByteArray encodeSnapshot(QVariantMap fields)
{
    fields.remove("outputs");
    return QJsonDocument::fromVariant(fields).toJson(QJsonDocument::Compact);
}

QVariantMap snapshot(QVariantMap fields, const QStringList &secrets = {})
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
    return fields;
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
    if (version > 3) {
        fail(QStringLiteral("任务数据库版本高于当前程序支持的版本"));
        return;
    }
    if (!query.exec("PRAGMA foreign_keys=ON") || !m_database.transaction()) {
        fail(query.lastError().isValid() ? query.lastError().text() : m_database.lastError().text());
        return;
    }
    if (!query.exec("CREATE TABLE IF NOT EXISTS tasks (sequence INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, "
                    "owner TEXT, snapshot BLOB NOT NULL, request BLOB)") ||
        !query.exec("CREATE TABLE IF NOT EXISTS task_meta (key TEXT PRIMARY KEY)") ||
        !query.exec("CREATE TABLE IF NOT EXISTS task_events (sequence INTEGER PRIMARY KEY, "
                    "task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, attempt INTEGER NOT NULL, "
                    "state TEXT NOT NULL, occurred_at INTEGER, message TEXT, error_code TEXT)") ||
        !query.exec("CREATE INDEX IF NOT EXISTS task_events_by_task ON task_events(task_id, sequence)") ||
        !query.exec("CREATE TABLE IF NOT EXISTS task_artifacts (completion INTEGER NOT NULL "
                    "REFERENCES task_events(sequence) ON DELETE CASCADE, position INTEGER NOT NULL, "
                    "metadata BLOB NOT NULL, PRIMARY KEY(completion, position))")) {
        fail(query.lastError().text());
        m_database.rollback();
        return;
    }
    if ((version < 2 && !importSnapshots()) || (version < 3 && !importArtifacts())) {
        m_database.rollback();
        return;
    }
    if (version < 3 && !query.exec("PRAGMA user_version=3")) {
        fail(query.lastError().text());
        m_database.rollback();
        return;
    }
    m_ready = commit();
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

bool TaskStore::commit()
{
    if (m_database.commit())
        return true;
    const auto error = m_database.lastError().text();
    m_database.rollback();
    return fail(error);
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
            if (!write(record, false, true)) {
                m_database.rollback();
                return false;
            }
        }
    }
    if (!prune()) {
        m_database.rollback();
        return false;
    }
    return commit();
}

bool TaskStore::save(const Record &record, bool inFlight)
{
    if (!available())
        return false;
    if (!m_database.transaction())
        return fail(m_database.lastError().text());
    if (!write(record, inFlight) || (!inFlight && !prune())) {
        m_database.rollback();
        return false;
    }
    if (!commit())
        return false;
    if (!inFlight)
        CommittedOutput::acknowledge(record.view);
    return true;
}

bool TaskStore::write(const Record &record, bool inFlight, bool imported)
{
    QStringList secrets;
    const bool protectedRequest = collectPasswords(record.request, secrets);
    std::sort(secrets.begin(), secrets.end(), [](const auto &a, const auto &b) { return a.size() > b.size(); });
    auto request = record.request;
    request.remove("cancel");
    const bool retainRequest = !protectedRequest && !request.isEmpty() &&
                               (inFlight || record.view.value("canRetry").toBool());
    const auto view = snapshot(record.view, secrets);
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO tasks(id, owner, snapshot, request) VALUES(?, ?, ?, ?) "
                  "ON CONFLICT(id) DO UPDATE SET owner=excluded.owner, snapshot=excluded.snapshot, request=excluded.request "
                  "WHERE tasks.owner=? OR (tasks.owner IS NULL AND tasks.request IS NOT NULL)");
    query.addBindValue(record.view.value("taskId"));
    query.addBindValue(inFlight ? QVariant(m_session) : QVariant());
    query.addBindValue(encodeSnapshot(view));
    query.addBindValue(retainRequest ? QVariant(QJsonDocument(request).toJson(QJsonDocument::Compact)) : QVariant());
    query.addBindValue(m_session);
    if (!query.exec())
        return fail(query.lastError().text());
    if (query.numRowsAffected() != 1)
        return fail(QStringLiteral("任务正在另一个万象窗口运行或已处理"));
    return addEvent(view, imported, inFlight) && writeArtifacts(view);
}

bool TaskStore::addEvent(const QVariantMap &view, bool imported, bool inFlight)
{
    const auto id = view.value("taskId");
    const auto state = view.value("state").toString();
    if (state.isEmpty())
        return true;
    QSqlQuery query(m_database);
    query.prepare("SELECT attempt, state FROM task_events WHERE task_id=? ORDER BY sequence DESC LIMIT 1");
    query.addBindValue(id);
    if (!query.exec())
        return fail(query.lastError().text());
    int attempt = imported && !inFlight ? 0 : 1;
    if (query.next()) {
        if (query.value(1).toString() == state)
            return true;
        attempt = query.value(0).toInt();
        if (state == QStringLiteral("等待"))
            ++attempt;
    }
    query.finish();
    query.prepare("INSERT INTO task_events(task_id, attempt, state, occurred_at, message, error_code) "
                  "VALUES(?, ?, ?, ?, ?, ?)");
    query.addBindValue(id);
    query.addBindValue(attempt);
    query.addBindValue(state);
    query.addBindValue(imported ? QVariant() : QVariant(QDateTime::currentMSecsSinceEpoch()));
    query.addBindValue(view.value("message"));
    query.addBindValue(view.value("errorCode"));
    return query.exec() || fail(query.lastError().text());
}

bool TaskStore::importSnapshots()
{
    QSqlQuery query(m_database);
    if (!query.exec("SELECT id, owner, snapshot FROM tasks WHERE NOT EXISTS "
                    "(SELECT 1 FROM task_events WHERE task_id=tasks.id)"))
        return fail(query.lastError().text());
    while (query.next()) {
        auto view = QJsonDocument::fromJson(query.value(2).toByteArray()).object().toVariantMap();
        view["taskId"] = query.value(0);
        if (!addEvent(view, true, !query.value(1).isNull()))
            return false;
    }
    return true;
}

bool TaskStore::writeArtifacts(const QVariantMap &view)
{
    const auto outputs = view.value("outputs").toList();
    if (view.value("state").toString() != QStringLiteral("完成") || outputs.isEmpty())
        return true;

    QSqlQuery completion(m_database);
    completion.prepare("SELECT sequence FROM task_events WHERE task_id=? AND state=? ORDER BY sequence DESC LIMIT 1");
    completion.addBindValue(view.value("taskId"));
    completion.addBindValue(view.value("state"));
    if (!completion.exec() || !completion.next())
        return fail(completion.lastError().text());
    const auto eventId = completion.value(0);
    completion.finish();

    QSqlQuery insert(m_database);
    if (!insert.prepare("INSERT INTO task_artifacts(completion, position, metadata) VALUES(?, ?, ?)"))
        return fail(insert.lastError().text());
    for (qsizetype index = 0; index < outputs.size(); ++index) {
        const auto item = outputs.at(index).toMap();
        if (item.value("path").toString().isEmpty())
            continue;
        insert.bindValue(0, eventId);
        insert.bindValue(1, index);
        insert.bindValue(2, QJsonDocument::fromVariant(item).toJson(QJsonDocument::Compact));
        if (!insert.exec())
            return fail(insert.lastError().text());
    }
    return true;
}

bool TaskStore::importArtifacts()
{
    QSqlQuery query(m_database);
    if (!query.exec("SELECT id, snapshot FROM tasks"))
        return fail(query.lastError().text());
    QList<QVariantMap> legacy;
    while (query.next()) {
        auto view = QJsonDocument::fromJson(query.value(1).toByteArray()).object().toVariantMap();
        if (view.contains("outputs")) {
            view["taskId"] = query.value(0);
            legacy.append(std::move(view));
        }
    }
    query.finish();
    if (!query.prepare("UPDATE tasks SET snapshot=? WHERE id=?"))
        return fail(query.lastError().text());
    for (const auto &view : legacy) {
        if (!writeArtifacts(view))
            return false;
        query.bindValue(0, encodeSnapshot(view));
        query.bindValue(1, view.value("taskId"));
        if (!query.exec())
            return fail(query.lastError().text());
    }
    return true;
}

QVariantList TaskStore::readArtifacts(const QString &taskId)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT metadata FROM task_artifacts WHERE completion=(SELECT sequence FROM task_events "
                  "WHERE task_id=? ORDER BY sequence DESC LIMIT 1) ORDER BY position");
    query.addBindValue(taskId);
    if (!query.exec()) {
        fail(query.lastError().text());
        return {};
    }
    QVariantList outputs;
    while (query.next())
        outputs.append(QJsonDocument::fromJson(query.value(0).toByteArray()).object().toVariantMap());
    return outputs;
}

QVariantList TaskStore::events(const QString &taskId)
{
    if (!available())
        return {};
    QSqlQuery query(m_database);
    query.prepare("SELECT attempt, state, occurred_at, message, error_code FROM task_events "
                  "WHERE task_id=? ORDER BY sequence DESC");
    query.addBindValue(taskId);
    if (!query.exec()) {
        fail(query.lastError().text());
        return {};
    }
    QVariantList events;
    while (query.next()) {
        events.append(QVariantMap{{"attempt", query.value(0)}, {"state", query.value(1)},
                                  {"timestamp", query.value(2).toLongLong()}, {"message", query.value(3)},
                                  {"errorCode", query.value(4)}});
    }
    return events;
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
    struct Row { Record record; QVariant owner; QByteArray stored; };
    QList<Row> rows;
    QSqlQuery query(m_database);
    if (!available() || !query.exec("SELECT id, owner, snapshot, request FROM tasks ORDER BY sequence")) {
        if (available())
            fail(query.lastError().text());
        return {};
    }
    while (query.next()) {
        const auto stored = query.value(2).toByteArray();
        auto view = QJsonDocument::fromJson(stored).object().toVariantMap();
        if (view.isEmpty())
            continue;
        view["taskId"] = query.value(0).toString();
        rows.append({{view, QJsonDocument::fromJson(query.value(3).toByteArray()).object()}, query.value(1), stored});
    }
    query.finish();

    static const QRegularExpression ownerId("^[a-f0-9]{32}$");
    QList<Record> history;
    for (auto &row : rows) {
        const auto owner = row.owner.toString();
        std::unique_ptr<QLockFile> previous;
        if (!owner.isEmpty()) {
            if (owner == m_session || !ownerId.match(owner).hasMatch())
                continue;
            previous = std::make_unique<QLockFile>(lockPath(m_directory, owner));
            previous->setStaleLockTime(0);
            if (!previous->tryLock(0))
                continue;
        }
        const auto receipt = (!owner.isEmpty() || row.record.view.value("state").toString() == QStringLiteral("已中断"))
                                 ? CommittedOutput::read(row.record.view) : CommittedOutput::Receipt{};
        if (!owner.isEmpty() || receipt) {
            const auto original = row.record.view;
            if (receipt) {
                row.record.view.insert(receipt.recoveredState());
                row.record.view.remove("errorCode");
            } else {
                row.record.view["state"] = QStringLiteral("已中断");
                row.record.view["progress"] = 0.0;
                row.record.view["message"] = row.record.request.isEmpty()
                    ? QStringLiteral("上次运行中断，请重新提交此任务")
                    : QStringLiteral("上次运行中断，可手动再次处理");
                row.record.view["errorCode"] = "interrupted";
            }
            if (!m_database.transaction()) {
                fail(m_database.lastError().text());
                continue;
            }
            query.prepare("UPDATE tasks SET owner=NULL, snapshot=?, request=CASE WHEN ? THEN NULL ELSE request END "
                          "WHERE id=? AND owner IS ? AND snapshot=?");
            query.addBindValue(encodeSnapshot(snapshot(row.record.view)));
            query.addBindValue(bool(receipt));
            query.addBindValue(row.record.view.value("taskId"));
            query.addBindValue(row.owner);
            query.addBindValue(row.stored);
            if (!query.exec()) {
                fail(query.lastError().text());
                m_database.rollback();
                continue;
            }
            if (query.numRowsAffected() != 1 || !addEvent(original, true, true) ||
                !addEvent(snapshot(row.record.view), false, false) || !writeArtifacts(row.record.view)) {
                m_database.rollback();
                continue;
            }
            if (!commit())
                continue;
            if (receipt) {
                row.record.request = {};
                CommittedOutput::acknowledge(row.record.view);
            }
        }
        if (row.record.view.value("state").toString() == QStringLiteral("完成")) {
            const auto outputs = readArtifacts(row.record.view.value("taskId").toString());
            if (!outputs.isEmpty())
                row.record.view["outputs"] = outputs;
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
