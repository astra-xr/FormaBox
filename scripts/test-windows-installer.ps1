[CmdletBinding()]
param([Parameter(Mandatory)][string]$Setup, [switch]$ExpectBundledEngines)

$ErrorActionPreference = 'Stop'
$setupPath = (Resolve-Path -LiteralPath $Setup).Path
$registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FormaBox'
if (Test-Path -LiteralPath $registry) {
    throw 'Run this test under a Windows account without an existing FormaBox installation'
}

function Invoke-CheckedProcess([string]$File, [string]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode) { throw "$File exited with code $($process.ExitCode)" }
}

$testRoot = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP "FormaBox-$([guid]::NewGuid())")).FullName
$target = Join-Path $testRoot '万象 安装'
$uninstaller = Join-Path $target 'Uninstall.exe'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) '万象.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) '万象.lnk'
$sendToShortcut = Join-Path ([Environment]::GetFolderPath('SendTo')) '万象（FormaBox）.lnk'
$quickOffice = Join-Path ([Environment]::GetFolderPath('SendTo')) '万象 - Office 转 PDF.lnk'
$quickPhoto = Join-Path ([Environment]::GetFolderPath('SendTo')) '万象 - 图片压缩到 100 KiB.lnk'

try {
    Invoke-CheckedProcess $setupPath "/S /D=$target"
    if (!(Test-Path -LiteralPath $uninstaller) -or !(Test-Path -LiteralPath $shortcut) -or
        !(Test-Path -LiteralPath $desktopShortcut) -or !(Test-Path -LiteralPath $sendToShortcut) -or
        !(Test-Path -LiteralPath $quickOffice) -or !(Test-Path -LiteralPath $quickPhoto) -or
        (Get-ItemProperty -LiteralPath $registry).InstallLocation -ne $target) {
        throw 'Installation files, shortcuts, or uninstall registration are missing'
    }

    $previousPath = $env:Path
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    Remove-Item Env:PYTHONHOME,Env:PYTHONPATH,Env:FORMABOX_PYTHON,Env:FORMABOX_WORKER_DIR,Env:QT_PLUGIN_PATH,Env:QML2_IMPORT_PATH,Env:QML_IMPORT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:FORMABOX_FFMPEG,Env:FORMABOX_TESSERACT,Env:FORMABOX_SOFFICE,Env:FORMABOX_WHISPER,Env:TESSDATA_PREFIX -ErrorAction SilentlyContinue
    $env:QT_QPA_PLATFORM = 'windows'
    $env:QT_QUICK_BACKEND = 'software'
    $env:QT_FORCE_STDERR_LOGGING = '1'
    $env:PYTHONUTF8 = '1'

    $python = Join-Path $target 'python/python.exe'
    if ($ExpectBundledEngines) {
        $json = & $python -X utf8 -B -m formabox check-engines
        if ($LASTEXITCODE) { throw 'Installed engine diagnostics failed' }
        $checks = ($json | ConvertFrom-Json).result
        $engineFiles = @{
            ffmpeg = 'engines/ffmpeg/ffmpeg.exe'
            tesseract = 'engines/tesseract/tesseract.exe'
            LibreOffice = 'engines/libreoffice/program/soffice.com'
        }
        foreach ($engine in $engineFiles.Keys) {
            $expected = (Resolve-Path -LiteralPath (Join-Path $target $engineFiles[$engine])).Path
            if (!$checks.$engine.ok -or [IO.Path]::GetFullPath($checks.$engine.path) -ne $expected) {
                throw "Built-in ${engine} did not pass: $($checks.$engine.message)"
            }
            Write-Host "Installed ${engine}: $($checks.$engine.message)"
        }
    }

    $sentFiles = @('发送样本 甲.txt', '发送样本 乙.txt') | ForEach-Object {
        $path = Join-Path $testRoot $_
        Set-Content -LiteralPath $path -Value 'Send To fixture'
        $path
    }
    $sendArguments = '--verify-send-to "{0}" "{1}"' -f $sentFiles[0], $sentFiles[1]
    $sendProcess = Start-Process -FilePath $sendToShortcut -ArgumentList $sendArguments -WindowStyle Hidden -PassThru
    if (!$sendProcess) { throw 'Windows did not start a process from the Send To shortcut' }
    if (!$sendProcess.WaitForExit(55000)) {
        $sendProcess.Kill()
        throw 'Send To shortcut did not complete runtime verification in 55 seconds'
    }
    if ($sendProcess.ExitCode) {
        $log = Join-Path $testRoot 'desktop-diagnostics.txt'
        $application = Join-Path $target 'FormaBox.exe'
        $diagnostic = Start-Process -FilePath $application -ArgumentList "--send-to $sendArguments" -WindowStyle Hidden -PassThru -RedirectStandardError $log
        if (!$diagnostic.WaitForExit(55000)) { $diagnostic.Kill() }
        if (Test-Path -LiteralPath $log) {
            Get-Content -LiteralPath $log -Encoding utf8
        }
        throw "Send To shortcut failed runtime verification with code $($sendProcess.ExitCode)"
    }
    Write-Host 'Send To and desktop runtime verified.'
    $quickInputs = @('快捷测试 甲.png', '快捷测试 乙.png') | ForEach-Object { Join-Path $testRoot $_ }
    & $python -c 'import sys; from PIL import Image; [Image.new("RGB", (160, 100), "teal").save(p) for p in sys.argv[1:]]' @quickInputs
    if ($LASTEXITCODE) { throw 'Unable to generate quick-action inputs' }
    Invoke-CheckedProcess $quickPhoto ('--verify-quick "{0}" "{1}"' -f $quickInputs[0], $quickInputs[1])
    if ($ExpectBundledEngines) {
        $document = Join-Path $testRoot '快捷测试 文档.rtf'
        Set-Content -LiteralPath $document -Encoding ascii -Value '{\rtf1\ansi FormaBox quick Office test}'
        Invoke-CheckedProcess $quickOffice ('--verify-quick "{0}"' -f $document)
    }
    Write-Host 'Quick actions completed from their installed shortcuts.'
    $smokeScript = Join-Path $PSScriptRoot '../tests/smoke_tools.py'
    $reportPath = Join-Path $testRoot 'smoke.json'
    $arguments = '-X utf8 -B "{0}" --scratch "{1}" --report "{2}"' -f $smokeScript, $testRoot, $reportPath
    $smoke = Start-Process -FilePath $python -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    if ($smoke.ExitCode -notin 0, 2 -or !(Test-Path -LiteralPath $reportPath)) {
        throw 'Installed worker smoke test failed'
    }
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($report.summary.failed -ne 0 -or $report.tools.'pdf.render'.status -ne 'passed') {
        throw 'Installed worker failed or the bundled PDF renderer is missing'
    }
    if ($ExpectBundledEngines -and $report.summary.blocked -ne 0) {
        throw 'At least one packaged tool was unavailable with the bundled engines'
    }

    $userFile = Join-Path $target 'python/keep.txt'
    Set-Content -LiteralPath $userFile -Value 'User-created file'
    Invoke-CheckedProcess $uninstaller "/S _?=$target"
    if ((Test-Path -LiteralPath (Join-Path $target 'FormaBox.exe')) -or
        (Test-Path -LiteralPath $registry) -or (Test-Path -LiteralPath $shortcut) -or
        (Test-Path -LiteralPath $desktopShortcut) -or (Test-Path -LiteralPath $sendToShortcut) -or
        (Test-Path -LiteralPath $quickOffice) -or (Test-Path -LiteralPath $quickPhoto) -or
        !(Test-Path -LiteralPath $userFile)) {
        throw 'Uninstall did not remove registered app files or did not preserve the user file'
    }
    Write-Host 'Installer registration, Send To file import, desktop startup, installed worker smoke tests and uninstall verified.'
}
finally {
    if ($previousPath) { $env:Path = $previousPath }
    if (Test-Path -LiteralPath $registry) {
        $registered = (Get-ItemProperty -LiteralPath $registry).InstallLocation
        if ($registered -eq $target -and (Test-Path -LiteralPath $uninstaller)) {
            Invoke-CheckedProcess $uninstaller "/S _?=$target"
        }
    }
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    $tempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
    if ($resolvedTestRoot.StartsWith("$tempRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
