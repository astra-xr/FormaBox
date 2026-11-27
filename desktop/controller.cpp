#include "controller.h"
#include <QCoreApplication>
#include <QClipboard>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonArray>
#include <QProcessEnvironment>
#include <QDesktopServices>
#include <QUrl>
#include <QSettings>
#include <QSet>
#include <QSaveFile>
#include <QStyleHints>
#include <QTimer>
#include <QUuid>
#include <QRegularExpression>
#include <algorithm>

namespace {
constexpr const char *engineNames[] = {"LibreOffice", "ffmpeg", "tesseract"};
constexpr const char *engineVariables[] = {"FORMABOX_SOFFICE", "FORMABOX_FFMPEG", "FORMABOX_TESSERACT"};

QVariantMap detectBundledEngines() {
 const QDir application(QCoreApplication::applicationDirPath());
 const char *files[] = {"engines/libreoffice/program/soffice.com", "engines/ffmpeg/ffmpeg.exe",
                        "engines/tesseract/tesseract.exe"};
 QVariantMap paths;
 for (int i = 0; i < 3; ++i) {
  const QFileInfo engine(application.filePath(QString::fromLatin1(files[i])));
  if (!engine.isFile())
   return {};
  paths.insert(engineNames[i], engine.absoluteFilePath());
 }
 return paths;
}

bool isTaskOutput(const QFileInfo &directory, const QFileInfo &file) {
 if (!directory.isDir() || !directory.isAbsolute() || !file.isAbsolute() || file.isSymLink() ||
     !(file.isFile() || file.isDir()))
  return false;
 const auto root = directory.canonicalFilePath();
 const auto path = file.canonicalFilePath();
 if (root.isEmpty() || path.isEmpty() || path == root) return false;
 const auto relative = QDir(root).relativeFilePath(path);
 return relative != ".." && !relative.startsWith("../") && !QDir::isAbsolutePath(relative);
}

bool canOpenResult(const QFileInfo &file) {
 const auto suffix = file.suffix().toLower();
 static const QStringList formats = {"pdf", "png", "jpg", "jpeg", "webp", "bmp", "gif", "tif", "tiff", "avif",
     "ico", "docx", "xlsx", "pptx", "rtf", "txt", "json", "csv", "zip", "mp4", "mkv", "webm",
     "mov", "avi", "srt", "vtt", "mp3", "wav", "flac", "ogg", "m4a", "aac", "opus", "html", "7z", "tar", "gz"};
 return file.isDir() || formats.contains(suffix);
}

QVariantMap resultRow(const QFileInfo &file, const QVariantMap &details = {}) {
 QVariantMap row = {{"path", file.filePath()}, {"name", file.fileName()}, {"bytes", file.isDir() ? -1LL : file.size()},
                    {"folder", file.isDir()}};
 for (const auto *key : {"original_bytes", "target_bytes"}) {
  bool valid = false;
  const auto size = details.value(key).toLongLong(&valid);
  if (valid && size >= 0) row.insert(key, size);
 }
 return row;
}

QString batchSession(const QJsonObject &request) {
 if (request.value("tool").toString() != "folder.batch") return {};
 const auto id = request.value("params").toObject().value("session").toString();
 static const QRegularExpression pattern("^[a-f0-9]{32}$");
 return pattern.match(id).hasMatch() ? id : QString{};
}
}

