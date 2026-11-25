[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$Python,
    [Parameter(Mandatory)][string]$MakeNsis,
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$OutputDirectory = 'build/installers',
    [string]$CompilerRuntime
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$recipe = Join-Path $root 'packaging/windows'
$versionMatch = Select-String -Path (Join-Path $root 'CMakeLists.txt') -Pattern '^project\(FormaBox VERSION (\d+\.\d+\.\d+) '
$version = $versionMatch.Matches[0].Groups[1].Value
$output = (New-Item -ItemType Directory -Path $OutputDirectory -Force).FullName

if (!$CompilerRuntime) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $CompilerRuntime = Get-ChildItem (Join-Path $vs 'VC/Redist/MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1
}
$crt = @(Get-ChildItem -LiteralPath $CompilerRuntime -File -Filter '*.dll')
if (!($crt.Name -contains 'msvcp140.dll') -or !($crt.Name -contains 'vcruntime140.dll')) {
    throw 'An x64 Microsoft.VC143.CRT redistributable is required'
}
$qtBom = @(Get-ChildItem (Join-Path $QtPrefix 'sbom') -Filter '*.spdx')
if (!$qtBom.Count) { throw 'Qt component notices are missing from the selected SDK' }
$payload = (New-Item -ItemType Directory -Path (Join-Path $output "payload-$([guid]::NewGuid().ToString('N').Substring(0, 8))")).FullName
$uninstallList = "$payload.nsh"

try {
    & cmake --install $BuildDirectory --config Release --prefix $payload
    if ($LASTEXITCODE -ne 0) { throw 'CMake deployment failed' }
    $pythonDir = Join-Path $payload 'python'
    & $Python (Join-Path $recipe 'stage-runtime.py') $pythonDir
    if ($LASTEXITCODE -ne 0) { throw 'Python runtime staging failed' }
    $crt | Copy-Item -Destination $payload
    $crt | Copy-Item -Destination $pythonDir
    $licenses = New-Item -ItemType Directory -Path (Join-Path $payload 'licenses')
    Copy-Item (Join-Path $root 'LICENSE') $licenses.FullName
    Copy-Item (Join-Path $recipe 'THIRD-PARTY-NOTICES.txt') $licenses.FullName
    Copy-Item (Join-Path $recipe 'runtime-requirements.txt') $licenses.FullName
    Copy-Item (Join-Path $recipe 'licenses/*.txt') $licenses.FullName
    $qtBom | Copy-Item -Destination $licenses.FullName

    $setup = Join-Path $output "FormaBox-$version-Windows-x64-Setup.exe"
    $escape = { param($path) $path.Substring($payload.Length + 1).Replace('$', '$$') }
    $commands = @(
        Get-ChildItem -LiteralPath $payload -File -Recurse | ForEach-Object {
            'Delete "$INSTDIR\' + (& $escape $_.FullName) + '"'
        }
        Get-ChildItem -LiteralPath $payload -Directory -Recurse |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object { 'RMDir "$INSTDIR\' + (& $escape $_.FullName) + '"' }
    )
    [IO.File]::WriteAllLines($uninstallList, $commands, [Text.UTF8Encoding]::new($true))
    $icon = Join-Path $root 'desktop/assets/formabox.ico'
    & $MakeNsis /INPUTCHARSET UTF8 /WX "/DSETUP_EXE=$setup" "/DFORMABOX_VERSION=$version" "/DPAYLOAD=$payload" "/DUNINSTALL_LIST=$uninstallList" "/DFORMABOX_ICON=$icon" (Join-Path $recipe 'installer.nsi')
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $setup -PathType Leaf)) {
        throw 'NSIS installer compilation failed'
    }
    $digest = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
    "$digest  $([IO.Path]::GetFileName($setup))" | Set-Content -LiteralPath "$setup.sha256" -Encoding ascii
    Write-Host "Built $setup"
}
finally {
    if (Test-Path -LiteralPath $uninstallList) {
        Remove-Item -LiteralPath $uninstallList
    }
    $resolvedPayload = (Resolve-Path -LiteralPath $payload).Path
    if ($resolvedPayload.StartsWith("$output\", [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedPayload -Recurse -Force
    }
}
