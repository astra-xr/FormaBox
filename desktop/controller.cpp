#include "controller.h"
#include "outputpath.h"
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
 : QObject(parent), engineRegistry(QCoreApplication::applicationDirPath()),
   toolRegistry([this](QProcess &process) { configure(process); }),
   inspection([this](QProcess &process, const QVariantMap *paths) { configure(process, paths); }),
   previews(inspection) {
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
 connect(&inspection, &InspectionRunner::busyChanged, this, &Controller::inspectionChanged);
 connect(&inspection, &InspectionRunner::finished, this, [this](const QString &command, const QJsonObject &,
                                                               const QJsonValue &result, const QString &error) {
  if (command == "check-engines") finishEngineCheck(result, error);
 });
 connect(&previews, &PreviewService::pdfPreviewReady, this, &Controller::pdfPreviewReady);
 connect(&previews, &PreviewService::pdfCompressionReady, this, &Controller::pdfCompressionReady);
 connect(&previews, &PreviewService::renamePreviewReady, this, &Controller::renamePreviewReady);
 connect(&previews, &PreviewService::studioPreviewReady, this, &Controller::studioPreviewReady);
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
 engineRegistry.configure(env, overrides);
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
 return engineRegistry.savedPaths();
}

void Controller::checkEngines(const QVariantMap &paths, bool save) {
 if (inspecting()) return;
 const auto error = engineRegistry.validate(paths, candidateEngines);
 if (!error.isEmpty()) {
  emit enginesChecked({}, error);
  return;
 }
 saveEngines = save;
 inspection.start("check-engines", 75000, {}, &candidateEngines);
}

void Controller::previewPdf(const QVariantList &inputs, int remaining) {
 previews.previewPdf(inputs, remaining);
}

void Controller::clearPdfPreview() {
 previews.clearPdfPreview();
}

void Controller::previewRename(const QVariantList &inputs, const QVariantMap &params) {
 previews.previewRename(inputs, params);
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
 previews.previewStudio(tool, inputs, params, options);
}

void Controller::clearStudioPreview() {
 previews.clearStudioPreview();
}

void Controller::playStudioSample(const QUrl &url) {
 previews.playStudioSample(url);
}

void Controller::copyText(const QString &text) {
 if (text.size() <= 500000) QGuiApplication::clipboard()->setText(text);
}

void Controller::previewPdfCompression(const QVariantList &inputs, const QString &pages, int targetKiB, int page) {
 previews.previewPdfCompression(inputs, pages, targetKiB, page);
}

void Controller::clearPdfCompression() {
 previews.clearPdfCompression();
}

QString Controller::savePdfCompression(const QString &output) {
 const auto saved = previews.savePdfCompression(output);
 if (!saved.error.isEmpty()) return saved.error;

 const QFileInfo file(saved.path);
 m_jobs.append(QVariantMap{{"title", QStringLiteral("PDF 页面工作台")},
                          {"state", QStringLiteral("完成")}, {"progress", 1.0},
                          {"message", QStringLiteral("已保存预览 · %1 KiB").arg(file.size() / 1024.0, 0, 'f', 1)},
                          {"directory", file.absolutePath()},
                          {"outputs", QVariantList{resultRow(file, saved.details)}}});
 saveHistory();
 emit jobsChanged();
 return {};
}

void Controller::finishEngineCheck(const QJsonValue &result, QString error) {
 const auto checks = result.toObject().toVariantMap();
 if (error.isEmpty() && !result.isObject())
  error = QStringLiteral("引擎诊断结果无效");
 bool saved = false;
 if (error.isEmpty() && saveEngines) {
  error = engineRegistry.saveTested(candidateEngines, checks);
  saved = error.isEmpty();
  if (saved)
   error = QStringLiteral("设置已保存");
 }
 candidateEngines.clear();
 saveEngines = false;
 if (saved)
  reload();
 if (error.isEmpty())
  error = QStringLiteral("测试结束");
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