Controller::Controller(QObject *parent)
 : QObject(parent), toolRegistry([this](QProcess &process) { configure(process); }),
   bundledEnginePaths(detectBundledEngines()) {
 loadHistory();
 m_presets = QSettings().value("tools/presets").toList();
 m_favorites = QSettings().value("tools/favorites").toStringList();
 connect(QGuiApplication::styleHints(),&QStyleHints::colorSchemeChanged,this,&Controller::systemThemeChanged);
 connect(&toolRegistry, &ToolRegistry::loading, this, [this] {
  setStatus(QStringLiteral("正在加载工具…"));
 });
 connect(&toolRegistry, &ToolRegistry::changed, this, [this] {
  emit toolsChanged();
  setStatus(QStringLiteral("已加载 %1 个工具 · 本地处理").arg(toolRegistry.tools().size()));
 });
 connect(&toolRegistry, &ToolRegistry::loadFailed, this, [this](const QString &details) {
  setStatus(QStringLiteral("工具引擎加载失败：") + details);
 });
 connect(&toolRegistry, &ToolRegistry::startFailed, this, [this](const QString &details) {
  setStatus(QStringLiteral("无法启动 Python 工具引擎：") + details);
 });
 connect(&worker,&QProcess::started,this,[this]{worker.write(QJsonDocument(activeRequest).toJson(QJsonDocument::Compact));worker.closeWriteChannel();});
 connect(&worker,&QProcess::readyReadStandardOutput,this,[this]{buffer+=worker.readAllStandardOutput();int n;while((n=buffer.indexOf('\n'))>=0){auto line=buffer.left(n);buffer.remove(0,n+1);processLine(line);}});
 connect(&worker,&QProcess::readyReadStandardError,this,[this]{worker.readAllStandardError();});
 connect(&worker,&QProcess::finished,this,&Controller::finalize);
 connect(&worker,&QProcess::errorOccurred,this,[this](QProcess::ProcessError e){
  if(e==QProcess::FailedToStart && active>=0)finishJob({{"state","失败"},{"message",worker.errorString()}});
 });
 inspectionTimeout.setSingleShot(true);
 connect(&inspectionTimeout, &QTimer::timeout, this, [this] {
  inspectionTimedOut = true;
  inspection.kill();
 });
 connect(&inspection, &QProcess::started, this, [this] {
  if (!inspectionRequest.isEmpty())
   inspection.write(QJsonDocument(inspectionRequest).toJson(QJsonDocument::Compact));
  inspection.closeWriteChannel();
 });
 connect(&inspection, &QProcess::finished, this, [this](int, QProcess::ExitStatus status) {
  finishInspection(status == QProcess::NormalExit);
 });
 connect(&inspection, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
  if (error == QProcess::FailedToStart)
   finishInspection(false);
 });
 QTimer::singleShot(0,this,&Controller::reload);
}
QString Controller::outputDefault()const{return QDir(QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation)).filePath("Omnora Output");}
bool Controller::systemDark()const{return QGuiApplication::styleHints()->colorScheme()==Qt::ColorScheme::Dark;}
void Controller::setStatus(QString s){m_status=std::move(s);emit statusChanged();}
void Controller::configure(QProcess &p, const QVariantMap *overrides){
 QString python=qEnvironmentVariable("FORMABOX_PYTHON"); if(python.isEmpty()){
  const QString bundled=QDir(QCoreApplication::applicationDirPath()).filePath("python/python.exe");
  const QString development=QDir(QCoreApplication::applicationDirPath()).filePath("../.venv/Scripts/python.exe");
  if(QFileInfo::exists(bundled))python=bundled;
  else if(QFileInfo::exists(development))python=QFileInfo(development).absoluteFilePath();
  else {
#ifdef Q_OS_WIN
  python=QStandardPaths::findExecutable("python.exe");
#else
  python=QStandardPaths::findExecutable("python3");
#endif
  }}
 auto env=QProcessEnvironment::systemEnvironment();env.insert("PYTHONUTF8","1");env.insert("PYTHONSAFEPATH","1");
 QString root=qEnvironmentVariable("FORMABOX_WORKER_DIR");if(root.isEmpty())root=QDir(QCoreApplication::applicationDirPath()).filePath("worker");
 if(QFileInfo::exists(QDir(root).filePath("formabox"))){QString old=env.value("PYTHONPATH");env.insert("PYTHONPATH",root+(old.isEmpty()?QString():QString(QDir::listSeparator())+old));}
 QString engines=QDir(QCoreApplication::applicationDirPath()).filePath("engines");env.insert("PATH",engines+QString(QDir::listSeparator())+env.value("PATH"));
 const auto paths = hasBundledEngines() ? bundledEnginePaths : (overrides ? *overrides : enginePaths());
 if (hasBundledEngines())
  env.remove("TESSDATA_PREFIX");
 for (int i = 0; i < 3; ++i) {
  const auto path = paths.value(engineNames[i]).toString();
  if (!path.isEmpty())
   env.insert(engineVariables[i], path);
 }
 p.setProcessEnvironment(env);p.setProgram(python);
}
void Controller::reload(){toolRegistry.reload();}
QString Controller::localPath(const QUrl &url)const{return url.isLocalFile()?url.toLocalFile():QString();}

QStringList Controller::inputSuffixes(const QVariantList &paths) const {
 QStringList suffixes;
 for (const auto &path : paths) {
  const QFileInfo file(path.toString());
  suffixes.append(file.isFile() ? file.suffix().toLower() : QString());
 }
 return suffixes;
}

