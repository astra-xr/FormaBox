[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Setup,
    [Parameter(Mandatory)][string]$PreviousSetup,
    [Parameter(Mandatory)][ValidateSet('0.9.0','0.9.3')][string]$PreviousVersion
)

$ErrorActionPreference = 'Stop'
$next = (Resolve-Path -LiteralPath $Setup).Path
$previous = (Resolve-Path -LiteralPath $PreviousSetup).Path
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FormaBox'
if (Test-Path -LiteralPath $uninstallKey) {
    throw 'Use a Windows account without a registered Omnora installation.'
}
$root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP "Omnora-upgrade-$([guid]::NewGuid())")).FullName
$target = Join-Path $root '万象 升级样本'
$uninstaller = Join-Path $target 'Uninstall.exe'
$app = Join-Path $target 'Omnora.exe'
$oldApp = if ($PreviousVersion -eq '0.9.0') { Join-Path $target 'FormaBox.exe' } else { $app }
$data = Join-Path $env:LOCALAPPDATA 'Omnora'
$history = Join-Path $data 'tasks.sqlite'
$preferences = 'HKCU:\Software\FormaBox\FormaBox\tools'
if (Test-Path -LiteralPath $history) {
    throw 'Use an isolated Windows account without existing Omnora task data.'
}
if ((Test-Path -LiteralPath $preferences) -and
    (Get-ItemProperty -LiteralPath $preferences).PSObject.Properties['favorites']) {
    throw 'Use an isolated Windows account without existing Omnora favorites.'
}

function Invoke-Setup([string]$File, [string]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
    return $process.ExitCode
}

function Assert-Fingerprint([string]$File, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Expected) {
        throw "Unexpected change to $File"
    }
}

$env:QT_QUICK_BACKEND = 'software'
try {
    if ((Invoke-Setup $previous "/S /D=$target") -ne 0) {
        throw "Could not install the published $PreviousVersion setup."
    }
    if ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ne $PreviousVersion) {
        throw 'The previous installation is not registered at the expected version.'
    }
    $original = (Get-FileHash -LiteralPath $oldApp -Algorithm SHA256).Hash
    $originalUninstaller = (Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash
    $personal = Join-Path $target 'python/用户的资料.txt'
    Set-Content -LiteralPath $personal -Value 'Omnora upgrade user file'
    $personalHash = (Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    & (Join-Path $target 'python/python.exe') -c "import sqlite3, sys; db = sqlite3.connect(sys.argv[1]); db.execute('CREATE TABLE user_fixture (label TEXT)'); db.execute('INSERT INTO user_fixture VALUES (?)', ('history',)); db.commit(); db.close()" $history
    if ($LASTEXITCODE) { throw 'Could not create the SQLite upgrade fixture.' }
    $historyHash = (Get-FileHash -LiteralPath $history -Algorithm SHA256).Hash
    if (!(Test-Path -LiteralPath $preferences)) { New-Item -Path $preferences -Force | Out-Null }
    New-ItemProperty -LiteralPath $preferences -Name favorites -PropertyType MultiString -Value @('image.convert','pdf.merge') | Out-Null

    # This path sorts after the executable and uninstaller, so the failure exercises a real partial switch.
    $locked = [IO.File]::Open((Join-Path $target 'worker/formabox/__init__.py'),
                              [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ((Invoke-Setup $next "/S /D=$target") -eq 0) {
            throw 'A locked-file upgrade unexpectedly succeeded.'
        }
    } finally {
        $locked.Dispose()
    }
    Assert-Fingerprint $oldApp $original
    Assert-Fingerprint $uninstaller $originalUninstaller
    if ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ne $PreviousVersion -or
        (Test-Path -LiteralPath (Join-Path $target '.omnora-setup'))) {
        throw 'The failed upgrade did not restore its previous state.'
    }
    if ($PreviousVersion -eq '0.9.0' -and (Test-Path -LiteralPath $app)) {
        throw 'The failed upgrade left a new executable in the old installation.'
    }
    if ((Invoke-Setup $oldApp '--verify-runtime') -ne 0) {
        throw 'The original program does not start after rollback.'
    }

    if ((Invoke-Setup $next "/S /D=$target") -ne 0) {
        throw 'The upgrade could not be retried after releasing the locked file.'
    }
    $expectedVersion = (Get-Item -LiteralPath $next).VersionInfo.ProductVersion
    if ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ne $expectedVersion -or
        (Invoke-Setup $app '--verify-runtime') -ne 0) {
        throw 'The upgraded installation failed startup verification.'
    }
    Assert-Fingerprint $personal $personalHash
    Assert-Fingerprint $history $historyHash
    if (((Get-ItemProperty -LiteralPath $preferences).favorites -join ',') -ne 'image.convert,pdf.merge') {
        throw 'The upgrade changed the existing favorites.'
    }
    if ((Invoke-Setup $uninstaller "/S _?=$target") -ne 0 -or
        (Test-Path -LiteralPath $app) -or (Test-Path -LiteralPath $uninstallKey)) {
        throw 'The upgraded installation failed uninstall verification.'
    }
    Assert-Fingerprint $personal $personalHash
    Assert-Fingerprint $history $historyHash
    Write-Host "Verified $PreviousVersion to ${expectedVersion}: locked-file rollback, original startup, retry, data preservation and uninstall."
} finally {
    if ((Test-Path -LiteralPath $uninstallKey) -and (Test-Path -LiteralPath $uninstaller) -and
        (Get-ItemProperty -LiteralPath $uninstallKey).InstallLocation -eq $target) {
        Invoke-Setup $uninstaller "/S _?=$target" | Out-Null
    }
    if (Test-Path -LiteralPath $history) { Remove-Item -LiteralPath $history }
    if (Test-Path -LiteralPath $preferences) {
        Remove-ItemProperty -LiteralPath $preferences -Name favorites -ErrorAction SilentlyContinue
    }
    $resolved = (Resolve-Path -LiteralPath $root).Path
    $tempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
    if ($resolved.StartsWith("$tempRoot\Omnora-upgrade-", [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
