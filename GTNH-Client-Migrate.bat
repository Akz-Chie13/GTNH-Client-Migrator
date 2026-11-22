@echo off
setlocal DisableDelayedExpansion
set "GTNH_MIGRATE_BAT=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$text = [IO.File]::ReadAllText($env:GTNH_MIGRATE_BAT, [Text.Encoding]::UTF8); $parts = $text -split '(?m)^:GTNH_BAT_PAYLOAD\r?$', 2; if ($parts.Count -ne 2) { throw 'Invalid BAT payload.' }; & ([ScriptBlock]::Create($parts[1]))"
set "GTNH_MIGRATE_EXIT=%errorlevel%"
pause
exit /b %GTNH_MIGRATE_EXIT%
:GTNH_BAT_PAYLOAD

$migrationEngine = [ScriptBlock]::Create(@'

[CmdletBinding(DefaultParameterSetName = 'Preview')]
param(
    [string]$SourceInstance,
    [string]$TargetInstance,
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [switch]$Apply,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')]
    [ValidatePattern('^\d{8}-\d{6}-[0-9a-f]{8}$')]
    [string]$Rollback
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$personalFiles = @('options.txt', 'optionsnf.txt', 'servers.dat')
$personalFolders = @('journeymap\config', 'journeymap\data', 'journeymap\icon',
    'visualprospecting', 'TCNodeTracker', 'saves\NEI\global')

function Get-DataFiles([string]$Path) {
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsupported link: $($item.FullName)" }
        if ($item.PSIsContainer) { Get-DataFiles $item.FullName }
        else { $item.FullName }
    }
}

function Get-DataHash([string]$Path) {
    if ([IO.Directory]::Exists($Path)) { throw "Expected a file, found a directory: $Path" }
    if ([IO.File]::Exists($Path)) {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '') }
            finally { $algorithm.Dispose() }
        } finally { $stream.Dispose() }
    }
    return ''
}

function Copy-DataFile([string]$From, [string]$To) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($To))
    [IO.File]::Copy($From, $To)
}

function Install-DataFile([string]$Staged, [string]$Destination, [bool]$Exists) {
    if ($Exists) {
        [IO.File]::Replace($Staged, $Destination, [System.Management.Automation.Language.NullString]::Value, $true)
    } else {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
        [IO.File]::Move($Staged, $Destination)
    }
}

