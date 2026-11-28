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

function Assert-WindowsDllImports([string]$Dll) {
    # Inspect the PE instead of relying on a runner that already has VC++ DLLs.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'Install the Visual Studio C++ Build Tools (x64) with a Windows SDK.'
    }
    $dumpbin = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
    if (!$dumpbin) {
        throw 'Could not locate the MSVC x64 dumpbin.exe.'
    }
    $pe = & $dumpbin /nologo /dependents $Dll
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect Rust DLL dependencies (exit code $LASTEXITCODE)."
    }
    $imports = @($pe | Where-Object { $_ -match '^\s+[a-zA-Z0-9_.-]+\.dll\s*$' } | ForEach-Object { $_.Trim() })
    if ($imports.Count -eq 0) {
        throw 'No import list found in MSVC dumpbin output.'
    }
    Write-Host "Rust DLL imports: $($imports -join ', ')"
    foreach ($import in $imports) {
        if ($import -notmatch '^(?:kernel32|ntdll|advapi32|bcrypt|bcryptprimitives|userenv|ws2_32|dbghelp|api-ms-win-core-[a-z0-9-]+)\.dll$') {
            throw "Non-system import in Rust DLL: $import"
        }
    }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('forma-build-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $temp -ItemType Directory | Out-Null
try {
    # This runs only after the expected-tag gate. The pinned Rust toolchain is
    # selected from rust-toolchain.toml; the crate itself has no dependencies.
    if (!(Get-Command cargo.exe -ErrorAction SilentlyContinue)) {
        throw 'Install Rust with rustup and the Visual Studio C++ Build Tools (x64) with a Windows SDK.'
    }
    $target = 'x86_64-pc-windows-msvc'
    $rustBuild = Join-Path $temp 'rust-target'
    $cargoArgs = @('--manifest-path', 'native\pixels\Cargo.toml', '--locked', '--offline', '--target', $target, '--target-dir', $rustBuild)
    Push-Location -LiteralPath $repo
    try {
        if ($SmokeTest) {
            & cargo test @cargoArgs
            if ($LASTEXITCODE -ne 0) { throw "Rust pixel tests failed (exit code $LASTEXITCODE)." }
        }
        & cargo build --release @cargoArgs
        if ($LASTEXITCODE -ne 0) { throw "Rust DLL build failed (exit code $LASTEXITCODE)." }
        $sysroot = & rustc --print sysroot
        if ($LASTEXITCODE -ne 0) { throw 'Could not locate the Rust toolchain licenses.' }
    } finally {
        Pop-Location
    }
    $nativeDll = Join-Path $rustBuild "$target\release\forma_pixels.dll"
    if (!(Test-Path -LiteralPath $nativeDll -PathType Leaf)) {
        throw 'Cargo did not produce forma_pixels.dll.'
    }
    Assert-WindowsDllImports $nativeDll

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
    Copy-Item -LiteralPath $nativeDll -Destination $packageDir
    foreach ($file in 'COPYRIGHT', 'LICENSE-APACHE', 'LICENSE-MIT') {
        Copy-Item -LiteralPath (Join-Path $sysroot "share\doc\rust\$file") -Destination (Join-Path $licensesDir "Rust-$file.txt")
    }

    $archiveName = "FORMA-v$version-windows-x64.zip"
    $archive = Join-Path $temp $archiveName
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $archive -CompressionLevel Optimal
    if ($SmokeTest) {
        # Exercise both modes in separate processes; never read or replace a
        # developer's local DLL. The script/include layout mirrors the repo.
        $sourceChecks = Join-Path $temp 'source-checks'
        New-Item -ItemType Directory -Path $sourceChecks | Out-Null
        Copy-Item -LiteralPath $source, (Join-Path $repo 'pixel_backend.ahk') -Destination $sourceChecks
        Copy-Item -LiteralPath (Join-Path $repo 'tests'), (Join-Path $repo 'tools') -Destination $sourceChecks -Recurse
        foreach ($backend in 'AutoHotkey', 'Rust') {
            if ($backend -eq 'Rust') {
                Copy-Item -LiteralPath $nativeDll -Destination $sourceChecks
                $parityScript = Join-Path $sourceChecks 'tests\native_pixels.ahk'
                Invoke-AhkCheck $runtime ('/ErrorStdOut=UTF-8 "{0}"' -f $parityScript) 'Rust/AHK parity' $temp
            }
            foreach ($suite in 'runtime_diagnostics', 'window_input', 'replay_f5', 'evaluate_vision', 'main_panel') {
                $script = Join-Path $sourceChecks "tests\$suite.ahk"
                Write-Host "Smoke test ($backend): $suite"
                Invoke-AhkCheck $runtime ('/ErrorStdOut=UTF-8 "{0}"' -f $script) "$backend $suite test" $temp
            }
            # Compare complete detectors on identical in-memory fixtures, on
            # the same runner. Check backend and outputs, not timing in CI.
            $script = Join-Path $sourceChecks 'tests\runtime_diagnostics.ahk'
            $benchmarks = @(
                @{ Detector = 'FrameMenu'; Mode = '--bench-menu'; Cases = 'blank|mixed'; Count = 4 }
                @{ Detector = 'FindEnemyMulti'; Mode = '--bench-combat'; Cases = 'static|figure|isolated|motion|changed|broad'; Count = 12 }
            )
            foreach ($bench in $benchmarks) {
                $detector = $bench.Detector
                $benchLog = Invoke-AhkCheck $runtime ('/ErrorStdOut=UTF-8 "{0}" {1}' -f $script, $bench.Mode) "$backend $detector benchmark" $temp
                $benchLog | Write-Output
                $samples = @($benchLog | Where-Object { $_ -match ('^\d+x\d+ ({0}): median=\d+\.\d+' -f $bench.Cases) })
                if ($samples.Count -ne $bench.Count -or !($benchLog -match " / $backend .+ / $detector \(ms\)")) {
                    throw "Missing or incorrect backend in $backend $detector benchmark."
                }
                if ($env:GITHUB_ACTIONS -eq 'true') {
                    Write-Host "::notice title=$detector ($backend)::$($samples -join ' | ')"
                }
            }
        }

        # Both variants read the same native grid. Alternate just the 3x3
        # reduction on one runner; the script checks boxes and diagnostics.
        $script = Join-Path $sourceChecks 'tests\runtime_diagnostics.ahk'
        $peakLog = Invoke-AhkCheck $runtime ('/ErrorStdOut=UTF-8 "{0}" --bench-combat-peak' -f $script) 'Paired warm peak benchmark' $temp
        $peakLog | Write-Output
        $peakSamples = @($peakLog | Where-Object { $_ -match '^\d+x\d+ (static|figure|isolated|motion|changed|broad): ahk_peak=\d+\.\d+ rust_peak=\d+\.\d+ \(n=11\)$' })
        if ($peakSamples.Count -ne 12 -or !($peakLog -match ' / Rust DLL / FindEnemyMulti paired warm peak \(ms\)')) {
            throw 'Missing paired warm peak measurements.'
        }
        if ($env:GITHUB_ACTIONS -eq 'true') {
            Write-Host "::notice title=FindEnemyMulti (paired 3x3 peak)::$($peakSamples -join ' | ')"
        }

        # GDI acquisition precedes any pixel backend. Measure once, using
        # a separate window/process, without running the game loop.
        $capture = Join-Path $sourceChecks 'tests\capture_window.ahk'
        $captureLog = Invoke-AhkCheck $runtime ('/ErrorStdOut=UTF-8 "{0}" --bench' -f $capture) 'GDI capture tests and benchmark' $temp
        $captureLog | Write-Output
        $captureSamples = @($captureLog | Where-Object { $_ -match '^(CAPTURE|SKIP capture) \d+x\d+' })
        foreach ($method in 'PrintWindow', 'BitBlt') {
            if (!($captureSamples -match "^CAPTURE 480x288 ${method}: median=\d+\.\d+ p95=\d+\.\d+")) {
                throw "Missing GDI benchmark for $method."
            }
        }
        if ($env:GITHUB_ACTIONS -eq 'true') {
            Write-Host "::notice title=Window capture (GDI)::$($captureSamples -join ' | ')"
        }

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
            if ($item.Key -eq 'built') { $smokeArgs += ' --require-rust' }
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
