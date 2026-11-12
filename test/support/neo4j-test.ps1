[CmdletBinding()]
param(
  [switch]$Keep,
  [string[]]$Tests = @(
    "test/integration/repeat_import_test.rb",
    "test/integration/source_materialisation_test.rb"
  )
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$CacheDir = Join-Path $RepoRoot "tmp/neo4j-cache"
$RunDir = Join-Path $RepoRoot ("tmp/neo4j-test-" + [guid]::NewGuid().ToString("N"))
$HttpPort = 17687
$BoltPort = 17688

$Neo4jVersion = "5.26.0"
$Neo4jUrl = "https://dist.neo4j.org/neo4j-community-$Neo4jVersion-windows.zip"
$Neo4jSha256 = "EA9C98111B72310DAB8AE00B7AE4D43DF59A1EA82A490579B886BFFB3E30DE8F"

$JreVersion = "21.0.13+9"
$JreUrl = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip"
$JreSha256 = "2332C0B4CFF6BED722DA3567C91D5E47568BCBA863FA4945D0A8D6FC76158628"

function Get-CachedArchive {
  param([string]$Url, [string]$Path, [string]$Sha256)

  if (Test-Path $Path) {
    if ((Get-FileHash $Path -Algorithm SHA256).Hash -eq $Sha256) { return }
    Remove-Item $Path -Force
  }

  New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
  $partial = "$Path.partial"
  Write-Host "Downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
  $actual = (Get-FileHash $partial -Algorithm SHA256).Hash
  if ($actual -ne $Sha256) {
    Remove-Item $partial -Force
    throw "Checksum mismatch for $Url (expected $Sha256, got $actual)"
  }
  Move-Item -Force $partial $Path
}

function Resolve-JavaHome {
  if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin/java.exe"))) {
    return $env:JAVA_HOME
  }
  if (Get-Command java.exe -ErrorAction SilentlyContinue) {
    return $null
  }

  $jreZip = Join-Path $CacheDir "OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip"
  Get-CachedArchive -Url $JreUrl -Path $jreZip -Sha256 $JreSha256
  $jreRoot = Join-Path $CacheDir "jre-$JreVersion"
  if (-not (Test-Path $jreRoot)) {
    Expand-Archive -Path $jreZip -DestinationPath $CacheDir -Force
    $extracted = Get-ChildItem $CacheDir -Directory |
      Where-Object { $_.Name -like "jdk-21*-jre" } |
      Select-Object -First 1
    if (-not $extracted) { throw "Could not find the extracted JRE" }
    Move-Item $extracted.FullName $jreRoot
  }
  $java = Get-ChildItem $jreRoot -Filter java.exe -Recurse | Select-Object -First 1
  if (-not $java) { throw "Could not find java.exe in $jreRoot" }
  return $java.Directory.Parent.FullName
}

$Neo4jHome = $null
$server = $null
$TestExitCode = 1

try {
  New-Item -ItemType Directory -Force -Path $CacheDir, $RunDir | Out-Null
  $neo4jZip = Join-Path $CacheDir "neo4j-community-$Neo4jVersion-windows.zip"
  Get-CachedArchive -Url $Neo4jUrl -Path $neo4jZip -Sha256 $Neo4jSha256

  $javaHome = Resolve-JavaHome
  if ($javaHome) {
    $env:JAVA_HOME = $javaHome
    $env:PATH = "$javaHome\bin;$env:PATH"
  }

  Expand-Archive -Path $neo4jZip -DestinationPath $RunDir -Force
  $Neo4jHome = Join-Path $RunDir "neo4j-community-$Neo4jVersion"
  if (-not (Test-Path (Join-Path $Neo4jHome "bin/neo4j.bat"))) {
    throw "Neo4j distribution did not extract as expected"
  }

  @"

server.default_listen_address=127.0.0.1
server.http.listen_address=127.0.0.1:$HttpPort
server.https.enabled=false
server.bolt.listen_address=127.0.0.1:$BoltPort
server.memory.heap.initial_size=512m
server.memory.heap.max_size=1g
server.memory.pagecache.size=256m
dbms.usage_report.enabled=false
"@ | Set-Content -Encoding utf8NoBOM (Join-Path $Neo4jHome "conf/neo4j.conf")

  $password = [guid]::NewGuid().ToString("N")
  & (Join-Path $Neo4jHome "bin/neo4j-admin.bat") dbms set-initial-password $password
  if ($LASTEXITCODE -ne 0) { throw "Could not set the disposable Neo4j password" }

  Write-Host "Starting disposable Neo4j on 127.0.0.1:$HttpPort"
  if (Get-NetTCPConnection -State Listen -LocalPort $HttpPort, $BoltPort -ErrorAction SilentlyContinue) {
    throw "A disposable Neo4j port is already in use"
  }
  $server = Start-Process -FilePath (Join-Path $Neo4jHome "bin/neo4j.bat") -ArgumentList "console" `
    -WorkingDirectory $Neo4jHome -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $RunDir "stdout.log") `
    -RedirectStandardError (Join-Path $RunDir "stderr.log")

  $client = [System.Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromSeconds(2)
  $ready = $false
  for ($attempt = 0; $attempt -lt 90; $attempt++) {
    if ($server.HasExited) {
      Get-Content (Join-Path $RunDir "stderr.log") -Tail 20
      throw "Disposable Neo4j exited before it became ready"
    }
    try {
      $response = $client.GetAsync("http://127.0.0.1:$HttpPort/").GetAwaiter().GetResult()
      if ([int]$response.StatusCode -in 200, 401) { $ready = $true; break }
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  $client.Dispose()
  if (-not $ready) { throw "Neo4j did not become ready on 127.0.0.1:$HttpPort" }

  $env:NEO4J_HTTP_URL = "http://127.0.0.1:$HttpPort"
  $env:NEO4J_USER = "neo4j"
  $env:NEO4J_PASSWORD = $password
  $env:NEO4J_DATABASE = "neo4j"
  $env:NEO4J_TEST_DISPOSABLE = "1"

  Push-Location $RepoRoot
  try {
    $TestExitCode = 0
    foreach ($test in $Tests) {
      Write-Host "Running $test against the disposable Neo4j"
      & bundle exec ruby $test
      if ($LASTEXITCODE -ne 0) { $TestExitCode = $LASTEXITCODE }
    }
  } finally {
    Pop-Location
  }
} finally {
  if ($server) {
    Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like "*$Neo4jHome*" } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (!$server.HasExited) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
  }
  if (-not $Keep -and (Test-Path $RunDir)) {
    Start-Sleep -Seconds 2
    $resolvedRun = (Resolve-Path -LiteralPath $RunDir).Path
    if ($resolvedRun -eq $RunDir -and (Split-Path $resolvedRun) -eq (Join-Path $RepoRoot "tmp")) {
      Remove-Item -LiteralPath $resolvedRun -Recurse -Force
    }
  } elseif ($Keep) {
    Write-Host "Kept disposable Neo4j directory: $RunDir"
  }
}

exit $TestExitCode
