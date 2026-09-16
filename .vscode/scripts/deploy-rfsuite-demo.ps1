param(
    [ValidateSet('simulator', 'radio')]
    [string]$Target = 'simulator',

    [string]$TargetRoot,

    [string]$Language
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$languageSource = 'default (en)'

function Get-LanguageFromSettingsFile {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) { return $null }

        # 1. Try native JSON parsing
        try {
            $json = $content | ConvertFrom-Json
            if ($json.'rfsuite.deploy.language') {
                return [string]$json.'rfsuite.deploy.language'
            }
        } catch {}

        # 2. Fallback regex parsing (supports JSONC, comments, trailing commas)
        $match = [regex]::Match($content, '["'']rfsuite\.deploy\.language["'']\s*:\s*["'']([^"'']+)["'']')
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    } catch {}

    return $null
}

if ([string]::IsNullOrWhiteSpace($Language) -or ($Language -like '${config:*')) {
    $Language = $null

    # 1. Check workspace settings (.vscode/settings.json)
    $wsSettings = Join-Path $workspaceRoot '.vscode\settings.json'
    $found = Get-LanguageFromSettingsFile -FilePath $wsSettings
    if ($found) {
        $Language = $found
        $languageSource = "workspace settings ($wsSettings)"
    }

    # 2. Check workspace files (*.code-workspace in workspace root or parent)
    if ([string]::IsNullOrWhiteSpace($Language)) {
        $codeWorkspaces = @(
            Get-ChildItem -Path $workspaceRoot -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue
            Get-ChildItem -Path (Join-Path $workspaceRoot '..') -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue
        )
        foreach ($cw in $codeWorkspaces) {
            $found = Get-LanguageFromSettingsFile -FilePath $cw.FullName
            if ($found) {
                $Language = $found
                $languageSource = "workspace file ($($cw.FullName))"
                break
            }
        }
    }

    # 3. Check VS Code / VSCodium User settings & Profiles across platforms
    if ([string]::IsNullOrWhiteSpace($Language)) {
        $userDirs = @(
            $(if ($env:APPDATA) { Join-Path $env:APPDATA 'Code\User' }),
            $(if ($env:APPDATA) { Join-Path $env:APPDATA 'Code - Insiders\User' }),
            $(if ($env:APPDATA) { Join-Path $env:APPDATA 'VSCodium\User' }),
            $(if ($env:HOME) { Join-Path $env:HOME 'Library/Application Support/Code/User' }),
            $(if ($env:HOME) { Join-Path $env:HOME 'Library/Application Support/Code - Insiders/User' }),
            $(if ($env:HOME) { Join-Path $env:HOME 'Library/Application Support/VSCodium/User' }),
            $(if ($env:HOME) { Join-Path $env:HOME '.config/Code/User' }),
            $(if ($env:HOME) { Join-Path $env:HOME '.config/Code - Insiders/User' }),
            $(if ($env:HOME) { Join-Path $env:HOME '.config/VSCodium/User' }),
            $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.config\Code\User' })
        )
        foreach ($uDir in $userDirs) {
            if (-not $uDir -or -not (Test-Path $uDir)) { continue }

            # Check primary user settings.json
            $uPath = Join-Path $uDir 'settings.json'
            $found = Get-LanguageFromSettingsFile -FilePath $uPath
            if ($found) {
                $Language = $found
                $languageSource = "user settings ($uPath)"
                break
            }

            # Check all profile settings.json
            $profileSettings = Get-ChildItem -Path (Join-Path $uDir 'profiles') -Filter 'settings.json' -Recurse -File -ErrorAction SilentlyContinue
            foreach ($ps in $profileSettings) {
                $found = Get-LanguageFromSettingsFile -FilePath $ps.FullName
                if ($found) {
                    $Language = $found
                    $languageSource = "profile settings ($($ps.FullName))"
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($Language)) { break }
        }
    }
} else {
    $languageSource = 'command-line argument'
}

if ([string]::IsNullOrWhiteSpace($Language) -or ($Language -like '${config:*')) {
    $Language = 'en'
    $languageSource = 'default fallback (en)'
}
$sourceRoot = Join-Path $workspaceRoot 'src'
$sourceCore = Join-Path $sourceRoot 'rfsuite'
$sourceAudioRoot = Join-Path $sourceCore 'audio'
$sourceToolEntrypoint = Join-Path $sourceRoot 'main.lua'
$sourceWidgetRoot = Join-Path $sourceRoot 'widgets\rfsuite'
$sourceFunctionRoot = Join-Path $sourceRoot 'functions'

function Test-LikelyRadioRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path $Root)) { return $false }

    $hasScripts = Test-Path (Join-Path $Root 'SCRIPTS')
    $hasSounds = Test-Path (Join-Path $Root 'SOUNDS')
    $hasWidgets = Test-Path (Join-Path $Root 'WIDGETS')

    # Ethos/EdgeTX removable media often expose one of these marker files.
    $hasMarker = (Test-Path (Join-Path $Root 'radio.cpuid')) -or (Test-Path (Join-Path $Root 'sdcard.cpuid')) -or (Test-Path (Join-Path $Root 'flash.cpuid')) -or (Test-Path (Join-Path $Root 'RADIO\radio.yml'))

    if (($hasScripts -and $hasSounds -and $hasWidgets) -or ($hasScripts -and $hasMarker)) {
        return $true
    }

    return $false
}

