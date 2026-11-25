#include "controller.h"
#include <QCoreApplication>
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
#include <QSaveFile>
#include <QStyleHints>
#include <QTimer>
#include <algorithm>

namespace {
constexpr const char *engineNames[] = {"LibreOffice", "ffmpeg", "tesseract"};
constexpr const char *engineVariables[] = {"FORMABOX_SOFFICE", "FORMABOX_FFMPEG", "FORMABOX_TESSERACT"};
}

Controller::Controller(QObject *parent):QObject(parent){
 loadHistory();
 connect(QGuiApplication::styleHints(),&QStyleHints::colorSchemeChanged,this,&Controller::systemThemeChanged);
 connect(&catalogue,&QProcess::finished,this,[this](int code,QProcess::ExitStatus es){
  const auto doc=QJsonDocument::fromJson(catalogue.readAllStandardOutput());
  if(code==0 && es==QProcess::NormalExit && doc.isArray()){m_tools=doc.array().toVariantList();emit toolsChanged();setStatus(QStringLiteral("已加载 %1 个工具 · 本地处理").arg(m_tools.size()));}
  else setStatus(QStringLiteral("工具引擎加载失败：")+QString::fromUtf8(catalogue.readAllStandardError()).left(500));
  if (reloadPending) {
   reloadPending = false;
   QTimer::singleShot(0, this, &Controller::reload);
  }
 });
 connect(&catalogue,&QProcess::errorOccurred,this,[this](QProcess::ProcessError){setStatus(QStringLiteral("无法启动 Python 工具引擎：")+catalogue.errorString());});
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
QString Controller::outputDefault()const{return QDir(QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation)).filePath("FormaBox Output");}
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
 const auto paths = overrides ? *overrides : enginePaths();
 for (int i = 0; i < 3; ++i) {
  const auto path = paths.value(engineNames[i]).toString();
  if (!path.isEmpty())
   env.insert(engineVariables[i], path);
 }
 if (!env.contains("TESSDATA_PREFIX")) {
  const auto customOcr = env.value("FORMABOX_TESSERACT");
  const QDir ocrFolder = customOcr.isEmpty() ? QDir(engines) : QFileInfo(customOcr).dir();
  const auto tessdata = ocrFolder.filePath("tessdata");
  if (QFileInfo(tessdata).isDir())
   env.insert("TESSDATA_PREFIX", tessdata);
 }
 p.setProcessEnvironment(env);p.setProgram(python);
}
void Controller::reload(){if(catalogue.state()!=QProcess::NotRunning){reloadPending=true;return;}configure(catalogue);catalogue.setArguments({"-B","-m","formabox","list","--check-engines"});setStatus(QStringLiteral("正在加载工具…"));catalogue.start();}
QString Controller::localPath(const QUrl &url)const{return url.isLocalFile()?url.toLocalFile():QString();}

QStringList Controller::inputSuffixes(const QVariantList &paths) const {
 QStringList suffixes;
 for (const auto &path : paths) {
  const QFileInfo file(path.toString());
  suffixes.append(file.isFile() ? file.suffix().toLower() : QString());
 }
 return suffixes;
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
 else
  emit enginesChecked(checks, error);
}
void Controller::submit(QString tool,QVariantList inputs,QVariantMap params,QString output){
 if(tool.isEmpty()||inputs.isEmpty()||output.trimmed().isEmpty()){setStatus(QStringLiteral("请选择工具、输入和输出目录"));return;}
 QString title=tool;for(auto v:m_tools){auto m=v.toMap();if(m.value("id").toString()==tool)title=m.value("label").toString();}
 enqueue(QJsonObject::fromVariantMap({{"tool",tool},{"inputs",inputs},{"params",params},{"output",output}}),title);
}
void Controller::submitWorkflow(QVariantList steps,QVariantList inputs,QString output){if(steps.isEmpty()||inputs.isEmpty()||output.trimmed().isEmpty()){setStatus(QStringLiteral("请提供工作流、输入及输出目录"));return;}enqueue(QJsonObject::fromVariantMap({{"steps",steps},{"inputs",inputs},{"output",output}}),QStringLiteral("工作流 (%1 步)").arg(steps.size()));}
void Controller::enqueue(QJsonObject json,QString title){int i=m_jobs.size();m_jobs.append(QVariantMap{{"title",title},{"state","等待"},{"progress",0.0},{"message",""},{"directory",""}});pending.enqueue({i,std::move(json)});emit jobsChanged();startNext();}
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
   const QDir canonical(directory.canonicalFilePath());
   for(const auto &entry:files){
    const QFileInfo file(entry.toString());
    const auto relative=canonical.relativeFilePath(file.canonicalFilePath());
    valid=valid&&file.exists()&&file.isAbsolute()&&relative!=".."&&!relative.startsWith("../")&&!QDir::isAbsolutePath(relative);
   }
   if(valid){
    finishJob({{"state","完成"},{"progress",1.0},{"directory",directory.absoluteFilePath()},{"message",QStringLiteral("输出 %1 项").arg(files.size())}});
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
 if(!sensitive&&values.value("state").toString()=="失败"){
  activeRequest.remove("cancel");
  retryRequests.insert(active,activeRequest);
  values.insert("canRetry",true);
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
void Controller::loadHistory(){QSettings s; m_jobs=s.value("jobs").toList();}
void Controller::saveHistory(){QVariantList history;for(auto v:m_jobs){auto m=v.toMap();m.remove("canRetry");if(m.value("state").toString()!="等待"&&m.value("state").toString()!="运行中")history.append(m);}while(history.size()>100)history.removeFirst();QSettings s;s.setValue("jobs",history);}
void Controller::clearHistory(){if(busy())return;m_jobs.clear();retryRequests.clear();saveHistory();emit jobsChanged();}
