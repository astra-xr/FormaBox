#include "workerprocess.h"

#ifdef Q_OS_WIN
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

struct WorkerProcess::WindowsJob {
    HANDLE handle = nullptr;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = nullptr;
    STARTUPINFOEXW startup{};

    ~WindowsJob()
    {
        if (attributes) {
            DeleteProcThreadAttributeList(attributes);
            HeapFree(GetProcessHeap(), 0, attributes);
        }
        if (handle)
            CloseHandle(handle);
    }

    bool initialize()
    {
        handle = CreateJobObjectW(nullptr, nullptr);
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!handle || !SetInformationJobObject(handle, JobObjectExtendedLimitInformation,
                                                &limits, sizeof(limits)))
            return false;

        SIZE_T size = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
        auto *memory = static_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(HeapAlloc(GetProcessHeap(), 0, size));
        if (!memory) {
            SetLastError(ERROR_OUTOFMEMORY);
            return false;
        }
        if (!InitializeProcThreadAttributeList(memory, 1, 0, &size)) {
            const auto error = GetLastError();
            HeapFree(GetProcessHeap(), 0, memory);
            SetLastError(error);
            return false;
        }
        attributes = memory;
        return UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                         &handle, sizeof(handle), nullptr, nullptr);
    }
};
#endif

WorkerProcess::WorkerProcess()
{
#ifdef Q_OS_WIN
    connect(this, &QProcess::finished, this, [this] { m_job.reset(); });
    connect(this, &QProcess::errorOccurred, this, [this](ProcessError error) {
        if (error == FailedToStart)
            m_job.reset();
    });
    setCreateProcessArgumentsModifier([this](CreateProcessArguments *args) {
        // QProcess prepares the child pipes. Preserve them and add atomic Job Object assignment.
        auto &info = m_job->startup;
        info.StartupInfo = *args->startupInfo;
        info.StartupInfo.cb = sizeof(info);
        info.lpAttributeList = m_job->attributes;
        args->startupInfo = &info.StartupInfo;
        args->flags |= EXTENDED_STARTUPINFO_PRESENT;
    });
#endif
}

WorkerProcess::~WorkerProcess()
{
    stop();
}

void WorkerProcess::startManaged()
{
    if (state() != NotRunning)
        return;
    if (program().isEmpty()) {
        setErrorString(QStringLiteral("未找到 Python 工作进程"));
        emit errorOccurred(FailedToStart);
        return;
    }
#ifdef Q_OS_WIN
    m_job = std::make_unique<WindowsJob>();
    if (!m_job->initialize()) {
        const auto code = GetLastError();
        setErrorString(QStringLiteral("无法建立工作进程组（Windows 错误 %1）").arg(code));
        emit errorOccurred(FailedToStart);
        return;
    }
#endif
    start();
}

void WorkerProcess::killTree()
{
#ifdef Q_OS_WIN
    if (m_job) {
        m_job.reset();
        return;
    }
#endif
    if (state() != NotRunning)
        kill();
}

void WorkerProcess::stop()
{
    killTree();
    if (state() != NotRunning)
        waitForFinished();
}
