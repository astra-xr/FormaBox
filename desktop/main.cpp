#include <QDebug>
#include <QDir>
#include <QEventLoop>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QImage>
#include <QJSValue>
#include <QPainter>
#include <QPdfWriter>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QSettings>
#include <QTimer>
#include "controller.h"

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
    const auto settings = engine.newQObject(root->findChild<QObject *>("engineSettings"));
    if (!invokeQml(settings, "open") || !invokeQml(settings, "close"))
        return false;
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
    return outputs.size() == 1 && outputs.first().size() > 0 && outputs.first().size() <= 100000;
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

    auto window = engine.newQObject(root);
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
        window.property("workflowReady").toBool())
        return false;

    window.setProperty("inputs", engine.toScriptValue(
        QVariantList{QStringLiteral("one.txt"), QStringLiteral("two.txt")}));
    const bool ready = window.property("workflowReady").toBool() && verifyWorkbench(engine, root, controller);
    if (ready)
        qInfo("Desktop checks passed: task controls, PDF preview and export, size comparison, and quick presets.");
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

    const bool verify = app.arguments().contains("--verify-runtime");
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
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("FormaBox", "Main");

    bool verificationStarted = false;
    if (verify) {
        const auto exitWhenReady = [&] {
            if (verificationStarted || engine.rootObjects().isEmpty() || controller.tools().isEmpty())
                return;
            verificationStarted = true;
            const bool passed = verifyDesktop(engine, engine.rootObjects().constFirst(), controller);
            if (!passed)
                qWarning("Desktop regression checks failed.");
            app.exit(passed ? 0 : 3);
        };
        QObject::connect(&controller, &Controller::toolsChanged, &app, exitWhenReady);
        QTimer::singleShot(0, &app, exitWhenReady);
        QTimer::singleShot(30'000, &app, [&] { app.exit(2); });
    }
    return app.exec();
}
