[CmdletBinding()]
param([Parameter(Mandatory)][string]$Setup)

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

try {
    Invoke-CheckedProcess $setupPath "/S /D=$target"
    if (!(Test-Path -LiteralPath $uninstaller) -or !(Test-Path -LiteralPath $shortcut) -or
        !(Test-Path -LiteralPath $desktopShortcut) -or
        (Get-ItemProperty -LiteralPath $registry).InstallLocation -ne $target) {
        throw 'Installation files, shortcuts, or uninstall registration are missing'
    }

    $previousPath = $env:Path
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    Remove-Item Env:PYTHONHOME,Env:PYTHONPATH,Env:FORMABOX_PYTHON,Env:FORMABOX_WORKER_DIR,Env:QT_PLUGIN_PATH,Env:QML2_IMPORT_PATH,Env:QML_IMPORT_PATH -ErrorAction SilentlyContinue
    $env:QT_QPA_PLATFORM = 'windows'
    $env:QT_QUICK_BACKEND = 'software'
    $env:PYTHONUTF8 = '1'

    Invoke-CheckedProcess (Join-Path $target 'FormaBox.exe') '--verify-runtime'
    $smokeScript = Join-Path $PSScriptRoot '../tests/smoke_tools.py'
    $reportPath = Join-Path $testRoot 'smoke.json'
    $python = Join-Path $target 'python/python.exe'
    $arguments = '-X utf8 -B "{0}" --scratch "{1}" --report "{2}"' -f $smokeScript, $testRoot, $reportPath
    $smoke = Start-Process -FilePath $python -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    if ($smoke.ExitCode -notin 0, 2 -or !(Test-Path -LiteralPath $reportPath)) {
        throw 'Installed worker smoke test failed'
    }
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($report.summary.failed -ne 0 -or $report.tools.'pdf.render'.status -ne 'passed') {
        throw 'Installed worker failed or the bundled PDF renderer is missing'
    }

    $userFile = Join-Path $target 'python/keep.txt'
    Set-Content -LiteralPath $userFile -Value 'User-created file'
    Invoke-CheckedProcess $uninstaller "/S _?=$target"
    if ((Test-Path -LiteralPath (Join-Path $target 'FormaBox.exe')) -or
        (Test-Path -LiteralPath $registry) -or (Test-Path -LiteralPath $shortcut) -or
        (Test-Path -LiteralPath $desktopShortcut) -or
        !(Test-Path -LiteralPath $userFile)) {
        throw 'Uninstall did not remove registered app files or did not preserve the user file'
    }
    Write-Host 'Installer registration, desktop startup, installed worker smoke tests and uninstall verified.'
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