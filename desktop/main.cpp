#include <QDebug>
#include <QGuiApplication>
#include <QJSValue>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QTimer>
#include "controller.h"

static bool verifyDesktop(QQmlApplicationEngine &engine, QObject *root, const QVariantList &tools)
{
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
        const auto result = window.property(QString::fromLatin1(method)).callWithInstance(window, arguments);
        if (result.isError())
            qWarning().noquote() << result.toString();
        return !result.isError();
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
    const bool ready = window.property("workflowReady").toBool();
    if (ready)
        qInfo("Desktop checks passed: edited tool parameters and workflow input validation.");
    return ready;
}

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    app.setOrganizationName("FormaBox");
    app.setApplicationName("FormaBox");
    app.setApplicationDisplayName(QStringLiteral("万象"));
    app.setApplicationVersion(QStringLiteral(FORMABOX_VERSION));
    QQuickStyle::setStyle("Fusion");

    Controller controller;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("backend", &controller);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("FormaBox", "Main");

    if (app.arguments().contains("--verify-runtime")) {
        const auto exitWhenReady = [&] {
            if (engine.rootObjects().isEmpty() || controller.tools().isEmpty())
                return;
            const bool passed = verifyDesktop(engine, engine.rootObjects().constFirst(), controller.tools());
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