QString Controller::presetParameters(const QString &tool, const QVariantMap &params, QVariantMap &values) const {
 if (tool == "pdf.compose")
  return QStringLiteral("页面布局无法保存为工具预设");
 const auto toolSpec = toolRegistry.find(tool);
 if (toolSpec.isEmpty())
  return QStringLiteral("工具不可用");
 for (const auto &item : toolSpec.value("params").toList()) {
  const auto spec = item.toMap();
  const auto key = spec.value("key").toString();
  if (spec.value("kind").toString() == "password")
   return QStringLiteral("含密码的工具不能保存预设");
  if (spec.value("kind").toString() == "internal")
   continue;
  const auto value = params.value(key, spec.value("default")).toString();
  if (value.size() > 4096)
   return QStringLiteral("预设参数太长");
  values.insert(key, value);
 }
 return {};
}

QString Controller::savePreset(QString name, const QString &tool, const QVariantMap &params,
                               const QVariantList &inputs) {
 QVariantMap values;
 const auto error = presetParameters(tool, params, values);
 if (!error.isEmpty()) return error;
 return storePreset(name, {{"tool", tool}, {"params", values}}, inputs);
}

QString Controller::saveWorkflowPreset(QString name, const QVariantList &steps, const QVariantList &inputs) {
 if (steps.isEmpty() || steps.size() > 32)
  return QStringLiteral("工作流需要 1–32 个步骤");
 QVariantList saved;
 for (const auto &item : steps) {
  const auto step = item.toMap();
  const auto tool = step.value("tool").toString();
  QVariantMap values;
  const auto error = presetParameters(tool, step.value("params").toMap(), values);
  if (!error.isEmpty()) return error;
  saved.append(QVariantMap{{"tool", tool}, {"params", values}});
 }
 return storePreset(name, {{"steps", saved}}, inputs);
}

QString Controller::storePreset(QString name, QVariantMap preset, const QVariantList &inputs) {
 name = name.trimmed();
 if (name.isEmpty() || name.size() > 40)
  return QStringLiteral("请输入 1–40 个字符的预设名称");
 auto next = m_presets;
 if (next.size() >= 24)
  return QStringLiteral("最多保存 24 个自定义预设");
 for (const auto &item : next)
  if (item.toMap().value("name").toString().compare(name, Qt::CaseInsensitive) == 0)
   return QStringLiteral("已有同名预设");
 auto suffixes = inputSuffixes(inputs);
 suffixes.removeAll(QString());
 suffixes.removeDuplicates();
 preset.insert("name", name);
 preset.insert("suffixes", suffixes);
 next.append(preset);
 return writePresets(next);
}

QString Controller::removePreset(const QString &name) {
 auto next = m_presets;
 const auto found = std::find_if(next.begin(), next.end(), [&name](const QVariant &item) {
  return item.toMap().value("name").toString() == name;
 });
 if (found == next.end())
  return QStringLiteral("预设不存在");
 next.erase(found);
 return writePresets(next);
}

QString Controller::writePresets(const QVariantList &presets) {
 QSettings settings;
 settings.setValue("tools/presets", presets);
 settings.sync();
 if (settings.status() != QSettings::NoError)
  return QStringLiteral("无法保存预设");
 m_presets = presets;
 emit presetsChanged();
 return {};
}

QVariantList Controller::resultItems(int index) const {
 if (index < 0 || index >= m_jobs.size()) return {};
 const auto job = m_jobs.at(index).toMap();
 const QFileInfo directory(job.value("directory").toString());
 QVariantList items;
 for (const auto &value : job.value("outputs").toList()) {
  auto item = value.toMap();
  const QFileInfo file(item.value("path").toString());
  const bool available = isTaskOutput(directory, file);
  item.insert("available", available);
  item.insert("canOpen", available && canOpenResult(file));
  items.append(item);
 }
 return items;
}

QVariantList Controller::useResults(int index, const QVariantList &paths) const {
 const auto available = resultItems(index);
 QVariantList selected;
 for (const auto &value : available) {
  const auto item = value.toMap();
  if (item.value("available").toBool() && paths.contains(item.value("path")))
   selected.append(item.value("path"));
 }
 return selected;
}

