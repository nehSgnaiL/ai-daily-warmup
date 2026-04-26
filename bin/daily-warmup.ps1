param(
  [string] $ConfigPath = "config\default.env",
  [switch] $Schedule
)

$ErrorActionPreference = "Stop"

function Resolve-ConfigPath {
  param([string] $Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return Join-Path (Get-Location) $Path
}

function Expand-UserPath {
  param([string] $Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $Path
  }

  if ($Path -eq "~") {
    return $HOME
  }

  if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) {
    return Join-Path $HOME $Path.Substring(2)
  }

  return $Path
}

function Read-WarmupConfig {
  param([string] $Path)

  $resolvedPath = Resolve-ConfigPath $Path
  if (!(Test-Path -LiteralPath $resolvedPath)) {
    throw "Config file not found: $resolvedPath"
  }

  $config = @{}
  foreach ($line in Get-Content -LiteralPath $resolvedPath) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
      continue
    }

    $parts = $trimmed.Split("=", 2)
    if ($parts.Count -ne 2) {
      continue
    }

    $key = $parts[0].Trim()
    $value = $parts[1].Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $config[$key] = $value
  }

  return $config
}

function Merge-WarmupConfig {
  param(
    [hashtable] $Base,
    [hashtable] $Override
  )

  foreach ($key in $Override.Keys) {
    $Base[$key] = $Override[$key]
  }

  return $Base
}

function Get-LocalConfigPath {
  param([string] $PrimaryConfigPath)

  if (![string]::IsNullOrWhiteSpace($env:WARMUP_LOCAL_CONFIG_PATH)) {
    return Resolve-ConfigPath $env:WARMUP_LOCAL_CONFIG_PATH
  }

  $resolvedPrimaryPath = Resolve-ConfigPath $PrimaryConfigPath
  return Join-Path (Split-Path -Parent $resolvedPrimaryPath) "local.env"
}

function Read-MergedWarmupConfig {
  param([string] $Path)

  $config = Read-WarmupConfig $Path
  $script:LoadedLocalConfigPath = ""

  $localConfigPath = Get-LocalConfigPath $Path
  if (Test-Path -LiteralPath $localConfigPath) {
    $config = Merge-WarmupConfig $config (Read-WarmupConfig $localConfigPath)
    $script:LoadedLocalConfigPath = $localConfigPath
  }

  return $config
}

function Invoke-WithEnvironment {
  param(
    [hashtable] $Environment,
    [scriptblock] $Script
  )

  $previous = @{}
  foreach ($key in $Environment.Keys) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
    [Environment]::SetEnvironmentVariable($key, $Environment[$key], "Process")
  }

  try {
    & $Script
  }
  finally {
    foreach ($key in $Environment.Keys) {
      [Environment]::SetEnvironmentVariable($key, $previous[$key], "Process")
    }
  }
}

function Resolve-TimeZone {
  param([string] $TimeZone)

  $fallbacks = @{
    "Asia/Hong_Kong" = "China Standard Time"
    "Asia/Shanghai" = "China Standard Time"
    "America/Los_Angeles" = "Pacific Standard Time"
    "America/New_York" = "Eastern Standard Time"
    "Europe/London" = "GMT Standard Time"
  }

  try {
    return [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
  }
  catch {
    if ($fallbacks.ContainsKey($TimeZone)) {
      return [System.TimeZoneInfo]::FindSystemTimeZoneById($fallbacks[$TimeZone])
    }
    throw
  }
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

function Test-ScheduledHour {
  param([hashtable] $Config)

  if ((Get-ConfigValue $Config "WARMUP_SCHEDULE_ENABLED" "true") -ne "true") {
    return $true
  }

  $timeZone = Get-ConfigValue $Config "WARMUP_TIMEZONE" ([System.TimeZoneInfo]::Local.Id)
  $targetZone = Resolve-TimeZone $timeZone
  $now = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $targetZone)
  $hours = (Get-ConfigValue $Config "WARMUP_HOURS" "8,13,18").Split(",") | ForEach-Object { [int] $_.Trim() }
  return $hours -contains $now.Hour
}

function Test-CommandPath {
  param([string] $Path)

  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or $Path.Contains("/")) {
    return Test-Path -LiteralPath (Expand-UserPath $Path)
  }

  return $null -ne (Get-Command $Path -ErrorAction SilentlyContinue)
}

function Split-Args {
  param([string] $ArgsText)

  if ([string]::IsNullOrWhiteSpace($ArgsText)) {
    return @()
  }

  return $ArgsText.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
}

