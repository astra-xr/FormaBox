#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <filesystem>
#include <string>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR arguments, int)
{
    std::wstring module(32768, L'\0');
    const auto length = GetModuleFileNameW(nullptr, module.data(), static_cast<DWORD>(module.size()));
    if (length == 0 || length >= module.size()) {
        MessageBoxW(nullptr, L"无法确定万象启动器所在的目录。", L"万象", MB_OK | MB_ICONERROR);
        return 1;
    }
    module.resize(length);

    const auto directory = std::filesystem::path(module).parent_path() / L"dist";
    const auto executable = directory / L"FormaBox.exe";
    const auto attributes = GetFileAttributesW(executable.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        const auto message = L"找不到万象的应用程序：\n" + executable.native() +
                             L"\n\n请将启动器留在项目根目录，并运行 scripts\\build-windows.ps1 生成 dist 目录。";
        MessageBoxW(nullptr, message.c_str(), L"万象", MB_OK | MB_ICONERROR);
        return 1;
    }

    auto command = L"\"" + executable.native() + L"\" " + arguments;
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
                        nullptr, directory.c_str(), &startup, &process)) {
        const auto message = L"万象无法启动。Windows 错误代码：" + std::to_wstring(GetLastError());
        MessageBoxW(nullptr, message.c_str(), L"万象", MB_OK | MB_ICONERROR);
        return 1;
    }

    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess);
    return static_cast<int>(exitCode);
}
