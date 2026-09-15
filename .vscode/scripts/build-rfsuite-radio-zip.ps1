param(
    [string]$OutputDir,
    [string]$ZipName,
    [string]$Language
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$deployScript = Join-Path $PSScriptRoot 'deploy-rfsuite-demo.ps1'

if (-not (Test-Path $deployScript)) {
    throw "Deploy script not found: $deployScript"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $workspaceRoot 'dist'
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Determine languages to build
$languages = @()
if (-not [string]::IsNullOrWhiteSpace($Language)) {
    $languages += $Language
} else {
    $i18nDir = Join-Path $workspaceRoot 'src\rfsuite\i18n'
    if (Test-Path $i18nDir) {
        $languages = Get-ChildItem -Path $i18nDir -Filter '*.lua' | 
            Where-Object { $_.BaseName -ne 'init' } | 
            ForEach-Object { $_.BaseName }
    }
    if ($languages.Count -eq 0) {
        $languages += 'en' # fallback
    }
}

# Determine base ZIP name without extension
if ([string]::IsNullOrWhiteSpace($ZipName)) {
    $versionFile = Join-Path $workspaceRoot 'src\rfsuite\lib\version.lua'
    $version = "0.1.5"
    if (Test-Path $versionFile) {
        $content = Get-Content $versionFile -Raw
        $major = [regex]::Match($content, 'M\.MAJOR\s*=\s*(\d+)').Groups[1].Value
        $minor = [regex]::Match($content, 'M\.MINOR\s*=\s*(\d+)').Groups[1].Value
        $patch = [regex]::Match($content, 'M\.PATCH\s*=\s*(\d+)').Groups[1].Value
        if ($major -ne "" -and $minor -ne "" -and $patch -ne "") {
            $version = "$major.$minor.$patch"
        }
    }
    $baseName = "rfsuite-radio-install-v$version"
} else {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ZipName)
}

foreach ($lang in $languages) {
    $currentZipName = "${baseName}_${lang}.zip"
    $zipPath = Join-Path $OutputDir $currentZipName
    
    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rfsuite-radio-package-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    
    try {
        Write-Host "Building radio install package for language: $lang..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File $deployScript -Target radio -TargetRoot $stagingRoot -Language $lang
        
        if (Test-Path $zipPath) {
            Remove-Item -Path $zipPath -Force
        }
        
        Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
        
        Write-Host "RFSuite install ZIP created:"
        Write-Host "  $zipPath"
        Write-Host "Contains top-level folders: SCRIPTS, WIDGETS, SOUNDS"
        Write-Host ""
    }
    finally {
        if (Test-Path $stagingRoot) {
            Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
