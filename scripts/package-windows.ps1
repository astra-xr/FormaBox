[CmdletBinding(DefaultParameterSetName = 'Compile')]
param(
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$Python,
    [Parameter(Mandatory, ParameterSetName = 'Compile')][string]$MakeNsis,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][switch]$PrepareOnly,
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$OutputDirectory = 'build/installers',
    [string]$CompilerRuntime,
    [string]$EngineBundleDirectory
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$recipe = Join-Path $root 'packaging/windows'
$transaction = (Resolve-Path -LiteralPath (Join-Path $BuildDirectory 'installer/Release/OmnoraInstallTransaction.exe')).Path
$versionMatch = Select-String -Path (Join-Path $root 'CMakeLists.txt') -Pattern '^project\(Omnora VERSION (\d+\.\d+\.\d+) '
$version = $versionMatch.Matches[0].Groups[1].Value
$output = (New-Item -ItemType Directory -Path $OutputDirectory -Force).FullName

$bundle = $null
if ($EngineBundleDirectory) {
    $bundle = Get-Item -LiteralPath $EngineBundleDirectory
    if (!$bundle.PSIsContainer -or ($bundle.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The engine bundle must be an ordinary directory'
    }
    foreach ($required in @('ffmpeg/ffmpeg.exe', 'tesseract/tesseract.exe',
            'tesseract/tessdata/eng.traineddata', 'tesseract/tessdata/chi_sim.traineddata',
            'libreoffice/program/soffice.com', 'libreoffice/program/soffice.bin',
            'whisper/whisper-cli.exe', 'whisper/whisper.dll', 'whisper/ggml.dll', 'NOTICES.txt')) {
        $file = Join-Path $bundle.FullName $required
        if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
            throw "The engine bundle is missing $required"
        }
    }
    $linked = Get-ChildItem -LiteralPath $bundle.FullName -Force -Recurse -Attributes ReparsePoint |
        Select-Object -First 1
    if ($linked) { throw "The engine bundle contains a reparse point: $($linked.FullName)" }
}

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
$prepared = $false

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
    if ($bundle) {
        $destination = Join-Path $payload 'engines'
        & "$env:SystemRoot\System32\robocopy.exe" $bundle.FullName $destination /E /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { throw 'Engine bundle staging failed' }
        $speech = Join-Path $destination 'whisper'
        $openMP = Join-Path (Split-Path $CompilerRuntime) 'Microsoft.VC143.OpenMP/vcomp140.dll'
        if (!(Test-Path -LiteralPath $openMP -PathType Leaf)) { throw 'The x64 Visual C++ OpenMP runtime is missing' }
        $crt | Copy-Item -Destination $speech
        Copy-Item -LiteralPath $openMP -Destination $speech
    }

    $variant = if ($bundle) { '-Full' } else { '' }
    $setup = Join-Path $output "Omnora-$version-Windows-x64${variant}-Setup.exe"
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
    $installerScript = Join-Path $recipe 'installer.nsi'
    if ($PrepareOnly) {
        $script = Join-Path $output "Omnora-$version-Windows-x64${variant}-Setup.nsi"
        $defines = @(
            ('!define SETUP_EXE "{0}"' -f $setup)
            ('!define FORMABOX_VERSION "{0}"' -f $version)
            ('!define PAYLOAD "{0}"' -f $payload)
            ('!define UNINSTALL_LIST "{0}"' -f $uninstallList)
            ('!define TRANSACTION_EXE "{0}"' -f $transaction)
            ('!define FORMABOX_ICON "{0}"' -f $icon)
            ('!include /CHARSET=UTF8 "{0}"' -f $installerScript)
        )
        [IO.File]::WriteAllLines($script, $defines, [Text.UTF8Encoding]::new($true))
        $prepared = $true
        Write-Host "Prepared $script"
        return
    }
    & $MakeNsis /INPUTCHARSET UTF8 /WX "/DSETUP_EXE=$setup" "/DFORMABOX_VERSION=$version" "/DPAYLOAD=$payload" "/DUNINSTALL_LIST=$uninstallList" "/DFORMABOX_ICON=$icon" "/DTRANSACTION_EXE=$transaction" $installerScript
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $setup -PathType Leaf)) {
        throw 'NSIS installer compilation failed'
    }
    $digest = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
    "$digest  $([IO.Path]::GetFileName($setup))" | Set-Content -LiteralPath "$setup.sha256" -Encoding ascii
    Write-Host "Built $setup"
}
finally {
    if (!$prepared) {
        if (Test-Path -LiteralPath $uninstallList) {
            Remove-Item -LiteralPath $uninstallList
        }
        $resolvedPayload = (Resolve-Path -LiteralPath $payload).Path
        if ($resolvedPayload.StartsWith("$output\", [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedPayload -Recurse -Force
        }
    }
}
