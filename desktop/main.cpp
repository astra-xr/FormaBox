#include <QDebug>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QImage>
#include <QJSValue>
#include <QMouseEvent>
#include <QPainter>
#include <QPdfWriter>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSet>
#include <QSettings>
#include <QTimer>
#include <functional>
#include "controller.h"
#ifdef Q_OS_WIN
#include "windowframe_win.h"
#endif

static bool invokeQml(QJSValue object, const char *method, const QJSValueList &arguments = {})
{
    const auto result = object.property(QString::fromLatin1(method)).callWithInstance(object, arguments);
    if (result.isError())
        qWarning().noquote() << method << result.toString();
    return !result.isError() && object.property(QString::fromLatin1(method)).isCallable();
}

static QFileInfo lastOutput(const Controller &controller, const QString &name)
{
    if (controller.jobs().isEmpty())
        return {};
    const auto job = controller.jobs().constLast().toMap();
    if (job.value("state").toString() != QStringLiteral("完成"))
        return {};
    return QFileInfo(QDir(job.value("directory").toString()).filePath(name));
}

static bool runTask(Controller &controller, const std::function<bool()> &start)
{
    const auto count = controller.jobs().size();
    QEventLoop wait;
    QObject::connect(&controller, &Controller::jobsChanged, &wait, [&] {
        if (!controller.busy()) wait.quit();
    });
    QTimer::singleShot(8000, &wait, &QEventLoop::quit);
    if (!start())
        return false;
    if (controller.busy())
        wait.exec();
    return !controller.busy() && controller.jobs().size() == count + 1 &&
           controller.jobs().constLast().toMap().value("state") == QStringLiteral("完成");
}

static bool runSuggestedWorkflow(QQmlApplicationEngine &engine, QObject *root, Controller &controller,
                                 const QString &source, const QString &destination,
                                 const QList<QPair<QString, QVariantMap>> &steps)
{
    auto window = engine.newQObject(root);
    window.setProperty("inputs", engine.toScriptValue(QVariantList{source}));
    window.setProperty("steps", engine.toScriptValue(QVariantList{}));
    root->findChild<QObject *>("outputDirectory")->setProperty("text", destination);
    const auto suggestions = window.property("suggestions");
    for (const auto &[tool, params] : steps) {
        QJSValue spec;
        for (int index = 0; index < suggestions.property("length").toInt(); ++index) {
            const auto candidate = suggestions.property(index);
            if (candidate.property("id").toString() == tool) {
                spec = candidate;
                break;
            }
        }
        if (!spec.isObject() || !invokeQml(window, "chooseTool", {spec}))
            return false;
        for (auto parameter = params.cbegin(); parameter != params.cend(); ++parameter)
            if (!invokeQml(window, "setParam", {QJSValue(parameter.key()), engine.toScriptValue(parameter.value())}))
                return false;
        if (!invokeQml(window, "addStep"))
            return false;
    }
    QVariantMap preset{
        {"steps", window.property("steps").toVariant()},
        {"suffixes", QStringList{QFileInfo(source).suffix().toLower()}},
    };
    return window.property("workflowReady").toBool() && runTask(controller, [&] {
        return invokeQml(window, "runPreset", {engine.toScriptValue(preset)});
    });
}

static bool verifyPdfEdits(QQmlApplicationEngine &engine, QObject *root, Controller &controller,
                           const QString &source, const QString &destination)
{
    const QVariantMap firstPage{{"pages", "1"}};
    if (!runSuggestedWorkflow(engine, root, controller, source, destination,
                              {{"pdf.crop", firstPage}, {"pdf.number", firstPage}, {"pdf.watermark", firstPage}}))
        return false;
    const auto outputs = controller.resultItems(controller.jobs().size() - 1);
    return outputs.size() == 1 &&
           outputs.constFirst().toMap().value("path").toString().endsWith("-watermarked.pdf") &&
           outputs.constFirst().toMap().value("canOpen").toBool();
}

