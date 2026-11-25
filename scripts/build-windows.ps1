param(
    [string]$QtPrefix = $env:Qt6_DIR,
    [string]$Configuration = 'Release',
    [string]$Python = '',
    [string]$Wheelhouse = '',
    [string]$Generator = '',
    [switch]$WithHeic,
    [switch]$TestOnly
)
$ErrorActionPreference = 'Stop'

function Invoke-Checked([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command" }
}

if ($Wheelhouse) { $Wheelhouse = (Resolve-Path -LiteralPath $Wheelhouse).Path }
if ($QtPrefix) { $QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path }
Push-Location -LiteralPath (Join-Path $PSScriptRoot '..')
try {
    $Root = (Get-Location).Path
    if (!(Test-Path -LiteralPath '.venv/Scripts/python.exe')) {
        if (!$Python) {
            $Command = Get-Command python.exe -ErrorAction SilentlyContinue
            if ($Command -and $Command.Source -notlike '*\Microsoft\WindowsApps\*') {
                $Python = $Command.Source
            }
        }
        if ($Python) {
            Invoke-Checked { & $Python -m venv .venv }
        } else {
            Invoke-Checked { py -3 -m venv .venv }
        }
    }
    $Py = (Resolve-Path -LiteralPath '.venv/Scripts/python.exe').Path
    $Extras = if ($WithHeic) { 'test,heic' } else { 'test' }
    $PipArgs = @('install', '-e', "./worker[$Extras]")
    if ($Wheelhouse) { $PipArgs += @('--no-index', '--find-links', $Wheelhouse) }
    Invoke-Checked { & $Py -m pip @PipArgs }
    $env:PYTHONUTF8 = '1'
    $env:FORMABOX_PYTHON = $Py
    $env:FORMABOX_WORKER_DIR = Join-Path $Root 'worker'
    Invoke-Checked { & $Py -m pytest -q -ra tests }
    if ($TestOnly) { return }

    $CmakeArgs = @('-S', '.', '-B', 'build', "-DCMAKE_BUILD_TYPE=$Configuration")
    if ($QtPrefix) { $CmakeArgs += "-DCMAKE_PREFIX_PATH=$QtPrefix" }
    if ($Generator) { $CmakeArgs += @('-G', $Generator) }
    Invoke-Checked { cmake @CmakeArgs }
    Invoke-Checked { cmake --build build --config $Configuration --parallel }
    Invoke-Checked { cmake --install build --config $Configuration --prefix "$Root/dist" }
    Copy-Item -LiteralPath "$Root/build/launcher/$Configuration/FormaBox.exe" -Destination "$Root/FormaBox.exe" -Force
    Write-Host "Launch the development build with $Root/FormaBox.exe."
} finally {
    Pop-Location
}
