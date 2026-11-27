[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EngineDirectory,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$WorkDirectory
)

$ErrorActionPreference = 'Stop'
$engineRoot = (New-Item -ItemType Directory -Path $EngineDirectory).FullName
$sourceRoot = (New-Item -ItemType Directory -Path $SourceDirectory -Force).FullName
$work = (New-Item -ItemType Directory -Path $WorkDirectory).FullName

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program exited with code $LASTEXITCODE" }
}

function Save-Download([string]$Url, [string]$File) {
    Invoke-Checked 'curl.exe' @('--fail', '--location', '--silent', '--show-error',
        '--connect-timeout', '30', '--max-time', '900', '--retry', '3', '--output', $File, $Url)
}

function Save-Verified([string]$Url, [string]$File, [string]$Expected) {
    Save-Download $Url $File
    if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Expected) {
        throw "SHA-256 mismatch for $File"
    }
}

function Save-GitBlob([string]$Url, [string]$File, [string]$Blob) {
    Save-Download $Url $File
    $actual = & git hash-object --no-filters -- $File
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Blob) { throw "Git blob hash mismatch for $File" }
}

Write-Host 'Staging FFmpeg and its corresponding sources'
# The older BtbN binary archive has rotated out. Extract only the FFmpeg
# executable identified in Open Video Craft's build notes and verify its digest.
$upstream = 'https://github.com/Reubencfernandes/Open-Video-Craft/releases/download/v1.0.3'
$container = Join-Path $work 'ffmpeg-container.exe'
Save-Verified "$upstream/Open-Video-Craft-Portable-1.0.3-win-x64.exe" $container '135d9b986c5dbdae20d042d4012de3b7595e0961504d11e4fc2a0d8aa13559ad'
$sevenZip = Join-Path $env:ProgramFiles '7-Zip/7z.exe'
$outer = Join-Path $work 'ffmpeg-container'
Invoke-Checked $sevenZip @('x', $container, "-o$outer", '-y', '-ir!app-64.7z')
$embedded = @(Get-ChildItem -LiteralPath $outer -Filter 'app-64.7z' -File -Recurse)
if ($embedded.Count -ne 1) { throw 'Expected one x64 archive in the FFmpeg carrier' }
$inner = Join-Path $work 'ffmpeg-extracted'
Invoke-Checked $sevenZip @('x', $embedded[0].FullName, "-o$inner", '-y', '-ir!ffmpeg.exe')
$ffmpeg = @(Get-ChildItem -LiteralPath $inner -Filter 'ffmpeg.exe' -File -Recurse)
if ($ffmpeg.Count -ne 1 -or (Get-FileHash -LiteralPath $ffmpeg[0].FullName).Hash -ne
    '070be6f5202e71a5e0bec88312230eebf2708f9b9ee3694596babf20902dddd2') {
    throw 'Extracted FFmpeg executable does not match the documented BtbN build'
}
$ffmpegDir = (New-Item -ItemType Directory -Path (Join-Path $engineRoot 'ffmpeg')).FullName
Copy-Item -LiteralPath $ffmpeg[0].FullName -Destination $ffmpegDir
Save-Download 'https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.1.2/COPYING.GPLv3' (Join-Path $ffmpegDir 'COPYING.GPLv3')
$ffmpegSourceAssets = @(
    @{ Name = 'FFmpeg-Windows-Build-Sources.tar.gz'; Sha = '1999c647b7945d2fddd9ff303dcc133a7740ad1e791c257afa5e8a7211782686' }
    @{ Name = 'FFmpeg-Windows-Dependency-Sources.tar'; Sha = 'f5375da5ffa4f85a7dac99108a2aa36d3030b8832b0008b6a453f747aa47fdbb' }
)
foreach ($asset in $ffmpegSourceAssets) {
    $suffix = $asset.Name.Replace('FFmpeg-Windows-', 'Windows-FFmpeg-')
    Save-Verified "$upstream/Open-Video-Craft-1.0.3-$suffix" (Join-Path $sourceRoot $asset.Name) $asset.Sha
}

Write-Host 'Building Tesseract and collecting its build inputs'
$vcpkg = Join-Path $work 'vcpkg'
$vcpkgCommit = '9fa95bf687fa6ae7f2da0673a8067e5fc1515c27'
$env:VCPKG_ROOT = $vcpkg
$env:VCPKG_DISABLE_METRICS = '1'
$env:VCPKG_BINARY_SOURCES = 'clear'
Invoke-Checked 'git' @('init', $vcpkg)
Invoke-Checked 'git' @('-C', $vcpkg, 'fetch', '--depth=1', 'https://github.com/microsoft/vcpkg.git', $vcpkgCommit)
Invoke-Checked 'git' @('-C', $vcpkg, 'checkout', '--detach', 'FETCH_HEAD')
Push-Location -LiteralPath $vcpkg
try {
    Invoke-Checked '.\bootstrap-vcpkg.bat' @('-disableMetrics')
    Invoke-Checked '.\vcpkg.exe' @('install', 'tesseract[core]:x64-windows-static')
} finally {
    Pop-Location
}
$tessDir = (New-Item -ItemType Directory -Path (Join-Path $engineRoot 'tesseract')).FullName
$tessData = (New-Item -ItemType Directory -Path (Join-Path $tessDir 'tessdata')).FullName
$tessLicenses = (New-Item -ItemType Directory -Path (Join-Path $tessDir 'licenses')).FullName
$staticInstall = Join-Path $vcpkg 'installed/x64-windows-static'
Copy-Item -LiteralPath (Join-Path $staticInstall 'tools/tesseract/tesseract.exe') -Destination $tessDir
Get-ChildItem -LiteralPath (Join-Path $staticInstall 'share') -Directory | ForEach-Object {
    $notice = Join-Path $_.FullName 'copyright'
    if (Test-Path -LiteralPath $notice -PathType Leaf) {
        Copy-Item -LiteralPath $notice -Destination (Join-Path $tessLicenses "$($_.Name).txt")
    }
}
if (!(Test-Path -LiteralPath (Join-Path $tessLicenses 'tesseract.txt'))) { throw 'Missing Tesseract license' }

