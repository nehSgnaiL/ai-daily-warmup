param(
  [string] $ConfigPath = "config\default.env",
  [switch] $Schedule
)

$ErrorActionPreference = "Stop"

function Add-PathDirectory {
  param([string] $Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path -LiteralPath $Path -PathType Container)) {
    return
  }

  $separator = [System.IO.Path]::PathSeparator
  $parts = @($env:PATH -split [Regex]::Escape([string] $separator) | Where-Object { $_ -ne "" })
  if ($parts -notcontains $Path) {
    $env:PATH = $Path + $separator + $env:PATH
  }
}

# Schedulers often start with a minimal PATH. Add common per-user CLI install
# locations so configured wrappers can still resolve provider commands.
Add-PathDirectory (Join-Path $HOME ".npm-global\bin")
Add-PathDirectory (Join-Path $HOME ".local\bin")
Add-PathDirectory (Join-Path $HOME "bin")
if (![string]::IsNullOrWhiteSpace($env:APPDATA)) {
  Add-PathDirectory (Join-Path $env:APPDATA "npm")
}

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
  $configDir = Split-Path -Parent $resolvedPrimaryPath
  $repoRoot = Split-Path -Parent $configDir
  return Join-Path $repoRoot "local\local.env"
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

function Get-PositiveIntegerConfig {
  param(
    [hashtable] $Config,
    [string] $Key,
    [int] $Default
  )

  $value = 0
  if ([int]::TryParse((Get-ConfigValue $Config $Key ([string] $Default)), [ref] $value) -and $value -gt 0) {
    return $value
  }

  return $Default
}

function Get-ScheduleHours {
  param([hashtable] $Config)

  return (Get-ConfigValue $Config "WARMUP_HOURS" "8,13,18").Split(",") | ForEach-Object {
    $hourText = $_.Trim()
    if ($hourText -ne "") {
      $hour = [int] $hourText
      if ($hour -ge 0 -and $hour -le 23) {
        $hour
      }
    }
  }
}

function Get-CurrentScheduleSlot {
  param([hashtable] $Config)

  if ((Get-ConfigValue $Config "WARMUP_SCHEDULE_ENABLED" "true") -ne "true") {
    return "always"
  }

  $timeZone = Get-ConfigValue $Config "WARMUP_TIMEZONE" ([System.TimeZoneInfo]::Local.Id)
  $targetZone = Resolve-TimeZone $timeZone
  $now = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $targetZone)
  $catchupMinutes = [int] (Get-ConfigValue $Config "WARMUP_SLOT_CATCHUP_MINUTES" "60")
  if ($catchupMinutes -lt 0) {
    $catchupMinutes = 60
  }

  $nowMinutes = ($now.Hour * 60) + $now.Minute
  $bestDelta = 1441
  $bestHour = $null
  foreach ($hour in (Get-ScheduleHours $Config)) {
    $targetMinutes = $hour * 60
    $delta = ($nowMinutes - $targetMinutes + 1440) % 1440
    if ($delta -le $catchupMinutes -and $delta -lt $bestDelta) {
      $bestDelta = $delta
      $bestHour = $hour
    }
  }

  if ($null -eq $bestHour) {
    return ""
  }

  $slotDate = $now.AddMinutes(-1 * $bestDelta)
  return "{0:yyyy-MM-dd}-{1:D2}" -f $slotDate, $bestHour
}

function Get-WarmupStatePath {
  param([hashtable] $Config)

  $configured = Get-ConfigValue $Config "WARMUP_STATE_PATH"
  if (![string]::IsNullOrWhiteSpace($configured)) {
    return Expand-UserPath $configured
  }

  $logPath = Get-WarmupLogPath $Config
  $logDir = Split-Path -Parent $logPath
  return Join-Path $logDir "warmup.state"
}

function Read-WarmupState {
  param([hashtable] $Config)

  $state = @{}
  $statePath = Get-WarmupStatePath $Config
  if (!(Test-Path -LiteralPath $statePath)) {
    return $state
  }

  foreach ($line in Get-Content -LiteralPath $statePath) {
    $parts = $line.Split("=", 2)
    if ($parts.Count -eq 2) {
      $state[$parts[0]] = $parts[1]
    }
  }

  return $state
}