function Undo-Changes($Entries, [string]$Backup, [string]$Game) {
    $restore = @(foreach ($entry in $Entries) {
        $relative = [string]$entry.Path
        $allowed = $relative -in $personalFiles -or @($personalFolders | Where-Object {
            $relative.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if (!$allowed) { throw "Unexpected migration entry: $relative" }

        $destination = Get-SafePath $Game $relative
        $current = Get-DataHash $destination
        if ($current -eq $entry.Before) { continue }
        if ($current -ne $entry.After) { throw "File changed since migration: $relative" }

        $original = Get-SafePath $Backup "before\$relative"
        if ($entry.Before -and (Get-DataHash $original) -ne $entry.Before) {
            throw "Backup is missing or damaged: $relative"
        }
        [pscustomobject]@{ Destination = $destination; Original = $original; Entry = $entry }
    })

    foreach ($file in $restore) {
        if ((Get-DataHash $file.Destination) -ne $file.Entry.After) {
            throw "File changed during rollback: $($file.Entry.Path)"
        }
        if ($file.Entry.Before) {
            $temporary = Join-Path $Backup ([guid]::NewGuid().ToString('N') + '.tmp')
            Copy-DataFile $file.Original $temporary
            try { Install-DataFile $temporary $file.Destination $true }
            finally { [IO.File]::Delete($temporary) }
        } else {
            [IO.File]::Delete($file.Destination)
        }
    }
    return $restore.Count
}

$target = Get-PrismInstance $TargetInstance
$backupRoot = Get-SafePath $target.Root '.gtnh-migration'
if (!$Rollback) {
    $source = Get-PrismInstance $SourceInstance
    if ($source.Root -eq $target.Root) { throw 'Choose two different Prism instances.' }
    Write-Host "来源 GTNH $($source.Version)：$($source.Root)"
    Write-Host "目标 GTNH $($target.Version)：$($target.Root)"
}

$sha = [Security.Cryptography.SHA256]::Create()
try {
    $mutexId = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($target.Root.ToUpperInvariant()))).Replace('-', '')
} finally { $sha.Dispose() }
$mutex = [Threading.Mutex]::new($false, "Local\GTNH-Client-Migrate-$mutexId")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another migration is using this target instance.' }

    if ($Rollback) {
        $backup = Get-SafePath $backupRoot $Rollback
        $manifest = Get-Content -LiteralPath (Get-SafePath $backup 'manifest.json') -Raw | ConvertFrom-Json
        if ($manifest.Target -ne $target.Root) { throw 'This backup belongs to another instance.' }
        $restored = Undo-Changes $manifest.Files $backup $target.Game
        Write-Host "回滚完成，已还原或撤销 $restored 个文件。"
        return
    }

    $found = @(foreach ($relative in $personalFiles) {
        $path = Get-SafePath $source.Game $relative
        if ([IO.File]::Exists($path)) { [pscustomobject]@{ Category = $relative; Path = $path } }
    }
    foreach ($relative in $personalFolders) {
        $path = Get-SafePath $source.Game $relative
        if ([IO.Directory]::Exists($path)) {
            foreach ($file in Get-DataFiles $path) { [pscustomobject]@{ Category = $relative; Path = $file } }
        }
    })

    $plan = @(foreach ($file in $found) {
        $relative = $file.Path.Substring($source.Game.Length + 1)
        $destination = Get-SafePath $target.Game $relative
        $before = Get-DataHash $destination
        $after = Get-DataHash $file.Path
        if (!$after) { throw "Source file disappeared: $relative" }
        $action = if ($before -eq $after) { 'Unchanged' } elseif ($before) { 'Replace' } else { 'Add' }
        [pscustomobject]@{ Path = $relative; Category = $file.Category; Action = $action; Before = $before; After = $after }
    })

    $plan | Group-Object Category | ForEach-Object {
        [pscustomobject]@{
            Data = $_.Name
            Add = @($_.Group | Where-Object Action -eq 'Add').Count
            Replace = @($_.Group | Where-Object Action -eq 'Replace').Count
            Unchanged = @($_.Group | Where-Object Action -eq 'Unchanged').Count
        }
    } | Format-Table -AutoSize | Out-Host

    $changes = @($plan | Where-Object Action -ne 'Unchanged')
    if (!$changes.Count) { Write-Host '个人文件已一致，无需复制。'; return }
    if (!$Apply -or (Read-Host '请先关闭 Minecraft。输入 Y 开始迁移，直接回车取消') -ne 'Y') {
        Write-Host '已取消迁移。'
        return
    }

    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backup = Get-SafePath $backupRoot $id
    [void][IO.Directory]::CreateDirectory($backup)
    foreach ($entry in $changes) {
        $inputFile = Join-Path $source.Game $entry.Path
        $incoming = Join-Path $backup "incoming\$($entry.Path)"
        Copy-DataFile $inputFile $incoming
        if ((Get-DataHash $incoming) -ne $entry.After) { throw "Source changed during copy: $($entry.Path)" }
        if ($entry.Before) {
            $original = Join-Path $backup "before\$($entry.Path)"
            Copy-DataFile (Get-SafePath $target.Game $entry.Path) $original
            if ((Get-DataHash $original) -ne $entry.Before) { throw "Target changed during backup: $($entry.Path)" }
        }
    }
    [pscustomobject]@{ Target = $target.Root; Files = $changes } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8

    $applied = [Collections.Generic.List[object]]::new()
    try {
        foreach ($entry in $changes) {
            $destination = Get-SafePath $target.Game $entry.Path
            if ((Get-DataHash $destination) -ne $entry.Before) { throw "Target changed during migration: $($entry.Path)" }
            Install-DataFile (Join-Path $backup "incoming\$($entry.Path)") $destination ([bool]$entry.Before)
            $applied.Add($entry)
        }
    } catch {
        Write-Warning "Migration interrupted. Backup ID: $id"
        try { [void](Undo-Changes $applied $backup $target.Game) }
        catch { Write-Warning "Automatic rollback could not finish: $_" }
        throw
    }

    Write-Host "已迁移 $($applied.Count) 个文件。备份目录：$backup"
    Write-Host "如需撤销，重新打开此 BAT 并选择回滚。备份编号：$id"
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

'@)

function Get-SafePath([string]$Root, [string]$Relative) {
    $parts = $Relative -split '\\'
    $path = $Root
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part = $parts[$i]
        if (!$part -or $part -in '.', '..' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Invalid path segment: $part"
        }
        $path = [IO.Path]::Combine($path, $part)
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($i -lt $parts.Count - 1 -and !$item.PSIsContainer))) {
            throw "Unsupported path: $path"
        }
    }
    return $path
}

