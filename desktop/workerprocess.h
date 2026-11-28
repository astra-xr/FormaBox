#pragma once

#include <QProcess>
#include <memory>

class WorkerProcess final : public QProcess {
public:
    WorkerProcess();
    ~WorkerProcess() override;

    void startManaged();
    void killTree();
    void stop();
private:
#ifdef Q_OS_WIN
    struct WindowsJob;
    std::unique_ptr<WindowsJob> m_job;
#endif
};
