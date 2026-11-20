param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist\portable'),
    [switch]$SmokeTest,
    [string]$ExpectedTag
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
if ($PSBoundParameters.ContainsKey('ExpectedTag') -and $ExpectedTag -cne "v$version") {
    throw "Tag '$ExpectedTag' does not match FORMA_VERSION; expected 'v$version'."
}

# Pin the release binaries and the corresponding AutoHotkey source archive.
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

function Invoke-AhkCheck([string]$Runtime, [string]$Arguments, [string]$Check, [string]$Directory) {
    $stdout = Join-Path $Directory 'check-stdout.log'
    $stderr = Join-Path $Directory 'check-stderr.log'
    $process = Start-Process -FilePath $Runtime -ArgumentList $Arguments -WorkingDirectory $Directory -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Get-Content -LiteralPath $stdout, $stderr -Encoding UTF8
    if ($process.ExitCode -ne 0) {
        $reason = Get-Content -LiteralPath $stderr -Encoding UTF8 -TotalCount 1
        throw "$Check failed (exit code $($process.ExitCode)). $reason"
    }
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
    $runtimeSourceDir = Join-Path $temp 'runtime-source'
    Expand-Archive -LiteralPath $compilerZip -DestinationPath $compilerDir
    Expand-Archive -LiteralPath $runtimeZip -DestinationPath $runtimeDir
    Expand-Archive -LiteralPath $runtimeSource -DestinationPath $runtimeSourceDir
    $compiler = Find-UniqueFile $compilerDir 'Ahk2Exe.exe'
    $runtime = Find-UniqueFile $runtimeDir 'AutoHotkey64.exe'
    $runtimeLicense = Find-UniqueFile $runtimeSourceDir 'license.txt'

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

    $archiveName = "FORMA-v$version-windows-x64.zip"
    $archive = Join-Path $temp $archiveName
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $archive -CompressionLevel Optimal
    if ($SmokeTest) {
        $panelScript = Join-Path $repo 'tests\main_panel.ahk'
        Write-Host 'Smoke test: main panel controls and profile isolation'
        Invoke-AhkCheck $runtime ('/ErrorStdOut=UTF-8 "{0}"' -f $panelScript) 'Main panel test' $temp

        $archivesToTest = [ordered]@{ built = $archive }
        $published = Join-Path $repo "portable\$archiveName"
        if (Test-Path -LiteralPath $published -PathType Leaf) {
            # Verify and run the exact download linked from the repository, too.
            $manifest = Get-Content -LiteralPath (Join-Path $repo 'portable\SHA256SUMS.txt')
            $hash = (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($manifest -notcontains "$hash  $archiveName") {
                throw "SHA-256 mismatch for repository archive $archiveName."
            }
            $archivesToTest['repository'] = $published
        }
        $smokeScript = Join-Path $repo 'tests\portable_startup.ahk'
        foreach ($item in $archivesToTest.GetEnumerator()) {
            Write-Host "Smoke test: $($item.Key) $archiveName"
            $extracted = Join-Path $temp "extracted-$($item.Key)"
            Expand-Archive -LiteralPath $item.Value -DestinationPath $extracted
            $smokeExe = Join-Path $extracted 'FORMA.exe'
            $smokeArgs = '/ErrorStdOut=UTF-8 "{0}" "{1}"' -f $smokeScript, $smokeExe
            Invoke-AhkCheck $runtime $smokeArgs "The $($item.Key) portable startup test" $temp
        }
    }
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    $checksums = foreach ($file in @($archive, $runtimeSource)) {
        $name = Split-Path -Leaf $file
        $copy = Join-Path $OutputDirectory $name
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $file -Destination $copy -Force
        if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne $hash) {
            throw "SHA-256 mismatch after staging $name."
        }
        '{0}  {1}' -f $hash.ToLowerInvariant(), $name
    }
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value $checksums -Encoding Ascii
    Write-Host "Portable FORMA v$version built in $OutputDirectory"
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
