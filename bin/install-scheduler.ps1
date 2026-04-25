param(
  [string] $ConfigPath = "config\default.env",
  [string] $TaskName = "ai-daily-warmup",
  [switch] $Uninstall
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$runnerPath = Join-Path $repoRoot "bin\daily-warmup.ps1"

function Resolve-RepoPath {
  param([string] $Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return Join-Path $repoRoot $Path
}

function Read-WarmupConfig {
  param([string] $Path)

  $resolvedPath = Resolve-RepoPath $Path
  if (!(Test-Path -LiteralPath $resolvedPath)) {
    throw "Config file not found: $resolvedPath"
  }

  $config = @{}
  foreach ($line in Get-Content -LiteralPath $resolvedPath) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "" -or $trimmed.StartsWith("#") -or !$trimmed.Contains("=")) {
      continue
    }

    $parts = $trimmed.Split("=", 2)
    $key = $parts[0].Trim()
    $value = $parts[1].Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $config[$key] = $value
  }

  return $config
}

function Get-ConfigValue {
  param(
    [hashtable] $Config,
    [string] $Key,
    [string] $Default = ""
  )

  if ($Config.ContainsKey($Key)) {
    return $Config[$Key]
  }

  return $Default
}

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Removed scheduled task: $TaskName"
  exit 0
}

if (!(Test-Path -LiteralPath $runnerPath)) {
  throw "Runner not found: $runnerPath"
}

$config = Read-WarmupConfig $ConfigPath
$hours = (Get-ConfigValue $config "WARMUP_HOURS" "8,13,18").Split(",") | ForEach-Object {
  $hour = [int] $_.Trim()
  if ($hour -lt 0 -or $hour -gt 23) {
    throw "Invalid hour in WARMUP_HOURS: $hour"
  }
  $hour
}

$resolvedConfigPath = Resolve-RepoPath $ConfigPath
$powerShellPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($powerShellPath)) {
  $powerShellPath = (Get-Command powershell -ErrorAction Stop).Source
}

$argument = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`" -ConfigPath `"$resolvedConfigPath`""
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $argument -WorkingDirectory $repoRoot
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today)
$trigger.Repetition.Interval = "PT1H"
$trigger.Repetition.Duration = "P1D"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Warm up configured AI CLIs." -Force | Out-Null

Write-Host "Installed scheduled task: $TaskName"
Write-Host "Warmup hours from config: $($hours -join ', ')"
