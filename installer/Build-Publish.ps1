param(
    [string]$RuntimeIdentifier = "win-x64",
    [string]$Configuration = "Release",
    [switch]$NoRestore
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repoRoot "WiFiErabi.App\WiFiErabi.App.csproj"
$publishRoot = Join-Path $repoRoot "artifacts\publish"
$publishDir = Join-Path $publishRoot $RuntimeIdentifier

Write-Host "Creating publish output..." -ForegroundColor Cyan
Write-Host "Project: $projectPath"
Write-Host "Output : $publishDir"

$env:DOTNET_CLI_HOME = Join-Path $repoRoot ".dotnet"

$publishArgs = @(
    "publish"
    $projectPath
    "-c"
    $Configuration
    "-r"
    $RuntimeIdentifier
    "--self-contained"
    "true"
    "-p:PublishSingleFile=true"
    "-p:IncludeNativeLibrariesForSelfExtract=true"
    "-p:DebugType=None"
    "-p:DebugSymbols=false"
    "-o"
    $publishDir
)

if ($NoRestore) {
    $publishArgs += "--no-restore"
}

dotnet @publishArgs

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

Write-Host ""
Write-Host "Publish output created." -ForegroundColor Green
Write-Host $publishDir