static bool verifySubtitles(QQmlApplicationEngine &engine, QObject *root, Controller &controller)
{
    QTemporaryDir directory;
    if (!directory.isValid())
        return false;
    QFile source(directory.filePath(QStringLiteral("中文字幕 样本.srt")));
    const auto original = QStringLiteral("1\n00:00:01,100 --> 00:00:02,800\n<b>测试字幕</b>\n\n").toUtf8();
    if (!source.open(QIODevice::WriteOnly) || source.write(original) != original.size())
        return false;
    source.close();
    if (!runSuggestedWorkflow(engine, root, controller, source.fileName(), directory.filePath("output"),
                              {{"subtitle.shift", {{"offset_ms", "-600"}}},
                               {"subtitle.convert", {{"format", "vtt"}}},
                               {"subtitle.transcript", {{"timestamps", true}}}}))
        return false;
    const auto outputs = controller.resultItems(controller.jobs().size() - 1);
    if (outputs.size() != 1)
        return false;
    const auto item = outputs.constFirst().toMap();
    QFile transcript(item.value("path").toString());
    return item.value("canOpen").toBool() && transcript.open(QIODevice::ReadOnly) &&
           transcript.readAll() == QStringLiteral("[00:00:00.500]\n测试字幕\n").toUtf8() &&
           source.open(QIODevice::ReadOnly) && source.readAll() == original;
}

static bool verifyFileTools(QQmlApplicationEngine &engine, QObject *root, Controller &controller,
                            const QString &source, const QDir &directory)
{
    auto window = engine.newQObject(root);
    const auto jobIndex = controller.jobs().size() - 1;
    const auto job = controller.jobs().at(jobIndex).toMap();
    const auto files = controller.resultItems(jobIndex);
    if (files.size() != 1) {
        qWarning("Compression result list does not contain one item.");
        return false;
    }
    const auto item = files.first().toMap();
    const auto path = item.value("path").toString();
    if (!item.value("canOpen").toBool() || item.value("original_bytes").toLongLong() != QFileInfo(source).size() ||
        item.value("target_bytes").toLongLong() != 97 * 1024 || !controller.useResults(jobIndex, {source}).isEmpty()) {
        qWarning("Compression result metadata or path validation failed.");
        return false;
    }

    auto results = engine.newQObject(root->findChild<QObject *>("taskResults"));
    if (!invokeQml(results, "showJob", {QJSValue(int(jobIndex)), QJSValue(job.value("directory").toString())}) ||
        !invokeQml(results, "choose", {QJSValue(path), QJSValue(true)}) ||
        !invokeQml(results, "useSelected") ||
        window.property("inputs").toVariant().toList() != QVariantList{path}) {
        qWarning("Task results could not be reused as input.");
        return false;
    }

    const QVariantList workflow = {
        QVariantMap{{"tool", "image.resize"}, {"params", QVariantMap{{"width", "160"}, {"height", "160"}}}},
        QVariantMap{{"tool", "image.compress"}, {"params", QVariantMap{{"target_kib", "97"}}}},
        QVariantMap{{"tool", "pdf.from_images"}, {"params", QVariantMap{}}},
    };
    const auto name = QStringLiteral("测试图片工作流");
    if (!controller.saveWorkflowPreset(name, workflow, {path}).isEmpty() ||
        controller.saveWorkflowPreset(name, workflow, {path}).isEmpty())
        return false;
    const auto saved = QSettings().value("tools/presets").toList();
    if (saved.size() != 1 || saved.first().toMap().value("steps").toList().size() != 3)
        return false;
    if (!runTask(controller, [&] {
        return invokeQml(window, "runPreset", {engine.toScriptValue(saved.first())});
    }) || !lastOutput(controller, "03/images.pdf").isFile() || !controller.removePreset(name).isEmpty()) {
        qWarning("Saved three-step workflow did not finish with a PDF.");
        return false;
    }

    auto rename = engine.newQObject(root->findChild<QObject *>("renamePreview"));
    QEventLoop wait;
    QObject::connect(&controller, &Controller::renamePreviewReady, &wait, &QEventLoop::quit);
    QTimer::singleShot(8000, &wait, &QEventLoop::quit);
    if (!invokeQml(rename, "showPreview", {engine.toScriptValue(QVariantList{path, source}),
                   engine.toScriptValue(QVariantMap{{"prefix", "new-"}, {"start", "8"}, {"digits", "2"}}),
                   QJSValue(directory.filePath("rename"))}))
        return false;
    if (controller.inspecting())
        wait.exec();
    const auto rows = rename.property("rows").toVariant().toList();
    if (!rename.property("applicable").toBool() || rows.size() != 2 ||
        rows.first().toMap().value("name") != "new-08.jpg" || rows.last().toMap().value("name") != "new-09.png") {
        qWarning("Rename preview did not preserve the supplied order.");
        return false;
    }
    return runTask(controller, [&] { return invokeQml(rename, "submitPreview"); }) &&
           lastOutput(controller, "new-08.jpg").isFile() && lastOutput(controller, "new-09.png").isFile() &&
           QFileInfo(source).isFile() && QFileInfo(path).isFile();
}