function Resolve-RadioTargetRoot {
    # Prefer mounted removable roots with Ethos/EdgeTX markers.
    $candidates = @()

    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop
        foreach ($drive in $drives) {
            if (-not $drive.Root) { continue }
            $root = $drive.Root
            if (Test-LikelyRadioRoot -Root $root) {
                $score = 0
                if (Test-Path (Join-Path $root 'radio.cpuid')) { $score += 8 }
                if (Test-Path (Join-Path $root 'sdcard.cpuid')) { $score += 8 }
                if (Test-Path (Join-Path $root 'flash.cpuid')) { $score += 8 }
                if (Test-Path (Join-Path $root 'RADIO\radio.yml')) { $score += 4 }
                if (Test-Path (Join-Path $root 'SCRIPTS\TOOLS')) { $score += 2 }
                if (Test-Path (Join-Path $root 'WIDGETS')) { $score += 1 }
                if (Test-Path (Join-Path $root 'SOUNDS')) { $score += 1 }
                $candidates += [pscustomobject]@{ Root = $root; Score = $score }
            }
        }
    } catch {
        # Fall back to no auto-detected path.
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $best = $candidates | Sort-Object -Property Score -Descending | Select-Object -First 1
    return $best.Root
}

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    if ($Target -eq 'simulator') {
        $TargetRoot = Join-Path $workspaceRoot 'simulator'
    } else {
        $TargetRoot = Resolve-RadioTargetRoot
        if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
            throw "Radio target not auto-detected. Mount the radio USB storage and retry, or set rfsuite.radioSdPath / pass -TargetRoot explicitly."
        }
    }
}

# If VS Code setting substitution did not resolve, treat it as unset.
if (($Target -eq 'radio') -and ($TargetRoot -like '${config:*')) {
    $TargetRoot = Resolve-RadioTargetRoot
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        throw "Radio target not auto-detected. Mount the radio USB storage and retry, or set rfsuite.radioSdPath / pass -TargetRoot explicitly."
    }
}

$TargetRoot = [System.IO.Path]::GetFullPath($TargetRoot)

if (-not (Test-Path $TargetRoot)) {
    throw "Target root not found: $TargetRoot"
}

$toolsRoot = Join-Path $TargetRoot 'SCRIPTS\TOOLS'
$widgetsRoot = Join-Path $TargetRoot 'WIDGETS'
$soundsRoot = Join-Path $TargetRoot 'SOUNDS'

$targetCore = Join-Path $toolsRoot 'rfsuite-core'
$targetToolEntrypoint = Join-Path $toolsRoot 'rfsuite.lua'
$targetUserRoot = Join-Path $toolsRoot 'rfsuite.user'
$targetWidgetRoot = Join-Path $widgetsRoot 'rfsuite'
$targetFunctionRoot = Join-Path $TargetRoot 'SCRIPTS\FUNCTIONS'
$targetSoundsRoot = Join-Path $soundsRoot 'rf'

$legacyToolFolder = Join-Path $toolsRoot 'rfsuite'

if (-not (Test-Path $sourceRoot)) {
    throw "Source folder not found: $sourceRoot"
}

if (-not (Test-Path $sourceCore)) {
    throw "Core source folder not found: $sourceCore"
}

if (-not (Test-Path $sourceToolEntrypoint)) {
    throw "Tool entrypoint not found: $sourceToolEntrypoint"
}

if (-not (Test-Path $sourceWidgetRoot)) {
    throw "Widget source folder not found: $sourceWidgetRoot"
}

if (-not (Test-Path $sourceAudioRoot)) {
    throw "Audio source folder not found: $sourceAudioRoot"
}

if (-not (Test-Path $toolsRoot)) {
    New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
}

if (-not (Test-Path $widgetsRoot)) {
    New-Item -ItemType Directory -Path $widgetsRoot -Force | Out-Null
}