function Get-ProviderArgs {
  param(
    [string] $Provider,
    [array] $Args,
    [string] $Model,
    [string] $Prompt
  )

  $result = @($Args)
  $firstArg = if ($result.Count -gt 0) { $result[0] } else { "" }

  switch ($Provider) {
    "codex" {
      if ($firstArg -ne "exec" -and $firstArg -ne "e") {
        $result = @("exec", "--skip-git-repo-check", "--ephemeral") + $result
      }
      if (![string]::IsNullOrWhiteSpace($Model)) {
        $result += @("--model", $Model)
      }
      $result += $Prompt
    }
    "gemini" {
      if (![string]::IsNullOrWhiteSpace($Model)) {
        $result += @("--model", $Model)
      }
      if (($result -notcontains "--prompt") -and ($result -notcontains "-p")) {
        $result += @("--prompt", $Prompt)
      }
    }
    "claude" {
      if (![string]::IsNullOrWhiteSpace($Model)) {
        $result += @("--model", $Model)
      }
    }
    default {
      if (![string]::IsNullOrWhiteSpace($Model)) {
        $result += @("--model", $Model)
      }
      $result += $Prompt
    }
  }

  return $result
}

function Get-WarmupLogPath {
  param([hashtable] $Config)

  return Expand-UserPath (Get-ConfigValue $Config "WARMUP_LOG_PATH" "./logs/warmup.log")
}

function Add-WarmupLog {
  param(
    [hashtable] $Config,
    [string] $Provider,
    [string] $Event,
    [string] $Result,
    [int] $Status,
    [int] $DurationSeconds = 0,
    [string] $Message = ""
  )

  $logPath = Get-WarmupLogPath $Config
  if ([string]::IsNullOrWhiteSpace($logPath)) {
    return
  }

  $logDir = Split-Path -Parent $logPath
  try {
    if (![string]::IsNullOrWhiteSpace($logDir)) {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $targetZone = Resolve-TimeZone (Get-ConfigValue $Config "WARMUP_TIMEZONE" ([System.TimeZoneInfo]::Local.Id))
    $timestamp = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $targetZone).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $cleanMessage = $Message -replace "[`t`r`n]+", " "
    Add-Content -LiteralPath $logPath -Value "$timestamp`t$Provider`t$Event`t$Result`t$Status`t$DurationSeconds`t$cleanMessage"
    $latestRows = Get-Content -LiteralPath $logPath -Tail 100
    Set-Content -LiteralPath $logPath -Value $latestRows
  }
  catch {
    Write-Warning "[local] Could not write log file: $logPath"
  }
}