static bool verifyWorkbench(QQmlApplicationEngine &engine, QObject *root, Controller &controller)
{
    QTemporaryDir files;
    if (!files.isValid())
        return false;
    const auto pdfPath = files.filePath(QStringLiteral("样本 A.pdf"));
    const auto imagePath = files.filePath(QStringLiteral("插页 B.png"));
    {
        QPdfWriter pdf(pdfPath);
        QPainter painter(&pdf);
        if (!painter.isActive())
            return false;
        painter.drawText(100, 200, "First page");
        if (!pdf.newPage())
            return false;
        painter.drawText(100, 200, "Second page");
    }
    QImage image(320, 240, QImage::Format_RGB32);
    image.fill(Qt::red);
    if (!image.save(imagePath))
        return false;

    auto window = engine.newQObject(root);
    const auto urls = QVariantList{QUrl::fromLocalFile(pdfPath), QUrl::fromLocalFile(imagePath)};
    window.setProperty("inputs", engine.toScriptValue(QVariantList{}));
    if (!invokeQml(window, "addUrls", {engine.toScriptValue(urls)}) ||
        window.property("suggestions").property(0).property("id").toString() != "pdf.compose")
        return false;

    QEventLoop wait;
    auto completed = QObject::connect(&controller, &Controller::pdfPreviewReady, &wait, &QEventLoop::quit);
    QTimer::singleShot(6000, &wait, &QEventLoop::quit);
    if (!invokeQml(window, "openWorkbench"))
        return false;
    if (controller.inspecting())
        wait.exec();
    QObject::disconnect(completed);

    auto panel = engine.newQObject(root->findChild<QObject *>("pdfWorkbench"));
    if (panel.property("pages").property("length").toInt() != 3 ||
        !invokeQml(panel, "movePage", {QJSValue(2), QJSValue(0)}) ||
        !invokeQml(panel, "rotatePage") ||
        panel.property("pages").property(0).property("rotation").toInt() != 90 ||
        !invokeQml(panel, "movePage", {QJSValue(2), QJSValue(1)}) ||
        !invokeQml(panel, "removePage") ||
        panel.property("pages").property("length").toInt() != 2)
        return false;

    panel.setProperty("outputDirectory", files.filePath("results"));
    QEventLoop exportWait;
    QObject::connect(&controller, &Controller::jobsChanged, &exportWait, [&] {
        if (!controller.busy()) exportWait.quit();
    });
    QTimer::singleShot(7000, &exportWait, &QEventLoop::quit);
    if (!invokeQml(panel, "exportPdf"))
        return false;
    if (controller.busy())
        exportWait.exec();
    if (!lastOutput(controller, "workbench.pdf").isFile())
        return false;

    QEventLoop previewWait;
    QObject::connect(&controller, &Controller::pdfCompressionReady, &previewWait, &QEventLoop::quit);
    QTimer::singleShot(8000, &previewWait, &QEventLoop::quit);
    if (!invokeQml(panel, "open") || !invokeQml(panel, "previewCompression", {QJSValue(1)}))
        return false;
    if (controller.inspecting())
        previewWait.exec();
    const auto preview = panel.property("compression");
    const auto bytes = preview.property("size").toInt();
    const QUrl original = preview.property("before").toVariant().toUrl();
    const QUrl optimized = preview.property("after").toVariant().toUrl();
    if (bytes <= 0 || !QFileInfo(original.toLocalFile()).isFile() || !QFileInfo(optimized.toLocalFile()).isFile() ||
        preview.property("met").toBool() != (bytes <= 1024) || !invokeQml(panel, "saveCompression") ||
        lastOutput(controller, "workbench.pdf").size() != bytes)
        return false;

    if (!verifyPdfEdits(engine, root, controller, pdfPath, files.filePath("pdf-edits"))) {
        qWarning("PDF editing tools did not complete from the desktop workflow.");
        return false;
    }
    window.setProperty("inputs", engine.toScriptValue(QVariantList{imagePath}));
    const auto presets = window.property("matchingPresets");
    auto photo = presets.property(0);
    if (photo.property("tool").toString() != "image.compress")
        return false;
    root->findChild<QObject *>("outputDirectory")->setProperty("text", files.filePath("preset-output"));
    const QString presetName = QStringLiteral("测试自定义预设");
    if (!controller.savePreset(presetName, "image.compress", {{"target_kib", "40"}}, {imagePath}).isEmpty())
        return false;
    const auto saved = QSettings().value("tools/presets").toList();
    if (saved.size() != 1 || saved.constFirst().toMap().value("params").toMap().value("target_kib") != "40" ||
        controller.savePreset(presetName, "image.compress", {}, {imagePath}).isEmpty() ||
        controller.savePreset("password", "pdf.encrypt", {{"password", "dummy"}}, {pdfPath}).isEmpty() ||
        !controller.removePreset(presetName).isEmpty() || !QSettings().value("tools/presets").toList().isEmpty())
        return false;
    QEventLoop presetWait;
    QObject::connect(&controller, &Controller::jobsChanged, &presetWait, [&] {
        if (!controller.busy()) presetWait.quit();
    });
    QTimer::singleShot(7000, &presetWait, &QEventLoop::quit);
    if (!invokeQml(window, "runPreset", {photo}))
        return false;
    if (controller.busy())
        presetWait.exec();
    const auto outputs = QDir(controller.jobs().constLast().toMap().value("directory").toString())
                             .entryInfoList({"*.jpg"}, QDir::Files);
    return outputs.size() == 1 && outputs.first().size() > 0 && outputs.first().size() <= 100000 &&
           verifyFileTools(engine, root, controller, imagePath, QDir(files.path()));
}