if (-not (Test-Path $soundsRoot)) {
    New-Item -ItemType Directory -Path $soundsRoot -Force | Out-Null
}

if (Test-Path $legacyToolFolder) {
    Remove-Item -Path $legacyToolFolder -Recurse -Force
}

if (Test-Path $targetCore) {
    Remove-Item -Path $targetCore -Recurse -Force
}
New-Item -ItemType Directory -Path $targetCore -Force | Out-Null
Get-ChildItem -Path $sourceCore -Force | Where-Object { $_.Name -ne 'audio' -and $_.Name -ne 'i18n' } | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $targetCore -Recurse -Force
}

# Copy only i18n/init.lua to the target Core since translations are inlined and de.lua/en.lua are no longer needed
$targetI18nDir = Join-Path $targetCore 'i18n'
New-Item -ItemType Directory -Path $targetI18nDir -Force | Out-Null
Copy-Item -Path (Join-Path $sourceCore 'i18n\init.lua') -Destination (Join-Path $targetI18nDir 'init.lua') -Force
Get-ChildItem -Path $targetCore -Filter '*.luac' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Copy-Item -Path $sourceToolEntrypoint -Destination $targetToolEntrypoint -Force

# No preference file is deployed: the suite writes its own store on first save.
if (-not (Test-Path $targetUserRoot)) {
    New-Item -ItemType Directory -Path $targetUserRoot -Force | Out-Null
}

function Get-ThemeMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$ThemeDir,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    $initFile = Join-Path $ThemeDir 'init.lua'
    if (-not (Test-Path $initFile)) {
        return $null
    }

    $content = Get-Content -Path $initFile -Raw
    $nameMatch = [regex]::Match($content, 'name\s*=\s*"([^"]+)"')
    if (-not $nameMatch.Success) {
        return $null
    }

    $configureMatch = [regex]::Match($content, 'configure\s*=\s*"([^"]+)"')
    $standaloneMatch = [regex]::Match($content, 'standalone\s*=\s*(true|false)')

    return [pscustomobject]@{
        name = $nameMatch.Groups[1].Value
        source = $SourceName
        folder = [System.IO.Path]::GetFileName($ThemeDir)
        configure = $(if ($configureMatch.Success) { $configureMatch.Groups[1].Value } else { $null })
        standalone = $(if ($standaloneMatch.Success) { $standaloneMatch.Groups[1].Value -eq 'true' } else { $false })
    }
}

