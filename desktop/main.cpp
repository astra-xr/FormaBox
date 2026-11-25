#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QTimer>
#include "controller.h"

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
            if (!engine.rootObjects().isEmpty() && !controller.tools().isEmpty())
                app.exit(0);
        };
        QObject::connect(&controller, &Controller::toolsChanged, &app, exitWhenReady);
        QTimer::singleShot(0, &app, exitWhenReady);
        QTimer::singleShot(20'000, &app, [&] { app.exit(2); });
    }
    return app.exec();
}