static bool verifyEngineControls(QQmlApplicationEngine &engine, QObject *root, Controller &controller)
{
    const auto *button = root->findChild<QObject *>("engineSettingsButton");
    auto *settings = root->findChild<QObject *>("engineSettings");
    if (!button || button->property("visible").toBool() == controller.hasBundledEngines())
        return false;
    if (!controller.hasBundledEngines()) {
        const auto dialog = engine.newQObject(settings);
        return invokeQml(dialog, "open") && invokeQml(dialog, "close");
    }
    if (settings)
        return false;

    QStringList available = {"video.frames", "image.ocr", "doc.pdf"};
    for (const auto &entry : controller.tools()) {
        const auto tool = entry.toMap();
        if (tool.value("missing_engines").toList().isEmpty())
            available.removeAll(tool.value("id").toString());
    }
    if (!available.isEmpty()) {
        qWarning().noquote() << "Bundled tools unavailable:" << available.join(", ");
        return false;
    }
    qInfo("Bundled engine settings hidden and all three engine categories available.");
    return true;
}

static bool verifyToolNavigation(QJSValue window, QObject *root, const QVariantList &tools)
{
    const auto showCategory = [&](const QString &category) {
        return invokeQml(window, "showCategory", {QJSValue(category)});
    };
    const auto visibleIds = [&] {
        QStringList ids;
        for (const auto &tool : window.property("visibleTools").toVariant().toList())
            ids.append(tool.toMap().value("id").toString());
        return ids;
    };
    auto *search = root->findChild<QObject *>("toolSearch");
    const auto *workflowToggle = root->findChild<QObject *>("workflowToggle");
    const auto featured = visibleIds();
    if (!search || !workflowToggle || window.property("category").toString() != QStringLiteral("常用") ||
        window.property("workflowExpanded").toBool() || window.property("taskCenterExpanded").toBool() ||
        featured.size() != 12 || featured.first() != "doc.pdf" ||
        QSet<QString>(featured.cbegin(), featured.cend()).size() != featured.size())
        return false;

    if (!showCategory(QStringLiteral("文档与数据")) || !visibleIds().contains("data.json") ||
        !showCategory(QStringLiteral("文件与隐私")) || !visibleIds().contains("file.rename") ||
        !visibleIds().contains("privacy.encrypt") || !showCategory(QStringLiteral("音频")) ||
        !visibleIds().contains("audio.convert") || visibleIds().contains("pdf.ocr"))
        return false;

    search->setProperty("text", " PDF.OCR ");
    if (visibleIds() != QStringList{"pdf.ocr"} || !showCategory(QStringLiteral("全部工具")) ||
        !search->property("text").toString().isEmpty() || visibleIds().size() != tools.size())
        return false;

    const auto theme = window.property("themeMode");
    window.setProperty("themeMode", "dark");
    const bool darkButton = workflowToggle->property("dark").toBool();
    window.setProperty("themeMode", "light");
    const bool lightButton = !workflowToggle->property("dark").toBool();
    window.setProperty("themeMode", theme);
    return darkButton && lightButton && showCategory(QStringLiteral("常用")) && visibleIds() == featured;
}

