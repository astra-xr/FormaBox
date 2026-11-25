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
    if (controller.jobs().isEmpty())
        return false;
    const auto job = controller.jobs().constLast().toMap();
    return job.value("state").toString() == QStringLiteral("完成") &&
           QFileInfo(QDir(job.value("directory").toString()).filePath("workbench.pdf")).isFile();
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
        qInfo("Desktop checks passed: tool parameters, workflow validation, suggestions, PDF preview and export.");
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
        QTimer::singleShot(20'000, &app, [&] { app.exit(2); });
    }
    return app.exec();
}