function Get-PrismInstance([string]$Path) {
    $root = Get-Item -LiteralPath $Path -Force
    if (!$root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ![IO.File]::Exists((Get-SafePath $root.FullName 'instance.cfg'))) {
        throw "不是有效的 Prism 实例目录：$Path"
    }
    foreach ($folder in '.minecraft', 'minecraft') {
        $game = Get-SafePath $root.FullName $folder
        foreach ($marker in @(
            @{ Path = 'config\DreamCoreMod.properties'; Key = 'displayedModpackVersion' },
            @{ Path = 'config\GTNewHorizons\dreamcraft.cfg'; Key = 'S:ModPackVersion' }
        )) {
            $properties = Get-SafePath $game $marker.Path
            if (![IO.File]::Exists($properties)) { continue }
            $pattern = '(?m)^\s*' + [regex]::Escape($marker.Key) + '\s*=\s*([^\r\n]+)'
            $version = [regex]::Match([IO.File]::ReadAllText($properties), $pattern)
            if ($version.Success) {
                return [pscustomobject]@{
                    Root = $root.FullName
                    Game = $game
                    Name = $root.Name
                    Version = $version.Groups[1].Value.Trim()
                }
            }
        }
    }
    throw "找不到 GTNH 版本信息：$Path"
}

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if ([Console]::IsInputRedirected) { [Console]::InputEncoding = [Text.UTF8Encoding]::new($false) }
if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }

function Find-Instances([string]$Path) {
    $path = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (![IO.Directory]::Exists($path)) { return }
    $root = (Get-Item -LiteralPath $path).FullName
    $config = Join-Path $root 'prismlauncher.cfg'
    if ([IO.File]::Exists($config)) {
        $match = [regex]::Match([IO.File]::ReadAllText($config), '(?m)^InstanceDir=([^\r\n]+)')
        if ($match.Success) {
            $configured = [Environment]::ExpandEnvironmentVariables($match.Groups[1].Value.Trim(' ', '"'))
            if (![IO.Path]::IsPathRooted($configured)) { $configured = Join-Path $root $configured }
            if ([IO.Directory]::Exists($configured)) { return (Get-Item -LiteralPath $configured).FullName }
        }
    }
    $standard = Join-Path $root 'instances'
    if ([IO.Directory]::Exists($standard)) { return (Get-Item -LiteralPath $standard).FullName }

    foreach ($folder in Get-ChildItem -LiteralPath $root -Directory -Force) {
        if ([IO.File]::Exists((Join-Path $folder.FullName 'instance.cfg'))) { return $root }
    }

    if ($env:APPDATA -and [IO.File]::Exists((Join-Path $root 'prismlauncher.exe')) -and
        ![IO.File]::Exists((Join-Path $root 'portable.txt'))) {
        $data = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'PrismLauncher'))
        if ($data -ne $root) { Find-Instances $data }
    }
}

function Get-WindowsDownloadsDirectory {
    $knownFolders = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $downloads = Get-ItemPropertyValue -LiteralPath $knownFolders -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction SilentlyContinue
    if ($downloads) {
        $resolved = [Environment]::ExpandEnvironmentVariables($downloads)
        if ([IO.Directory]::Exists($resolved)) { return $resolved }
    }
    if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' }
}

function Find-PortablePrismRoots([IO.DirectoryInfo]$Directory, [int]$Depth) {
    if (!$Directory -or ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
    $path = $Directory.FullName
    if ($Directory.Name -like 'PrismLauncher*' -or
        [IO.File]::Exists((Join-Path $path 'prismlauncher.exe')) -or
        [IO.File]::Exists((Join-Path $path 'portable.txt'))) {
        $path
    }
    if ($Depth -gt 0) {
        foreach ($child in Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue) {
            Find-PortablePrismRoots $child ($Depth - 1)
        }
    }
}

function Get-PrismInstanceLocations([string]$Downloads) {
    $candidates = @(
        Split-Path -LiteralPath $env:GTNH_MIGRATE_BAT
        foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA, $env:USERPROFILE)) {
            if ($base) { Join-Path $base 'PrismLauncher' }
        }
        if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\PrismLauncher' }
        $installDir = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\PrismLauncher' -Name 'InstallDir' -ErrorAction SilentlyContinue
        if ($installDir) { $installDir }

        if ([IO.Directory]::Exists($Downloads)) {
            Find-PortablePrismRoots (Get-Item -LiteralPath $Downloads) 2
        }
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq [IO.DriveType]::Fixed) {
                Find-PortablePrismRoots $drive.RootDirectory 1
            }
        }
    )
    $locations = foreach ($candidate in ($candidates | Select-Object -Unique)) {
        try { Find-Instances $candidate } catch { continue }
    }
    $locations | Select-Object -Unique
}