static bool verifyButtonReflection(QObject *root)
{
    const auto *button = root->findChild<QQuickItem *>("workflowToggle");
    const auto *reflection = button ? button->findChild<QQuickItem *>("buttonReflection") : nullptr;
    if (!reflection || !button->window() || button->width() < 40)
        return false;

    const auto moveOverButton = [button](qreal fraction) {
        auto *window = button->window();
        const auto local = button->mapToScene({button->width() * fraction, button->height() / 2});
        QMouseEvent move(QEvent::MouseMove, local, window->mapToGlobal(local),
                         Qt::NoButton, Qt::NoButton, Qt::NoModifier);
        QCoreApplication::sendEvent(window, &move);
    };
    moveOverButton(0.2);
    const auto left = reflection->property("position").toPointF();
    moveOverButton(0.8);
    const auto right = reflection->property("position").toPointF();
    return button->property("lit").toBool() && right.x() - left.x() > button->width() / 2;
}

static bool verifyDesktop(QQmlApplicationEngine &engine, QObject *root, Controller &controller)
{
    const auto tools = controller.tools();
    const auto findTool = [&](const QString &id) {
        for (const auto &tool : tools) {
            const auto spec = tool.toMap();
            if (spec.value("id").toString() == id)
                return spec;
        }
        return QVariantMap{};
    };
    const auto converter = findTool(QStringLiteral("image.convert"));
    const auto compare = findTool(QStringLiteral("text.diff"));
    if (converter.isEmpty() || compare.isEmpty())
        return false;
    if (!verifyEngineControls(engine, root, controller)) {
        qWarning("Engine controls or bundled engine verification failed.");
        return false;
    }

    auto window = engine.newQObject(root);
#ifdef Q_OS_WIN
    if (!window.property("immersiveFrame").toBool() || !verifyWindowFrame(*qobject_cast<QQuickWindow *>(root))) {
        qWarning("Immersive window frame verification failed.");
        return false;
    }
#endif
    if (!verifyToolNavigation(window, root, tools)) {
        qWarning("Tool navigation, search, or button theme verification failed.");
        return false;
    }
    if (!verifyButtonReflection(root)) {
        qWarning("The button reflection did not follow the pointer.");
        return false;
    }
    const auto call = [&](const char *method, const QJSValueList &arguments = {}) {
        return invokeQml(window, method, arguments);
    };
    const auto imageTool = engine.toScriptValue(converter);
    if (!call("chooseTool", {imageTool}) ||
        !call("setParam", {QJSValue(QStringLiteral("format")), QJSValue(QStringLiteral("webp"))}) ||
        !call("chooseTool", {imageTool}) ||
        window.property("params").property("format").toString() != QStringLiteral("webp"))
        return false;

    window.setProperty("inputs", engine.toScriptValue(QVariantList{QStringLiteral("one.txt")}));
    if (!call("chooseTool", {engine.toScriptValue(compare)}) || !call("addStep") ||
        window.property("workflowReady").toBool() || !window.property("workflowExpanded").toBool())
        return false;

    window.setProperty("inputs", engine.toScriptValue(
        QVariantList{QStringLiteral("one.txt"), QStringLiteral("two.txt")}));
    const bool ready = window.property("workflowReady").toBool() &&
                       verifyWorkbench(engine, root, controller) && verifySubtitles(engine, root, controller);
    if (ready)
        qInfo("Desktop checks passed: featured tools, grouped navigation, global search, button themes, PDF editing, task results, rename preview, workflows, and subtitles.");
    return ready;
}

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    app.setOrganizationName("FormaBox");
    app.setApplicationName("FormaBox");
    app.setApplicationDisplayName(QStringLiteral("万象"));
    app.setApplicationVersion(QStringLiteral(FORMABOX_VERSION));
    app.setWindowIcon(QIcon(QStringLiteral(":/branding/formabox.png")));
    QQuickStyle::setStyle("Fusion");

    auto arguments = app.arguments();
    const bool verifyImport = arguments.removeAll("--verify-send-to") > 0;
    const auto sendTo = arguments.indexOf("--send-to");
    const auto options = sendTo < 0 ? arguments : arguments.first(sendTo);
    const bool verify = verifyImport || options.contains("--verify-runtime");
    QVariantList launchedFiles;
    if (sendTo >= 0) {
        for (const auto &path : arguments.sliced(sendTo + 1)) {
            const QFileInfo file(path);
            if (file.isAbsolute() && (file.isFile() || file.isDir()) && !file.isSymLink() &&
                !launchedFiles.contains(file.absoluteFilePath()))
                launchedFiles.append(file.absoluteFilePath());
        }
    }
    std::unique_ptr<QTemporaryDir> verificationSettings;
    if (verify) {
        verificationSettings = std::make_unique<QTemporaryDir>();
        if (!verificationSettings->isValid())
            return 2;
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, verificationSettings->path());
    }
    Controller controller;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("backend", &controller);
    engine.rootContext()->setContextProperty("launchFiles", launchedFiles);