bool Controller::openResult(int index, const QString &path) {
 if (useResults(index, {path}).isEmpty()) return false;
 const QFileInfo file(path);
 if (!canOpenResult(file)) return false;
 return QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

QVariantMap Controller::enginePaths() const {
 return QSettings().value("engines/paths").toMap();
}

void Controller::checkEngines(const QVariantMap &paths, bool save) {
 if (inspecting()) return;
 QVariantMap candidates;
 for (const auto *name : engineNames) {
  const auto path = paths.value(name).toString().trimmed();
  if (path.isEmpty()) continue;
  const QFileInfo executable(path);
  const auto filename = executable.fileName().toLower();
  const bool office = QByteArray(name) == "LibreOffice";
  const QString stem = office ? QStringLiteral("soffice") : QString::fromLatin1(name);
  bool validName = filename == stem + ".exe" || (office && filename == "soffice.com");
#ifndef Q_OS_WIN
  validName = validName || filename == stem || (office && filename == "libreoffice");
#endif
  if (!executable.isAbsolute() || !executable.isFile() || !validName) {
   emit enginesChecked({}, QStringLiteral("%1：请选择安装目录中的可执行文件。").arg(QString::fromLatin1(name)));
   return;
  }
  candidates.insert(name, executable.absoluteFilePath());
 }
 candidateEngines = candidates;
 saveEngines = save;
 startInspection("check-engines", 70000, &candidateEngines);
}

void Controller::previewPdf(const QVariantList &inputs, int remaining) {
 if (inspecting()) return;
 if (!previewRoot)
  previewRoot = std::make_unique<QTemporaryDir>(QDir::temp().filePath("formabox-preview-XXXXXX"));
 if (!previewRoot->isValid()) {
  emit pdfPreviewReady({}, QStringLiteral("无法创建预览目录"));
  return;
 }
 previewBatch = std::make_unique<QTemporaryDir>(previewRoot->filePath("batch-XXXXXX"));
 if (!previewBatch->isValid()) {
  emit pdfPreviewReady({}, QStringLiteral("无法创建预览目录"));
  return;
 }
 inspectionRequest = QJsonObject::fromVariantMap(
     {{"inputs", inputs}, {"limit", remaining}, {"output", previewBatch->path()}});
 startInspection("preview-pdf", 60000);
}

void Controller::clearPdfPreview() {
 if (!inspecting()) previewRoot.reset();
}

void Controller::previewRename(const QVariantList &inputs, const QVariantMap &params) {
 if (inspecting()) return;
 inspectionRequest = QJsonObject::fromVariantMap({{"inputs", inputs}, {"params", params}});
 startInspection("preview-rename", 60000);
}

bool Controller::setFavorites(const QStringList &ids) {
 if (ids.size() > 12 || QSet<QString>(ids.cbegin(), ids.cend()).size() != ids.size()) return false;
 for (const auto &id : ids)
  if (toolRegistry.find(id).isEmpty()) return false;
 QSettings settings;
 settings.setValue("tools/favorites", ids);
 settings.sync();
 if (settings.status() != QSettings::NoError) return false;
 m_favorites = ids;
 emit favoritesChanged();
 return true;
}

void Controller::previewStudio(const QString &tool, const QVariantList &inputs, const QVariantMap &params,
                               const QVariantMap &options) {
 if (inspecting()) return;
 if (!studioRoot) studioRoot = std::make_unique<QTemporaryDir>();
 if (studioRoot->isValid())
  studioBatch = std::make_unique<QTemporaryDir>(studioRoot->filePath("preview-XXXXXX"));
 if (!studioBatch || !studioBatch->isValid()) {
  emit studioPreviewReady({}, QStringLiteral("无法创建预览目录"));
  return;
 }
 auto request = options;
 request.insert("tool", tool);
 request.insert("inputs", inputs);
 request.insert("params", params);
 request.insert("output", studioBatch->path());
 inspectionRequest = QJsonObject::fromVariantMap(request);
 startInspection("preview-tool", 180000);
}

void Controller::clearStudioPreview() {
 if (inspectionCommand != "preview-tool") studioRoot.reset();
}

void Controller::playStudioSample(const QUrl &url) {
 const QFileInfo file(url.toLocalFile());
 if (studioRoot && file.suffix() == "wav" && isTaskOutput(QFileInfo(studioRoot->path()), file))
  QDesktopServices::openUrl(url);
}

void Controller::copyText(const QString &text) {
 if (text.size() <= 500000) QGuiApplication::clipboard()->setText(text);
}

void Controller::previewPdfCompression(const QVariantList &inputs, const QString &pages, int targetKiB, int page) {
 if (inspecting()) return;
 compressionPreview = std::make_unique<QTemporaryDir>();
 if (!compressionPreview->isValid()) {
  compressionPreview.reset();
  emit pdfCompressionReady({}, QStringLiteral("无法创建压缩预览目录"));
  return;
 }
 inspectionRequest = QJsonObject::fromVariantMap(
     {{"inputs", inputs}, {"pages", pages}, {"output", compressionPreview->path()},
      {"target_kib", targetKiB}, {"page", page}});
 startInspection("preview-pdf-compression", 180000);
}

void Controller::clearPdfCompression() {
 if (inspectionCommand != "preview-pdf-compression") {
  compressionPreview.reset();
  compressionDetails.clear();
 }
}

QString Controller::savePdfCompression(const QString &output) {
 if (!compressionPreview || inspecting())
  return QStringLiteral("请先生成压缩预览");
 const auto directory = QDir::cleanPath(output.trimmed());
 if (!QDir::isAbsolutePath(directory) || !QDir().mkpath(directory))
  return QStringLiteral("无法创建输出目录");
 QFile preview(compressionPreview->filePath("compressed.pdf"));
 if (!preview.open(QIODevice::ReadOnly) || preview.size() <= 0)
  return QStringLiteral("压缩预览已失效");
 QTemporaryDir result(QDir(directory).filePath("Omnora-XXXXXX"));
 if (!result.isValid())
  return QStringLiteral("无法创建任务目录");
 QSaveFile destination(result.filePath("workbench.pdf"));
 if (!destination.open(QIODevice::WriteOnly))
  return QStringLiteral("无法保存 PDF：") + destination.errorString();
 while (!preview.atEnd()) {
  const auto bytes = preview.read(1024 * 1024);
  if (bytes.isEmpty() || destination.write(bytes) != bytes.size())
   return QStringLiteral("无法写入 PDF");
 }
 if (!destination.commit())
  return QStringLiteral("无法保存 PDF：") + destination.errorString();
 result.setAutoRemove(false);
 m_jobs.append(QVariantMap{{"title", QStringLiteral("PDF 页面工作台")},
                          {"state", QStringLiteral("完成")}, {"progress", 1.0},
                          {"message", QStringLiteral("已保存预览 · %1 KiB").arg(preview.size() / 1024.0, 0, 'f', 1)},
                          {"directory", result.path()},
                          {"outputs", QVariantList{resultRow(QFileInfo(result.filePath("workbench.pdf")), compressionDetails)}}});
 saveHistory();
 emit jobsChanged();
 return {};
}

void Controller::startInspection(const QString &command, int timeout, const QVariantMap *overrides) {
 inspectionCommand = command;
 inspectionTimedOut = false;
 configure(inspection, overrides);
 inspection.setArguments({"-B", "-m", "formabox", command});
 emit inspectionChanged();
 inspectionTimeout.start(timeout);
 inspection.start();
}

void Controller::finishInspection(bool exited) {
 if (!inspecting()) return;
 inspectionTimeout.stop();
 const auto reply = QJsonDocument::fromJson(inspection.readAllStandardOutput()).object();
 const auto diagnostics = QString::fromUtf8(inspection.readAllStandardError()).trimmed();
 const auto result = reply.value("result");
 auto error = reply.value("error").toString();
 if (inspectionTimedOut)
  error = QStringLiteral("操作超时");
 else if (!exited || (result.isUndefined() && error.isEmpty()))
  error = diagnostics.isEmpty() ? QStringLiteral("无法运行工作进程") : diagnostics.left(500);

 const bool pdf = inspectionCommand == "preview-pdf";
 const bool compression = inspectionCommand == "preview-pdf-compression";
 const bool rename = inspectionCommand == "preview-rename";
 const bool studio = inspectionCommand == "preview-tool";
 QVariantList pages;
 QVariantMap checks;
 if (pdf) {
  const auto inputs = inspectionRequest.value("inputs").toArray();
  for (const auto &value : result.toArray()) {
   const auto row = value.toObject();
   const int source = row.value("source").toInt(-1);
   const int page = row.value("page").toInt(-1);
   const QString image = row.value("thumbnail").toString();
   const auto thumbnail = previewBatch->filePath(image);
   if (source < 0 || source >= inputs.size() || page < 0 || !image.endsWith(".png") ||
       QFileInfo(image).fileName() != image || !QFileInfo(thumbnail).isFile()) {
    error = QStringLiteral("预览结果无效");
    break;
   }
   const auto path = inputs.at(source).toString();
   pages.append(QVariantMap{{"path", path}, {"name", QFileInfo(path).fileName()}, {"page", page},
                            {"thumbnail", QUrl::fromLocalFile(thumbnail)}, {"rotation", 0}});
  }
  if (pages.isEmpty() && error.isEmpty())
   error = QStringLiteral("文件没有可用页面");
  if (error.isEmpty())
   previewBatch->setAutoRemove(false);
  else
   pages.clear();
  previewBatch.reset();
 } else if (compression) {
  const QFileInfo candidate(compressionPreview->filePath("compressed.pdf"));
  const auto before = compressionPreview->filePath("before.png");
  const auto after = compressionPreview->filePath("after.png");
  checks = result.toObject().toVariantMap();
  if (error.isEmpty() && (!candidate.isFile() || !QFileInfo(before).isFile() || !QFileInfo(after).isFile() ||
                          candidate.size() <= 0 || candidate.size() != checks.value("size").toLongLong() ||
                          !checks.contains("met")))
   error = QStringLiteral("压缩结果无效");
  if (error.isEmpty()) {
   checks.insert("before", QUrl::fromLocalFile(before));
   checks.insert("after", QUrl::fromLocalFile(after));
   compressionDetails = {{"original_bytes", checks.value("original")}, {"target_bytes", checks.value("target")}};
  } else {
   compressionPreview.reset();
  }
 } else if (rename) {
  checks = result.toObject().toVariantMap();
  if (error.isEmpty() && (checks.value("rows").toList().isEmpty() || checks.value("plan").toString().size() != 64))
   error = QStringLiteral("改名预览结果无效");
 } else if (studio) {
  checks = result.toObject().toVariantMap();
  const auto previewUrl = [&](const QVariant &entry) {
   const auto name = entry.toString();
   const QFileInfo file(studioBatch->filePath(name));
   if (name.isEmpty() || QFileInfo(name).fileName() != name ||
       !isTaskOutput(QFileInfo(studioBatch->path()), file) || !file.isFile()) {
    error = QStringLiteral("预览文件无效");
    return QUrl{};
   }
   return QUrl::fromLocalFile(file.filePath());
  };
  for (const auto *key : {"image", "sample"}) {
   if (checks.contains(key)) checks[key] = previewUrl(checks[key]);
  }
  if (checks.contains("pictures")) {
   QVariantList pictures;
   for (const auto &file : checks.value("pictures").toList()) pictures.append(previewUrl(file));
   checks["pictures"] = pictures;
  }
  if (checks.contains("rows")) {
   QVariantList rows;
   for (const auto &value : checks.value("rows").toList()) {
    auto row = value.toMap();
    if (row.contains("thumbnail")) row["thumbnail"] = previewUrl(row["thumbnail"]);
    rows.append(row);
   }
   checks["rows"] = rows;
  }
  if (error.isEmpty()) studioBatch->setAutoRemove(false);
  studioBatch.reset();
 } else {
  checks = result.toObject().toVariantMap();
  if (error.isEmpty() && saveEngines) {
   for (auto it = candidateEngines.cbegin(); it != candidateEngines.cend(); ++it) {
    if (!checks.value(it.key()).toMap().value("ok").toBool()) {
     error = QStringLiteral("%1 未通过测试，设置未保存").arg(it.key());
     break;
    }
   }
   if (error.isEmpty()) {
    QSettings settings;
    settings.setValue("engines/paths", candidateEngines);
    settings.sync();
    if (settings.status() == QSettings::NoError) {
     error = QStringLiteral("设置已保存");
     reload();
    } else {
     error = QStringLiteral("无法保存引擎设置");
    }
   }
  }
  if (error.isEmpty())
   error = QStringLiteral("测试结束");
 }
 inspectionRequest = {};
 inspectionCommand.clear();
 emit inspectionChanged();
 if (pdf)
  emit pdfPreviewReady(pages, error);
 else if (compression)
  emit pdfCompressionReady(checks, error);
 else if (rename)
  emit renamePreviewReady(checks.value("rows").toList(), checks.value("plan").toString(), error);
 else if (studio)
  emit studioPreviewReady(checks, error);
 else
  emit enginesChecked(checks, error);
}
void Controller::submit(QString tool,QVariantList inputs,QVariantMap params,QString output){
 if(tool.isEmpty()||inputs.isEmpty()||output.trimmed().isEmpty()){setStatus(QStringLiteral("请选择工具、输入和输出目录"));return;}
 const auto title = toolRegistry.find(tool).value("label", tool).toString();
 enqueue(QJsonObject::fromVariantMap({{"tool",tool},{"inputs",inputs},{"params",params},{"output",output}}),title);
}
void Controller::submitWorkflow(QVariantList steps,QVariantList inputs,QString output){if(steps.isEmpty()||inputs.isEmpty()||output.trimmed().isEmpty()){setStatus(QStringLiteral("请提供工作流、输入及输出目录"));return;}enqueue(QJsonObject::fromVariantMap({{"steps",steps},{"inputs",inputs},{"output",output}}),QStringLiteral("工作流 (%1 步)").arg(steps.size()));}
void Controller::enqueue(QJsonObject json, QString title) {
 if (json.value("tool").toString() == "folder.batch") {
  if (batchSession(json).isEmpty()) {
   auto params = json.value("params").toObject();
   params["session"] = QUuid::createUuid().toString(QUuid::Id128);
   json["params"] = params;
  }
  QSettings settings;
  settings.setValue("resume/" + batchSession(json), json.toVariantMap());
  settings.sync();
  if (settings.status() != QSettings::NoError) {
   setStatus(QStringLiteral("无法记录续跑任务"));
   return;
  }
 }
 const int index = m_jobs.size();
 m_jobs.append(QVariantMap{{"title", title}, {"state", "等待"}, {"progress", 0.0}, {"message", ""}, {"directory", ""}});
 pending.enqueue({index, std::move(json)});
 emit jobsChanged();
 startNext();
}
void Controller::update(int i,QVariantMap values){if(i<0||i>=m_jobs.size())return;auto row=m_jobs[i].toMap();for(auto it=values.begin();it!=values.end();++it)row.insert(it.key(),it.value());m_jobs[i]=row;emit jobsChanged();}
void Controller::startNext(){
 if(active>=0||pending.isEmpty())return;
 auto request=pending.dequeue();
 active=request.index;
 activeRequest=request.json;
 outcome={};
 protocolError=false;
 buffer.clear();
 temp=std::make_unique<QTemporaryDir>();
 if(!temp->isValid()){
  finishJob({{"state","失败"},{"message","无法建立临时目录"}});
  return;
 }
 activeRequest.insert("cancel",temp->filePath("cancel"));
 configure(worker);
 worker.setArguments({"-B","-m","formabox","run","--request","-"});
 update(active,{{"state","运行中"},{"progress",-1.0},{"message","准备处理"}});
 worker.start();
}
void Controller::processLine(QByteArray line){
 if(active<0||line.trimmed().isEmpty())return;
 const auto object=QJsonDocument::fromJson(line).object();
 const auto event=object.value("event").toString();
 if(!outcome.isEmpty()){
  protocolError=true;
 }else if(event=="progress"){
  const auto total=object.value("total").toDouble();
  const auto progress=total>0?std::clamp(object.value("current").toDouble()/total,0.0,0.99):-1.0;
  update(active,{{"progress",progress},{"message",object.value("message").toString()}});
 }else if(event=="result"||event=="error"||event=="cancelled"){
  outcome=object;
 }else{
  protocolError=true;
 }
}
void Controller::finalize(int code,QProcess::ExitStatus exitStatus){
 if(active<0)return;
 buffer+=worker.readAllStandardOutput();
 for(const auto &line:buffer.split('\n'))processLine(line);
 const auto event=outcome.value("event").toString();
 if(!protocolError&&exitStatus==QProcess::NormalExit){
  if(event=="result"&&code==0){
   const QFileInfo directory(outcome.value("directory").toString());
   const auto files=outcome.value("files").toArray();
   bool valid=directory.isDir()&&directory.isAbsolute()&&!files.isEmpty();
   const auto details = outcome.value("details").toArray();
   QVariantList outputs;
   for (qsizetype index = 0; valid && index < files.size(); ++index) {
    const QFileInfo file(files.at(index).toString());
    valid = isTaskOutput(directory, file);
    if (valid)
     outputs.append(resultRow(file, index < details.size() ? details.at(index).toObject().toVariantMap() : QVariantMap{}));
   }
   if(valid){
    finishJob({{"state","完成"},{"progress",1.0},{"directory",directory.absoluteFilePath()},
               {"message",QStringLiteral("输出 %1 项").arg(files.size())},{"outputs",outputs}});
    return;
   }
   finishJob({{"state","失败"},{"message","工作进程返回的结果文件无效"}});
   return;
  }
  if((event=="error"&&code==1)||(event=="cancelled"&&code==2)){
   finishJob({{"state",event=="error"?"失败":"已取消"},{"message",outcome.value("message").toString()}});
   return;
  }
 }
 finishJob({{"state","失败"},{"message",QStringLiteral("工作进程异常退出 (%1)").arg(code)}});
}
void Controller::finishJob(QVariantMap values){
 const auto usesPassword=[](const QJsonObject &request){return request.value("params").toObject().contains("password");};
 bool sensitive=usesPassword(activeRequest);
 for(const auto &step:activeRequest.value("steps").toArray())sensitive=sensitive||usesPassword(step.toObject());
 const auto session = batchSession(activeRequest);
 const auto state = values.value("state").toString();
 if (!session.isEmpty() && state == "完成") {
  QSettings settings;
  settings.remove("resume/" + session);
  settings.sync();
 }
 if (!sensitive && (state == "失败" || (!session.isEmpty() && state == "已取消"))) {
  activeRequest.remove("cancel");
  retryRequests.insert(active,activeRequest);
  values.insert("canRetry",true);
  values.insert("canResume", !session.isEmpty());
 }
 const int finished=active;
 active=-1;
 activeRequest={};
 temp.reset();
 update(finished,values);
 saveHistory();
 QTimer::singleShot(0,this,&Controller::startNext);
}
void Controller::cancel(int index){if(index==active&&temp){if(!outcome.isEmpty())return;QFile f(temp->filePath("cancel"));if(f.open(QIODevice::WriteOnly)){f.close();update(index,{{"message","已请求取消，等待安全退出"}});}else setStatus(QStringLiteral("无法请求取消：")+f.errorString());return;}for(int i=0;i<pending.size();++i)if(pending[i].index==index){pending.removeAt(i);update(index,{{"state","已取消"},{"message","取消排队"}});saveHistory();return;}}
void Controller::retry(int index){
 if(!retryRequests.contains(index))return;
 auto request=retryRequests.take(index);
 update(index,{{"canRetry",false}});
 enqueue(request,m_jobs.at(index).toMap().value("title").toString());
}
QString Controller::readWorkflow(const QUrl &url){
 QFile file(localPath(url));
 if(!file.open(QIODevice::ReadOnly)||file.size()>1024*1024){setStatus(QStringLiteral("无法读取工作流文件或文件过大"));return {};}
 return QString::fromUtf8(file.readAll());
}
bool Controller::writeWorkflow(const QUrl &url,const QString &text){
 QSaveFile file(localPath(url));
 const auto data=text.toUtf8();
 if(!file.open(QIODevice::WriteOnly)||file.write(data)!=data.size()||!file.commit()){
  setStatus(QStringLiteral("保存工作流失败：")+file.errorString());
  return false;
 }
 return true;
}
void Controller::openFolder(QString path){if(QFileInfo(path).isDir())QDesktopServices::openUrl(QUrl::fromLocalFile(path));}
void Controller::loadHistory() {
 QSettings settings;
 m_jobs = settings.value("jobs").toList();
 settings.beginGroup("resume");
 for (const auto &key : settings.childKeys()) {
  const auto request = QJsonObject::fromVariantMap(settings.value(key).toMap());
  if (batchSession(request) != key || request.value("output").toString().isEmpty()) continue;
  retryRequests.insert(m_jobs.size(), request);
  m_jobs.append(QVariantMap{{"title", "文件夹批处理"}, {"state", "可继续"}, {"progress", 0.0},
                           {"message", "从已保存的结果接着处理"}, {"canResume", true}, {"canRetry", true}});
 }
}
void Controller::saveHistory(){QVariantList history;for(auto v:m_jobs){auto m=v.toMap();m.remove("canRetry");if(m.value("state").toString()!="等待"&&m.value("state").toString()!="运行中")history.append(m);}while(history.size()>100)history.removeFirst();QSettings s;s.setValue("jobs",history);}
void Controller::clearHistory(){
 if(busy())return;
 m_jobs.clear();
 retryRequests.clear();
 QSettings().remove("resume");
 saveHistory();
 emit jobsChanged();
}