$models = 'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/87416418657359cb625c412a48b6e1d6d41c29bd'
Save-GitBlob "$models/eng.traineddata" (Join-Path $tessData 'eng.traineddata') 'bbef4675053b5b468cdb477053e28b1c698ba08e'
Save-GitBlob "$models/chi_sim.traineddata" (Join-Path $tessData 'chi_sim.traineddata') '388bac276d033d06e5ed5ba7a7ad14ae58f97dab'
Save-GitBlob "$models/LICENSE" (Join-Path $tessData 'LICENSE') 'd645695673349e3947e8e5ae42332d0ac3164cd7'

$ports = @(Get-Content -LiteralPath (Join-Path $vcpkg 'installed/vcpkg/status') |
    ForEach-Object { if ($_ -match '^Package: ([a-z0-9-]+)$') { $Matches[1] } } |
    Sort-Object -Unique)
$inputSources = @(
    foreach ($port in $ports) {
        "ports/$port"
        if (Test-Path -LiteralPath (Join-Path $vcpkg "buildtrees/$port/src") -PathType Container) {
            "buildtrees/$port/src"
        }
    }
)
if ($inputSources -notcontains 'buildtrees/tesseract/src' -or $inputSources -notcontains 'buildtrees/leptonica/src') {
    throw 'Tesseract build source files are missing'
}
@"
vcpkg checkout: https://github.com/microsoft/vcpkg/tree/$vcpkgCommit
Build with Visual Studio 2022 and the pinned vcpkg checkout:
  bootstrap-vcpkg.bat -disableMetrics
  vcpkg install tesseract[core]:x64-windows-static
Exact patched inputs are in buildtrees/<port>/src. Recipes and patches are in ports.
Language models: $models
"@ | Set-Content -LiteralPath (Join-Path $vcpkg 'FORMABOX-BUILD.txt') -Encoding utf8
Invoke-Checked 'tar.exe' (@('-czf', (Join-Path $sourceRoot 'Tesseract-Windows-Build-Sources.tar.gz'), '-C', $vcpkg,
    'FORMABOX-BUILD.txt', 'LICENSE.txt', 'NOTICE.txt', 'scripts', 'triplets') + $inputSources)

Write-Host 'Extracting the unmodified LibreOffice runtime'
$msi = Join-Path $work 'LibreOffice_26.8.3_Win_x86-64.msi'
$officeUrl = 'https://download.documentfoundation.org/libreoffice/stable/26.8.3/win/x86_64/LibreOffice_26.8.3_Win_x86-64.msi'
Save-Verified $officeUrl $msi '0e6918c273eabbdbbd800ee0dacbbf130a14c13c2e4cec861b06dd59e015bf94'
$officeExtract = Join-Path $work 'office-extract'
$msiLog = Join-Path $work 'libreoffice-extract.log'
$msiArguments = '/a "{0}" /qn TARGETDIR="{1}" /l*v "{2}"' -f $msi, $officeExtract, $msiLog
$msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -WindowStyle Hidden -Wait -PassThru
if ($msiProcess.ExitCode) {
    Get-Content -LiteralPath $msiLog -Tail 25
    throw "LibreOffice extraction failed with code $($msiProcess.ExitCode)"
}
$office = @(Get-ChildItem -LiteralPath $officeExtract -Filter 'soffice.com' -File -Recurse)
if ($office.Count -ne 1) { throw 'The LibreOffice runtime was not found' }
$officeRoot = $office[0].Directory.Parent.FullName
if (!(Test-Path -LiteralPath (Join-Path $officeRoot 'LICENSE.html'))) { throw 'Missing LibreOffice license notices' }
$lo = Join-Path $engineRoot 'libreoffice'
& robocopy.exe $officeRoot $lo /E /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP /XF '*.msi'
if ($LASTEXITCODE -ge 8) { throw 'LibreOffice staging failed' }

@'
FormaBox Windows bundled engines

FFmpeg 8.1.2, BtbN win64 GPL static build, extracted without running Open Video Craft 1.0.3.
FFmpeg is distributed under the GNU GPL version 3 or later. See ffmpeg/COPYING.GPLv3.
Build configuration and corresponding source are published on the same FormaBox Release:
FFmpeg-Windows-Build-Sources.tar.gz and FFmpeg-Windows-Dependency-Sources.tar.

Tesseract is built from vcpkg for x64-windows-static, under Apache-2.0.
See tesseract/licenses for Tesseract and linked-library license texts.
The exact build inputs are in the same Release under Tesseract-Windows-Build-Sources.tar.gz.
English and Simplified Chinese trained data are from tesseract-ocr/tessdata_fast, under Apache-2.0.

LibreOffice 26.8.3.1 is from The Document Foundation's original Windows MSI.
See libreoffice/LICENSE.html and the upstream notices in the LibreOffice directory.
Corresponding source archives for the core, dictionaries, help and translations:
https://download.documentfoundation.org/libreoffice/src/26.8.3/
https://mirrors.ibiblio.org/libreoffice/src/26.8.3/

FormaBox releases and source attachments: https://github.com/astra-xr/FormaBox/releases
'@ | Set-Content -LiteralPath (Join-Path $engineRoot 'NOTICES.txt') -Encoding utf8
exit 0
