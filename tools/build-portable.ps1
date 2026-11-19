param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist\portable')
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') {
    throw 'Run this build script in PowerShell on Windows.'
}

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$source = Join-Path $repo 'fortnite_bot.ahk'
$sourceText = [IO.File]::ReadAllText($source)
$versionMatch = [regex]::Match($sourceText, '(?m)^global FORMA_VERSION := "(\d+\.\d+\.\d+)"\r?$')
if (!$versionMatch.Success) {
    throw 'Could not read FORMA_VERSION from fortnite_bot.ahk.'
}
$version = $versionMatch.Groups[1].Value

# Hashes published by AutoHotkey/Ahk2Exe and AutoHotkey/AutoHotkey.
$compilerTag = 'Ahk2Exe1.1.37.02a2'
$compilerHash = 'c29b8c3a5124850d79fc9e66e2ca79677c377d7f31631ad3022ba159c5d9e3be'
$runtimeVersion = '2.0.18'
$runtimeHash = 'bf3a27398397b886a3d8b0ad2591c29a7165d1f560b1943a8bc120497b6ea5f8'
$runtimeSourceName = "AutoHotkey-v$runtimeVersion-source.zip"
$runtimeSourceHash = 'cc98b9ae8ff19458d9ebf5c2fe58da133d5c520045715ba2c290c6a728359977'

function Get-VerifiedArchive([string]$Url, [string]$Path, [string]$Sha256) {
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 90
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Sha256) {
        throw "Unexpected SHA-256 for $Url"
    }
}

function Find-UniqueFile([string]$Directory, [string]$Name) {
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter $Name -File -Recurse)
    if ($files.Count -ne 1) {
        throw "Expected one $Name in $Directory, found $($files.Count)."
    }
    return $files[0].FullName
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('forma-build-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $temp -ItemType Directory | Out-Null
try {
    $compilerZip = Join-Path $temp 'compiler.zip'
    $runtimeZip = Join-Path $temp 'runtime.zip'
    $runtimeSource = Join-Path $temp $runtimeSourceName
    Get-VerifiedArchive "https://github.com/AutoHotkey/Ahk2Exe/releases/download/$compilerTag/$compilerTag.zip" $compilerZip $compilerHash
    Get-VerifiedArchive "https://github.com/AutoHotkey/AutoHotkey/releases/download/v$runtimeVersion/AutoHotkey_$runtimeVersion.zip" $runtimeZip $runtimeHash
    Get-VerifiedArchive "https://codeload.github.com/AutoHotkey/AutoHotkey/zip/refs/tags/v$runtimeVersion" $runtimeSource $runtimeSourceHash

    $compilerDir = Join-Path $temp 'compiler'
    $runtimeDir = Join-Path $temp 'runtime'
    Expand-Archive -LiteralPath $compilerZip -DestinationPath $compilerDir
    Expand-Archive -LiteralPath $runtimeZip -DestinationPath $runtimeDir
    $compiler = Find-UniqueFile $compilerDir 'Ahk2Exe.exe'
    $runtime = Find-UniqueFile $runtimeDir 'AutoHotkey64.exe'
    $runtimeLicense = Find-UniqueFile $runtimeDir 'license.txt'

    $packageDir = Join-Path $temp 'package'
    $licensesDir = Join-Path $packageDir 'licenses'
    New-Item -ItemType Directory -Path $licensesDir -Force | Out-Null
    $exe = Join-Path $packageDir 'FORMA.exe'
    $entry = Join-Path $PSScriptRoot 'portable_entry.ahk'
    $icon = Join-Path $repo 'assets\forma.ico'
    $buildArgs = "/in `"$entry`" /out `"$exe`" /base `"$runtime`" /icon `"$icon`" /cp 65001 /compress 0 /silent verbose"
    $process = Start-Process -FilePath $compiler -ArgumentList $buildArgs -WorkingDirectory $repo -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Ahk2Exe failed (exit code $($process.ExitCode))."
    }
    if ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion -ne "$version.0") {
        throw 'The executable version does not match FORMA_VERSION.'
    }

    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $packageDir
    Copy-Item -LiteralPath (Join-Path $repo 'docs\portable.txt') -Destination (Join-Path $packageDir 'README.txt')
    Copy-Item -LiteralPath $runtimeLicense -Destination (Join-Path $licensesDir 'AutoHotkey-GPL-2.0.txt')

    $archive = Join-Path $temp "FORMA-v$version-windows-x64.zip"
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $archive -CompressionLevel Optimal
    $digests = foreach ($file in @($archive, $runtimeSource)) {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Leaf $file)
    }
    $hashFile = Join-Path $temp 'SHA256SUMS.txt'
    Set-Content -LiteralPath $hashFile -Value $digests -Encoding Ascii
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    foreach ($file in @($archive, $runtimeSource, $hashFile)) {
        Copy-Item -LiteralPath $file -Destination $OutputDirectory -Force
    }
    Write-Host "Portable FORMA v$version built in $OutputDirectory"
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
