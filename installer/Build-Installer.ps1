param(
    [string]$RuntimeIdentifier = "win-x64",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$publishScript = Join-Path $PSScriptRoot "Build-Publish.ps1"
$issPath = Join-Path $PSScriptRoot "WiFiErabi.iss"
$projectPath = Join-Path $repoRoot "WiFiErabi.App\WiFiErabi.App.csproj"
$iscc = Get-Command iscc -ErrorAction SilentlyContinue

if (-not $iscc) {
    $defaultIsccPaths = @(
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )

    $matchedPath = $defaultIsccPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($matchedPath) {
        $iscc = @{ Source = $matchedPath }
    }
}

if (-not $iscc) {
    throw @"
Inno Setup 'iscc' was not found.

Install Inno Setup first so the 'iscc' command is available.
If you only want the publish output, run:

  powershell -File .\installer\Build-Publish.ps1
"@
}

& $publishScript -RuntimeIdentifier $RuntimeIdentifier -Configuration $Configuration

$publishDir = Join-Path $repoRoot "artifacts\publish\$RuntimeIdentifier"
$outputDir = Join-Path $repoRoot "artifacts\installer"
$projectXml = [xml](Get-Content -Raw $projectPath)
$projectVersion = $projectXml.Project.PropertyGroup.Version | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($projectVersion)) {
    throw "Version was not found in $projectPath."
}

Write-Host ""
Write-Host "Creating installer..." -ForegroundColor Cyan

& $iscc.Source `
    "/DMyAppVersion=$projectVersion" `
    "/DMyAppPublishDir=$publishDir" `
    "/DMyInstallerOutputDir=$outputDir" `
    $issPath

if ($LASTEXITCODE -ne 0) {
    throw "ISCC failed with exit code $LASTEXITCODE."
}

Write-Host ""
Write-Host "Installer created." -ForegroundColor Green
Write-Host $outputDir