function Invoke-InTempDirectory {
  param(
    [scriptblock] $Script,
    [string] $WorkDirectory = ""
  )

  $removeRunDir = $false
  if ([string]::IsNullOrWhiteSpace($WorkDirectory)) {
    $runDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $runDir | Out-Null
    $removeRunDir = $true
  }
  else {
    $runDir = Expand-UserPath $WorkDirectory
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
  }

  try {
    Push-Location $runDir
    & $Script
  }
  finally {
    Pop-Location
    if ($removeRunDir) {
      Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-ProviderWarmup {
  param(
    [string] $Provider,
    [hashtable] $Config
  )

  $prefix = $Provider.ToUpperInvariant()
  $prompt = Get-ConfigValue $Config "WARMUP_PROMPT" "Warmup. Don't think, just reply: OK"
  $commandPath = Expand-UserPath (Get-ConfigValue $Config "${prefix}_PATH" $Provider)
  $credentialPath = Expand-UserPath (Get-ConfigValue $Config "${prefix}_CREDENTIAL_PATH")
  $envFile = Expand-UserPath (Get-ConfigValue $Config "${prefix}_ENV_FILE")
  $workDirectory = Expand-UserPath (Get-ConfigValue $Config "${prefix}_WORKDIR")
  $args = Split-Args (Get-ConfigValue $Config "${prefix}_ARGS")
  $model = Get-ConfigValue $Config "${prefix}_MODEL"

  if (![string]::IsNullOrWhiteSpace($credentialPath) -and !(Test-Path -LiteralPath $credentialPath)) {
    Write-Warning "[$Provider] No credentials found at $credentialPath. Run the CLI login first."
    Add-WarmupLog $Config $Provider "skip" "missing_credentials" 0 0 "No credentials found at $credentialPath."
    return
  }

  if (!(Test-CommandPath $commandPath)) {
    Write-Warning "[$Provider] Command not found: $commandPath"
    Add-WarmupLog $Config $Provider "skip" "command_not_found" 0 0 "Command not found: $commandPath."
    return
  }

  $providerEnv = @{}
  if (![string]::IsNullOrWhiteSpace($envFile)) {
    if (!(Test-Path -LiteralPath $envFile)) {
      Write-Warning "[$Provider] Env file not found: $envFile"
      Add-WarmupLog $Config $Provider "skip" "missing_env_file" 0 0 "Env file not found: $envFile."
      return
    }
    $providerEnv = Read-WarmupConfig $envFile
  }

  $args = Get-ProviderArgs $Provider $args $model $prompt

  $providerEnv["GITHUB_TOKEN"] = $null

  Write-Host "[$Provider] Sending warmup prompt..."
  $status = 0
  $startTime = Get-Date
  Add-WarmupLog $Config $Provider "start" "running" 0 0 "Starting warmup command."
  try {
    Invoke-InTempDirectory {
      Invoke-WithEnvironment $providerEnv {
        if ($Provider -eq "claude") {
          $prompt | & $commandPath @args
        }
        else {
          & $commandPath @args
        }
        if (!$?) {
          if ($LASTEXITCODE -is [int]) {
            throw "Command exited with status $LASTEXITCODE."
          }
          throw "Command failed."
        }
      }
    } -WorkDirectory $workDirectory
    $durationSeconds = [int] [Math]::Max(0, ((Get-Date) - $startTime).TotalSeconds)
    Write-Host "[$Provider] Warmup complete."
    Add-WarmupLog $Config $Provider "finish" "success" $status $durationSeconds "Warmup complete."
  }
  catch {
    $durationSeconds = [int] [Math]::Max(0, ((Get-Date) - $startTime).TotalSeconds)
    if ($LASTEXITCODE -is [int]) {
      $status = $LASTEXITCODE
    }
    else {
      $status = 1
    }
    Write-Warning "[$Provider] Warmup failed: $($_.Exception.Message)"
    Add-WarmupLog $Config $Provider "finish" "failed" $status $durationSeconds "Warmup failed: $($_.Exception.Message)"
  }
}

function Invoke-WarmupOnce {
  param([hashtable] $Config)

  if (![string]::IsNullOrWhiteSpace($script:LoadedLocalConfigPath)) {
    Add-WarmupLog $Config "local" "init" "started" 0 0 "Warmup run started. Config: $ConfigPath; local override: $script:LoadedLocalConfigPath."
  }
  else {
    Add-WarmupLog $Config "local" "init" "started" 0 0 "Warmup run started. Config: $ConfigPath; no local override."
  }
  if (!(Test-ScheduledHour $Config)) {
    Write-Host "[local] Current hour is outside configured schedule."
    Add-WarmupLog $Config "local" "skip" "outside_schedule" 0 0 "Current hour is outside configured schedule."
    Add-WarmupLog $Config "local" "finish" "complete" 0 0 "Warmup run finished outside schedule."
    return
  }

  $providers = (Get-ConfigValue $Config "WARMUP_PROVIDERS" "codex").Split(",")
  foreach ($provider in $providers) {
    $providerName = $provider.Trim().ToLowerInvariant()
    if ($providerName -ne "") {
      Invoke-ProviderWarmup $providerName $Config
    }
  }
  Add-WarmupLog $Config "local" "finish" "complete" 0 0 "Warmup run finished."
}

try {
  $script:LoadedLocalConfigPath = ""
  $config = Read-MergedWarmupConfig $ConfigPath
}
catch {
  $fallbackConfig = @{
    "WARMUP_LOG_PATH" = "./logs/warmup.log"
  }
  Add-WarmupLog $fallbackConfig "local" "init_error" "failed" 1 0 $_.Exception.Message
  throw
}

if ($Schedule) {
  $lastRunKey = ""
  while ($true) {
    $targetZone = Resolve-TimeZone (Get-ConfigValue $config "WARMUP_TIMEZONE" ([System.TimeZoneInfo]::Local.Id))
    $now = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $targetZone)
    $runKey = "{0:yyyy-MM-dd-HH}" -f $now

    if ((Test-ScheduledHour $config) -and $runKey -ne $lastRunKey) {
      Invoke-WarmupOnce $config
      $lastRunKey = $runKey
    }

    $pollSeconds = [int] (Get-ConfigValue $config "WARMUP_POLL_SECONDS" "60")
    if ($pollSeconds -lt 10) {
      $pollSeconds = 10
    }
    Start-Sleep -Seconds $pollSeconds
  }
}

Invoke-WarmupOnce $config