#ifdef Q_OS_WIN
    engine.rootContext()->setContextProperty("windowsFrameSupported", true);
#else
    engine.rootContext()->setContextProperty("windowsFrameSupported", false);
#endif
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("FormaBox", "Main");
    if (!engine.rootObjects().isEmpty()) {
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
#ifdef Q_OS_WIN
        window->setProperty("immersiveFrame", installWindowFrame(*window));
#endif
        window->show();
    }

    bool verificationStarted = false;
    if (verify) {
        const auto exitWhenReady = [&] {
            if (verificationStarted || engine.rootObjects().isEmpty() || controller.tools().isEmpty())
                return;
            verificationStarted = true;
            auto *root = engine.rootObjects().constFirst();
            const bool checkImport = verifyImport || sendTo >= 0;
            const bool launchPassed = !checkImport ||
                (sendTo >= 0 && !launchedFiles.isEmpty() &&
                 (!verifyImport || launchedFiles.size() == 2) &&
                 launchedFiles.size() == arguments.size() - sendTo - 1 &&
                 engine.newQObject(root).property("inputs").toVariant().toList() == launchedFiles);
            if (!launchPassed)
                qWarning("Send To file import verification failed.");
            const bool passed = launchPassed && verifyDesktop(engine, root, controller);
            if (!passed)
                qWarning("Desktop regression checks failed.");
            app.exit(passed ? 0 : 3);
        };
        // Give the header and its native hit targets a layout pass before testing.
        const auto scheduleVerification = [&app, exitWhenReady] { QTimer::singleShot(100, &app, exitWhenReady); };
        QObject::connect(&controller, &Controller::toolsChanged, &app, scheduleVerification);
        scheduleVerification();
        QTimer::singleShot(45'000, &app, [&] { app.exit(2); });
    }
    return app.exec();
}