function Read-Choice([string]$Prompt, [int]$Count) {
    while ($true) {
        $value = Read-Host $Prompt
        if ($value -eq 'Q' -or !$value) { return -1 }
        $number = 0
        if ([int]::TryParse($value, [ref]$number) -and $number -ge 1 -and $number -le $Count) {
            return ($number - 1)
        }
        Write-Host '请输入列表内的编号，或输入 Q 返回。'
    }
}

function Select-Instance($Instances, [string]$Prompt) {
    for ($i = 0; $i -lt $Instances.Count; $i++) {
        $item = $Instances[$i]
        Write-Host ('  {0}. {1}  [GTNH {2}]' -f ($i + 1), $item.Name, $item.Version)
    }
    $index = Read-Choice $Prompt $Instances.Count
    if ($index -ge 0) { return $Instances[$index] }
}

function Run-MigrationMenu {
    Write-Host 'GTNH 客户端迁移工具'
    Write-Host '1. 预览并迁移    2. 回滚    Q. 退出'
    $mode = Read-Choice '选择操作' 2
    if ($mode -lt 0) { return }

    $locations = @(Get-PrismInstanceLocations (Get-WindowsDownloadsDirectory))

    for ($i = 0; $i -lt $locations.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $locations[$i]) }
    $prompt = if ($locations.Count -eq 1) { '回车使用已找到的目录，或粘贴 Prism/instances 路径，Q 退出' }
              else { '选择目录编号或粘贴 Prism/instances 路径，Q 退出' }
    do {
        $answer = Read-Host $prompt
        if ($answer -eq 'Q' -or $null -eq $answer) { return }
        $number = 0
        if (!$answer -and $locations.Count -eq 1) { $root = $locations[0] }
        elseif ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $locations.Count) {
            $root = $locations[$number - 1]
        } else {
            try { $root = Find-Instances $answer } catch { $root = $null }
        }
        if (!$root) { Write-Host '找不到实例目录，请检查路径。' }
    } until ($root)

    $instances = @(foreach ($folder in (Get-ChildItem -LiteralPath $root -Directory -Force | Sort-Object Name)) {
        try { Get-PrismInstance $folder.FullName } catch { continue }
    })
    if ($mode -eq 0) {
        if ($instances.Count -lt 2) { throw '需要至少两个已导入的 GTNH 实例。' }
        $source = Select-Instance $instances '选择旧实例，Q 退出'
        if (!$source) { return }
        $targets = @($instances | Where-Object Root -ne $source.Root)
        $target = Select-Instance $targets '选择新实例，Q 退出'
        if (!$target) { return }
        Write-Host '预览：Add 为新增，Replace 为覆盖并备份，Unchanged 为内容相同。'
        & $migrationEngine -SourceInstance $source.Root -TargetInstance $target.Root -Apply
    } else {
        if (!$instances.Count) { throw '此目录下没有 GTNH 实例。' }
        $target = Select-Instance $instances '选择要回滚的目标实例，Q 退出'
        if (!$target) { return }
        $backupRoot = Get-SafePath $target.Root '.gtnh-migration'
        if (![IO.Directory]::Exists($backupRoot)) { throw '此实例没有迁移备份。' }
        $backups = @(Get-ChildItem -LiteralPath $backupRoot -Directory -Force | Where-Object {
            $_.Name -match '^\d{8}-\d{6}-[0-9a-f]{8}$' -and
                !($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                [IO.File]::Exists((Join-Path $_.FullName 'manifest.json'))
        } | Sort-Object Name -Descending)
        if (!$backups.Count) { throw '此实例没有完整的迁移备份。' }
        for ($i = 0; $i -lt $backups.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $backups[$i].Name) }
        $index = Read-Choice '选择备份编号，Q 退出' $backups.Count
        if ($index -lt 0) { return }
        if ((Read-Host '请先关闭 Minecraft。输入 Y 回滚，直接回车取消') -ne 'Y') {
            Write-Host '已取消回滚。'
            return
        }
        & $migrationEngine -TargetInstance $target.Root -Rollback $backups[$index].Name
    }
}

try { Run-MigrationMenu }
catch {
    Write-Host "操作失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
