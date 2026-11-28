#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <set>
#include <string>
#include <system_error>
#include <vector>

namespace {
namespace fs = std::filesystem;
constexpr char ownership[] = "Omnora installer transaction 1";
constexpr wchar_t uninstallKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\FormaBox";

enum class Kind { Missing, File, Directory };

Kind kind(const fs::path &path)
{
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        const DWORD code = GetLastError();
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND)
            return Kind::Missing;
        throw std::system_error(code, std::system_category());
    }
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT)
        throw std::runtime_error("Installer paths must not contain reparse points");
    return attributes & FILE_ATTRIBUTE_DIRECTORY ? Kind::Directory : Kind::File;
}

Kind checked(const fs::path &root, const fs::path &relative)
{
    auto path = root;
    for (const auto &part : relative) {
        if (part.empty() || part == "." || part == ".." || part.native().find(L':') != std::wstring::npos)
            throw std::runtime_error("Invalid installation file name");
        path /= part;
        kind(path);
    }
    return kind(path);
}

void move(const fs::path &source, const fs::path &target, DWORD flags = 0)
{
    if (!MoveFileExW(source.c_str(), target.c_str(), flags | MOVEFILE_WRITE_THROUGH))
        throw std::system_error(GetLastError(), std::system_category());
}

void record(const fs::path &path, const std::string &bytes)
{
    const auto partial = path.native() + L".tmp";
    const auto file = CreateFileW(partial.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        throw std::system_error(GetLastError(), std::system_category());
    DWORD written = 0;
    const bool saved = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) &&
                       FlushFileBuffers(file);
    const DWORD error = saved ? ERROR_WRITE_FAULT : GetLastError();
    CloseHandle(file);
    if (!saved || written != bytes.size())
        throw std::system_error(error, std::system_category());
    move(partial, path, MOVEFILE_REPLACE_EXISTING);
}

std::string read(const fs::path &path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
        throw std::runtime_error("Cannot read the installation journal");
    return {std::istreambuf_iterator<char>(input), {}};
}

struct FileChange {
    fs::path relative;
    bool existed;
};

class Transaction {
public:
    explicit Transaction(fs::path root)
        : root(std::move(root)), staging(this->root / L".omnora-setup"),
          payload(staging / L"payload"), backup(staging / L"backup")
    {
        if (!this->root.is_absolute() || this->root == this->root.root_path() ||
            this->root.native().starts_with(L"\\\\"))
            throw std::runtime_error("The installation location must be a local directory");
        checked(this->root.root_path(), this->root.relative_path());
    }

    void prepare(const std::string &previousVersion)
    {
        if (kind(staging) != Kind::Missing)
            recover();
        fs::create_directories(staging);
        record(staging / "owner", ownership);
        record(staging / "previous-version", previousVersion);
        fs::create_directory(payload);
    }

    void apply()
    {
        checkStage();
        if (kind(payload / "Omnora.exe") != Kind::File || kind(payload / "Uninstall.exe") != Kind::File)
            throw std::runtime_error("Incomplete installer payload");

        std::vector<FileChange> files;
        std::set<fs::path> newDirectories;
        for (const auto &entry : fs::recursive_directory_iterator(payload)) {
            if (kind(entry.path()) != Kind::File)
                continue;
            auto relative = entry.path().lexically_relative(payload);
            const auto original = checked(root, relative);
            if (original == Kind::Directory || *relative.begin() == L".omnora-setup")
                throw std::runtime_error("The install destination contains a conflicting directory");
            for (auto parent = relative.parent_path(); !parent.empty(); parent = parent.parent_path()) {
                if (kind(root / parent) != Kind::Missing)
                    break;
                newDirectories.insert(parent);
            }
            files.push_back({std::move(relative), original == Kind::File});
        }
        std::sort(files.begin(), files.end(), [](const auto &left, const auto &right) {
            return left.relative < right.relative;
        });
        std::string journal;
        for (const auto &file : files) {
            const auto path = file.relative.generic_u8string();
            journal += file.existed ? "1 " : "0 ";
            journal.append(path.begin(), path.end());
            journal += '\n';
        }
        std::string directories;
        for (const auto &directory : newDirectories) {
            const auto path = directory.generic_u8string();
            directories.append(path.begin(), path.end());
            directories += '\n';
        }
        record(staging / "directories", directories);
        record(staging / "files", journal);

        for (const auto &file : files) {
            const auto destination = root / file.relative;
            if (file.existed) {
                const auto saved = backup / file.relative;
                fs::create_directories(saved.parent_path());
                move(destination, saved);
            } else {
                fs::create_directories(destination.parent_path());
            }
            move(payload / file.relative, destination);
        }
    }

    void accept()
    {
        checkStage();
        record(staging / "accepted", ownership);
        // The journal is already committed, so cleanup can be retried on the next install.
        try {
            cleanup();
        } catch (const std::exception &) {
        }
    }

