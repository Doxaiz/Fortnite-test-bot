$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $repo 'fortnite_bot.ahk'))
# Independent of the builder's FORMA_VERSION parser: use the EXE metadata version.
$metadata = [regex]::Match($source, '(?m)^;@Ahk2Exe-SetVersion[ \t]+([0-9]+\.[0-9]+\.[0-9]+)\.0[ \t]*\r?$')
if (!$metadata.Success) {
    throw 'Could not read the expected tag from Ahk2Exe-SetVersion.'
}
$tag = 'v' + $metadata.Groups[1].Value
$wrongTag = if ($tag -eq 'v0.0.0') { 'v0.0.1' } else { 'v0.0.0' }
$builder = Join-Path $repo 'tools\build-portable.ps1'
$output = Join-Path ([IO.Path]::GetTempPath()) ('forma-tag-test-' + [guid]::NewGuid().ToString('N'))

# This override is scoped to the test and its child script. A regression must
# fail the test instead of performing a download on the wrong-tag path.
function Invoke-WebRequest {
    throw 'The builder attempted a download before rejecting the wrong tag.'
}

$rejected = $false
try {
    $null = & $builder -ExpectedTag $wrongTag -OutputDirectory $output
} catch {
    if ($_.Exception.Message -cne "Tag '$wrongTag' does not match FORMA_VERSION; expected '$tag'.") {
        throw
    }
    $rejected = $true
}
if (!$rejected -or (Test-Path -LiteralPath $output)) {
    throw 'The builder did not reject the wrong tag without staging a package.'
}
Write-Host "Rejected $wrongTag before downloading or staging anything. Testing matching tag $tag in the build."
Write-Output $tag
