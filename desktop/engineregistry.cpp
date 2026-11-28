#include "engineregistry.h"

#include <QDir>
#include <QFileInfo>
#include <QSettings>
#include <utility>

namespace {
constexpr auto settingsKey = "engines/paths";

struct Engine {
    const char *id;
    const char *name;
    const char *variable;
    const char *bundledFile;
    const char *program;
    bool requiredForBundle;
};

constexpr Engine engines[] = {
    {"LibreOffice", "LibreOffice", "FORMABOX_SOFFICE", "libreoffice/program/soffice.com", "soffice", true},
    {"ffmpeg", "FFmpeg", "FORMABOX_FFMPEG", "ffmpeg/ffmpeg.exe", "ffmpeg", true},
    {"tesseract", "Tesseract", "FORMABOX_TESSERACT", "tesseract/tesseract.exe", "tesseract", true},
    {"whisper-cli", "whisper.cpp", "FORMABOX_WHISPER", "whisper/whisper-cli.exe", "whisper-cli", false},
};

bool isOffice(const Engine &engine)
{
    return QLatin1StringView(engine.program) == QLatin1StringView("soffice");
}

bool validProgram(const Engine &engine, const QFileInfo &file)
{
    const auto filename = file.fileName().toLower();
    const auto program = QString::fromLatin1(engine.program);
    if (filename == program + ".exe" || (isOffice(engine) && filename == "soffice.com"))
        return true;
#ifndef Q_OS_WIN
    if (filename == program || (isOffice(engine) && filename == "libreoffice"))
        return true;
#endif
    return false;
}
}

EngineRegistry::EngineRegistry(const QString &applicationDirectory)
    : m_engineDirectory(QDir(applicationDirectory).filePath("engines"))
{
    const QDir directory(m_engineDirectory);
    for (const auto &engine : engines) {
        const QFileInfo executable(directory.filePath(QString::fromLatin1(engine.bundledFile)));
        if (executable.isFile())
            m_bundledPaths.insert(engine.id, executable.absoluteFilePath());
        else if (engine.requiredForBundle)
            m_hasBundledEngines = false;
    }
}

QVariantList EngineRegistry::options() const
{
    QVariantList entries;
    for (const auto &engine : engines) {
        const auto name = QString::fromLatin1(engine.name);
        const auto program = QString::fromLatin1(engine.program);
        const auto names = isOffice(engine) ? QStringLiteral("soffice.exe soffice.com") : program + ".exe";
        entries.append(QVariantMap{{"id", engine.id}, {"name", name}, {"filter", name + " (" + names + ")"}});
    }
    return entries;
}

QVariantMap EngineRegistry::savedPaths() const
{
    return QSettings().value(settingsKey).toMap();
}

void EngineRegistry::configure(QProcessEnvironment &environment, const QVariantMap *candidates) const
{
    environment.insert("PATH", m_engineDirectory + QDir::listSeparator() + environment.value("PATH"));
    const auto selected = hasBundledEngines() ? m_bundledPaths : (candidates ? *candidates : savedPaths());
    if (hasBundledEngines())
        environment.remove("TESSDATA_PREFIX");
    for (const auto &engine : engines) {
        const auto path = selected.value(engine.id).toString();
        if (!path.isEmpty())
            environment.insert(engine.variable, path);
    }
}

QString EngineRegistry::validate(const QVariantMap &paths, QVariantMap &candidates) const
{
    QVariantMap accepted;
    for (const auto &engine : engines) {
        const auto selection = paths.value(engine.id).toString().trimmed();
        if (selection.isEmpty())
            continue;
        const QFileInfo file(selection);
        if (!file.isAbsolute() || !file.isFile() || !validProgram(engine, file))
            return QStringLiteral("%1：请选择安装目录中的可执行文件。").arg(QString::fromLatin1(engine.name));
        accepted.insert(engine.id, file.absoluteFilePath());
    }
    candidates = std::move(accepted);
    return {};
}

QString EngineRegistry::saveTested(const QVariantMap &candidates, const QVariantMap &checks) const
{
    for (auto it = candidates.cbegin(); it != candidates.cend(); ++it) {
        const auto check = checks.value(it.key()).toMap();
        const auto tested = QFileInfo(check.value("path").toString()).canonicalFilePath();
        const auto selected = QFileInfo(it.value().toString()).canonicalFilePath();
        if (!check.value("ok").toBool() || tested.isEmpty() || QFileInfo(tested) != QFileInfo(selected))
            return QStringLiteral("%1 所选路径未通过测试，设置未保存").arg(it.key());
    }
    QSettings settings;
    settings.setValue(settingsKey, candidates);
    settings.sync();
    if (settings.status() != QSettings::NoError)
        return QStringLiteral("无法保存引擎设置");
    return {};
}