function Write-WarmupState {
  param(
    [hashtable] $Config,
    [string] $Slot
  )

  if ((Get-ConfigValue $Config "WARMUP_SCHEDULE_ENABLED" "true") -ne "true") {
    return
  }
  if ([string]::IsNullOrWhiteSpace($Slot) -or $Slot -eq "always") {
    return
  }

  $statePath = Get-WarmupStatePath $Config
  $stateDir = Split-Path -Parent $statePath
  if (![string]::IsNullOrWhiteSpace($stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
  }

  $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  Set-Content -LiteralPath $statePath -Value @(
    "LAST_TRIGGER_SLOT=$Slot",
    "LAST_TRIGGER_EPOCH=$nowEpoch"
  )
}

function Test-ScheduledWindow {
  param([hashtable] $Config)

  $script:CurrentScheduleSlot = ""
  $script:ScheduleSkipReason = ""

  $slot = Get-CurrentScheduleSlot $Config
  if ([string]::IsNullOrWhiteSpace($slot)) {
    $script:ScheduleSkipReason = "outside_schedule"
    return $false
  }
  if ($slot -eq "always") {
    $script:CurrentScheduleSlot = $slot
    return $true
  }

  $state = Read-WarmupState $Config
  if ($state.ContainsKey("LAST_TRIGGER_SLOT") -and $state["LAST_TRIGGER_SLOT"] -eq $slot) {
    $script:ScheduleSkipReason = "already_triggered"
    return $false
  }

  $minMinutes = [int] (Get-ConfigValue $Config "WARMUP_MIN_WINDOW_MINUTES" "300")
  if ($minMinutes -lt 0) {
    $minMinutes = 300
  }
  if ($state.ContainsKey("LAST_TRIGGER_EPOCH") -and $minMinutes -gt 0) {
    $lastEpoch = [int64] $state["LAST_TRIGGER_EPOCH"]
    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($nowEpoch -lt ($lastEpoch + ($minMinutes * 60))) {
      $script:ScheduleSkipReason = "previous_window"
      return $false
    }
  }

  $script:CurrentScheduleSlot = $slot
  return $true
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
    $latestRows = Get-Content -LiteralPath $logPath -Tail (Get-PositiveIntegerConfig $Config "WARMUP_LOG_MAX_ROWS" 200)
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
    $script:LastProviderSucceeded = $true
    return
  }

  if (!(Test-CommandPath $commandPath)) {
    Write-Warning "[$Provider] Command not found: $commandPath"
    Add-WarmupLog $Config $Provider "skip" "command_not_found" 0 0 "Command not found: $commandPath."
    $script:LastProviderSucceeded = $true
    return
  }

  $providerEnv = @{}
  if (![string]::IsNullOrWhiteSpace($envFile)) {
    if (!(Test-Path -LiteralPath $envFile)) {
      Write-Warning "[$Provider] Env file not found: $envFile"
      Add-WarmupLog $Config $Provider "skip" "missing_env_file" 0 0 "Env file not found: $envFile."
      $script:LastProviderSucceeded = $true
      return
    }
    $providerEnv = Read-WarmupConfig $envFile
  }

  $args = Get-ProviderArgs $Provider $args $model $prompt

  $providerEnv["GITHUB_TOKEN"] = $null

  Write-Host "[$Provider] Sending warmup prompt..."
  $status = 0
  $startTime = Get-Date
  $outputPath = [System.IO.Path]::GetTempFileName()
  $script:ProviderExitCode = 0
  Add-WarmupLog $Config $Provider "start" "running" 0 0 "Starting warmup command."
  try {
    Invoke-InTempDirectory {
      Invoke-WithEnvironment $providerEnv {
        if ($Provider -eq "claude") {
          $prompt | & $commandPath @args 2>&1 | Tee-Object -FilePath $outputPath
        }
        else {
          & $commandPath @args 2>&1 | Tee-Object -FilePath $outputPath
        }
        if ($LASTEXITCODE -is [int]) {
          $script:ProviderExitCode = $LASTEXITCODE
        }
        else {
          $script:ProviderExitCode = if ($?) { 0 } else { 1 }
        }
        if ($script:ProviderExitCode -ne 0) {
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
    $script:LastProviderSucceeded = $true
  }
  catch {
    $durationSeconds = [int] [Math]::Max(0, ((Get-Date) - $startTime).TotalSeconds)
    if ($script:ProviderExitCode -is [int]) {
      $status = $script:ProviderExitCode
    }
    else {
      $status = 1
    }
    $failureDetail = "No provider output captured."
    if (Test-Path -LiteralPath $outputPath) {
      $lineCount = Get-PositiveIntegerConfig $Config "WARMUP_FAILURE_LOG_LINES" 20
      $captured = (Get-Content -LiteralPath $outputPath -Tail $lineCount -ErrorAction SilentlyContinue) -join " "
      $captured = ($captured -replace "[`t`r`n]+", " ") -replace "\s+", " "
      $captured = $captured.Trim()
      if (![string]::IsNullOrWhiteSpace($captured)) {
        $failureDetail = $captured
      }
    }
    Write-Warning "[$Provider] Warmup failed: $($_.Exception.Message)"
    Add-WarmupLog $Config $Provider "finish" "failed" $status $durationSeconds "Warmup failed: $($_.Exception.Message). Output tail: $failureDetail"
    $script:LastProviderSucceeded = $false
  }
  finally {
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
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
  if (!(Test-ScheduledWindow $Config)) {
    switch ($script:ScheduleSkipReason) {
      "previous_window" {
        Write-Host "[local] Waiting for the next 5-hour window before triggering."
        Add-WarmupLog $Config "local" "skip" "previous_window" 0 0 "Last trigger is still inside the minimum window interval."
        Add-WarmupLog $Config "local" "finish" "complete" 0 0 "Warmup run deferred until the next window."
      }
      "already_triggered" {
        Write-Host "[local] Current schedule slot already triggered."
        Add-WarmupLog $Config "local" "skip" "already_triggered" 0 0 "Current schedule slot already triggered."
        Add-WarmupLog $Config "local" "finish" "complete" 0 0 "Warmup run finished for an already triggered slot."
      }
      default {
        Write-Host "[local] Current time is outside configured schedule."
        Add-WarmupLog $Config "local" "skip" "outside_schedule" 0 0 "Current time is outside configured schedule."
        Add-WarmupLog $Config "local" "finish" "complete" 0 0 "Warmup run finished outside schedule."
      }
    }
    return
  }

  $allProvidersSucceeded = $true
  $providers = (Get-ConfigValue $Config "WARMUP_PROVIDERS" "codex").Split(",")
  foreach ($provider in $providers) {
    $providerName = $provider.Trim().ToLowerInvariant()
    if ($providerName -ne "") {
      $script:LastProviderSucceeded = $true
      Invoke-ProviderWarmup $providerName $Config
      if (!$script:LastProviderSucceeded) {
        $allProvidersSucceeded = $false
      }
    }
  }
  if ($allProvidersSucceeded) {
    Write-WarmupState $Config $script:CurrentScheduleSlot
    Add-WarmupLog $Config "local" "finish" "complete" 0 0 "Warmup run finished."
  }
  else {
    Add-WarmupLog $Config "local" "finish" "failed" 1 0 "One or more provider warmups failed; schedule slot was left retryable."
    throw "One or more provider warmups failed."
  }
}

try {
  $script:LoadedLocalConfigPath = ""
  $config = Read-MergedWarmupConfig $ConfigPath
}
catch {
  $fallbackConfig = @{
    "WARMUP_LOG_PATH" = "./logs/warmup.log"
    "WARMUP_LOG_MAX_ROWS" = "200"
  }
  Add-WarmupLog $fallbackConfig "local" "init_error" "failed" 1 0 $_.Exception.Message
  throw
}

if ($Schedule) {
  while ($true) {
    $slot = Get-CurrentScheduleSlot $config
    $state = Read-WarmupState $config
    $lastSlot = if ($state.ContainsKey("LAST_TRIGGER_SLOT")) { $state["LAST_TRIGGER_SLOT"] } else { "" }
    if (![string]::IsNullOrWhiteSpace($slot) -and $slot -ne $lastSlot) {
      Invoke-WarmupOnce $config
    }

    $pollSeconds = [int] (Get-ConfigValue $config "WARMUP_POLL_SECONDS" "60")
    if ($pollSeconds -lt 10) {
      $pollSeconds = 10
    }
    Start-Sleep -Seconds $pollSeconds
  }
}

Invoke-WarmupOnce $config