    void recover()
    {
        if (kind(staging) == Kind::Missing)
            return;
        if (kind(staging) == Kind::Directory && fs::is_empty(staging)) {
            fs::remove(staging);
            return;
        }
        checkStage();
        if (kind(staging / "accepted") == Kind::Missing && kind(staging / "files") == Kind::File) {
            std::vector<FileChange> files;
            std::ifstream journal(staging / "files", std::ios::binary);
            if (!journal)
                throw std::runtime_error("Cannot open the installation journal");
            for (std::string line; std::getline(journal, line);) {
                if (line.size() < 3 || line[1] != ' ' || (line[0] != '0' && line[0] != '1'))
                    throw std::runtime_error("Invalid installation journal");
                fs::path relative(std::u8string(line.begin() + 2, line.end()));
                if (relative.has_root_path() || *relative.begin() == L".omnora-setup")
                    throw std::runtime_error("Invalid installation journal path");
                checked(root, relative);
                files.push_back({std::move(relative), line[0] == '1'});
            }
            for (auto file = files.rbegin(); file != files.rend(); ++file) {
                const auto target = root / file->relative;
                const auto saved = backup / file->relative;
                if (kind(saved) == Kind::File) {
                    move(saved, target, MOVEFILE_REPLACE_EXISTING);
                } else if (!file->existed && kind(payload / file->relative) == Kind::Missing &&
                           kind(target) == Kind::File) {
                    fs::remove(target);
                }
            }
            std::vector<fs::path> directories;
            std::ifstream journalDirectories(staging / "directories", std::ios::binary);
            for (std::string line; std::getline(journalDirectories, line);) {
                fs::path relative(std::u8string(line.begin(), line.end()));
                if (relative.empty() || relative.has_root_path() || *relative.begin() == L".omnora-setup")
                    throw std::runtime_error("Invalid installation journal directory");
                checked(root, relative);
                directories.push_back(root / relative);
            }
            for (auto it = directories.rbegin(); it != directories.rend(); ++it)
                RemoveDirectoryW(it->c_str());
            restoreRegisteredVersion();
            record(staging / "accepted", ownership);
        }
        cleanup();
    }

private:
    void cleanup() const
    {
        fs::remove_all(payload);
        fs::remove_all(backup);
        for (const auto &entry : fs::directory_iterator(staging)) {
            if (entry.path().filename() != "owner" && entry.path().filename() != "accepted")
                fs::remove(entry.path());
        }
        fs::remove(staging / "accepted");
        fs::remove(staging / "owner");
        fs::remove(staging);
    }

    void checkStage() const
    {
        if (kind(staging) != Kind::Directory || kind(staging / "owner") != Kind::File ||
            read(staging / "owner") != ownership)
            throw std::runtime_error("The installation staging directory is not owned by Omnora");
        for (const auto &entry : fs::recursive_directory_iterator(staging))
            kind(entry.path());
    }

    void restoreRegisteredVersion() const
    {
        wchar_t location[32768]{};
        DWORD size = sizeof(location);
        if (RegGetValueW(HKEY_CURRENT_USER, uninstallKey, L"InstallLocation", RRF_RT_REG_SZ,
                         nullptr, location, &size) != ERROR_SUCCESS ||
            CompareStringOrdinal(root.c_str(), -1, location, -1, TRUE) != CSTR_EQUAL)
            return;

        const auto previous = read(staging / "previous-version");
        if (previous.empty()) {
            RegDeleteTreeW(HKEY_CURRENT_USER, uninstallKey);
            return;
        }
        HKEY key = nullptr;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, uninstallKey, 0, KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
            const std::wstring version(previous.begin(), previous.end());
            RegSetValueExW(key, L"DisplayVersion", 0, REG_SZ, reinterpret_cast<const BYTE *>(version.c_str()),
                           static_cast<DWORD>((version.size() + 1) * sizeof(wchar_t)));
            RegCloseKey(key);
        }
    }

    const fs::path root;
    const fs::path staging;
    const fs::path payload;
    const fs::path backup;
};
}

int wmain(int argc, wchar_t **argv)
{
    try {
        if (argc != 4)
            return 2;
        Transaction transaction(fs::path(argv[2]).lexically_normal());
        const std::wstring action(argv[1]);
        if (action == L"prepare") {
            const std::wstring version(argv[3]);
            if (version.find_first_not_of(L"0123456789.") != std::wstring::npos)
                return 2;
            std::string previousVersion;
            for (const wchar_t character : version)
                previousVersion.push_back(static_cast<char>(character));
            transaction.prepare(previousVersion);
        } else if (action == L"apply") {
            transaction.apply();
        } else if (action == L"accept") {
            transaction.accept();
        } else if (action == L"recover") {
            transaction.recover();
        } else {
            return 2;
        }
        return 0;
    } catch (const std::system_error &error) {
        const int code = error.code().value();
        return code > 0 ? code : 1;
    } catch (const std::exception &) {
        return 1;
    }
}