function New-ThemeIndexFile {
    param(
        [Parameter(Mandatory = $true)][string]$TargetCoreDir,
        [Parameter(Mandatory = $true)][string]$TargetUserDir
    )

    $entries = @()

    $systemThemesDir = Join-Path $TargetCoreDir 'widgets\dashboard\themes'
    if (Test-Path $systemThemesDir) {
        Get-ChildItem -Path $systemThemesDir -Directory | ForEach-Object {
            $meta = Get-ThemeMetadata -ThemeDir $_.FullName -SourceName 'system'
            if ($null -ne $meta) { $entries += $meta }
        }
    }

    $userThemesDir = Join-Path $TargetUserDir 'dashboard'
    if (Test-Path $userThemesDir) {
        Get-ChildItem -Path $userThemesDir -Directory | ForEach-Object {
            $meta = Get-ThemeMetadata -ThemeDir $_.FullName -SourceName 'user'
            if ($null -ne $meta) { $entries += $meta }
        }
    }

    $indexFile = Join-Path $TargetCoreDir 'app\pages\settings\dashboard\theme_index.lua'
    $lines = @('return {')
    foreach ($entry in $entries) {
        $safeName = $entry.name.Replace('\', '\\').Replace('"', '\"')
        $safeFolder = $entry.folder.Replace('\', '\\').Replace('"', '\"')
        $configureValue = if ([string]::IsNullOrEmpty($entry.configure)) { 'nil' } else { '"' + $entry.configure.Replace('\', '\\').Replace('"', '\"') + '"' }
        $standaloneValue = if ($entry.standalone) { 'true' } else { 'false' }
        $lines += ('  { name = "' + $safeName + '", source = "' + $entry.source + '", folder = "' + $safeFolder + '", configure = ' + $configureValue + ', standalone = ' + $standaloneValue + ' },')
    }
    $lines += '}'

    Set-Content -Path $indexFile -Value $lines -Encoding ASCII
}

function Copy-LanguageAudioPack {
    param(
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][string]$SourceAudioDir,
        [Parameter(Mandatory = $true)][string]$TargetAudioDir
    )

    $sourceLanguageRoot = Join-Path $SourceAudioDir $Language
    $sourcePack = Join-Path $sourceLanguageRoot 'default'
    if (-not (Test-Path $sourcePack)) {
        $sourcePack = $sourceLanguageRoot
    }

    if (-not (Test-Path $sourcePack)) {
        return
    }

    if (Test-Path $TargetAudioDir) {
        Remove-Item -Path $TargetAudioDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $TargetAudioDir -Force | Out-Null

    foreach ($sub in @('adj', 'app', 'evt', 'stat', 'gov')) {
        $srcSub = Join-Path $sourcePack $sub
        if (Test-Path $srcSub) {
            Copy-Item -Path $srcSub -Destination (Join-Path $TargetAudioDir $sub) -Recurse -Force
        }
    }
}

if (Test-Path $targetWidgetRoot) {
    Remove-Item -Path $targetWidgetRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $targetWidgetRoot -Force | Out-Null
Copy-Item -Path (Join-Path $sourceWidgetRoot '*') -Destination $targetWidgetRoot -Recurse -Force
Get-ChildItem -Path $targetWidgetRoot -Filter '*.luac' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# Special-function scripts. EdgeTX offers every lua file directly under SCRIPTS\FUNCTIONS to a
# "Play Script" special function, so the folder is flat -- and it is not emptied first, because
# a pilot's own scripts live in it too.
if (Test-Path $sourceFunctionRoot) {
    if (-not (Test-Path $targetFunctionRoot)) {
        New-Item -ItemType Directory -Path $targetFunctionRoot -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $sourceFunctionRoot '*.lua') -Destination $targetFunctionRoot -Force
}

if (Test-Path $targetSoundsRoot) {
    Remove-Item -Path $targetSoundsRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $targetSoundsRoot -Force | Out-Null

Copy-LanguageAudioPack -Language 'en' -SourceAudioDir $sourceAudioRoot -TargetAudioDir (Join-Path $targetSoundsRoot 'en')
Copy-LanguageAudioPack -Language 'de' -SourceAudioDir $sourceAudioRoot -TargetAudioDir (Join-Path $targetSoundsRoot 'de')

foreach ($wav in @('beep.wav', 'multibeep.wav', 'warn.wav', 'alarm.wav')) {
    $src = Join-Path $sourceAudioRoot $wav
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $targetSoundsRoot -Force
    }
}

New-ThemeIndexFile -TargetCoreDir $targetCore -TargetUserDir $targetUserRoot

# Run translation pre-compiler and resolver to inline the language strings
Write-Host "Running i18n pre-compiler and resolver for language: $Language (source: $languageSource)"

$pythonCmd = 'python'
if (-not (Get-Command $pythonCmd -ErrorAction SilentlyContinue)) {
    if (Get-Command 'python3' -ErrorAction SilentlyContinue) {
        $pythonCmd = 'python3'
    } elseif (Get-Command 'py' -ErrorAction SilentlyContinue) {
        $pythonCmd = 'py'
    } else {
        $pathsToTry = @(
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe",
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\python3.exe",
            "C:\msys64\ucrt64\bin\python.exe",
            "C:\msys64\usr\bin\python.exe",
            "C:\Python312\python.exe",
            "C:\Python311\python.exe",
            "C:\Python310\python.exe",
            "C:\Program Files\Python312\python.exe",
            "C:\Program Files\Python311\python.exe",
            "C:\Program Files\Python310\python.exe"
        )
        foreach ($p in $pathsToTry) {
            if (Test-Path $p) {
                $pythonCmd = $p
                break
            }
        }
    }
}

& $pythonCmd (Join-Path $workspaceRoot '.vscode\scripts\precompile_i18n.py') --root $toolsRoot
& $pythonCmd (Join-Path $workspaceRoot '.vscode\scripts\precompile_i18n.py') --root $targetWidgetRoot

& $pythonCmd (Join-Path $workspaceRoot '.vscode\scripts\resolve_i18n_tags.py') --json (Join-Path $sourceCore "i18n\$Language.lua") --root $toolsRoot
& $pythonCmd (Join-Path $workspaceRoot '.vscode\scripts\resolve_i18n_tags.py') --json (Join-Path $sourceCore "i18n\$Language.lua") --root $targetWidgetRoot

Write-Host "RFSuite demo deployed to:"
Write-Host "  Target mode:     $Target"
Write-Host "  Target root:     $TargetRoot"
Write-Host "  Language:        $Language ($languageSource)"
Write-Host "  Tool entrypoint: $targetToolEntrypoint"
Write-Host "  Core package:    $targetCore"
Write-Host "  User data:       $targetUserRoot"
Write-Host "  Widget package:  $targetWidgetRoot"
Write-Host "  Function scripts:$targetFunctionRoot"
