param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Uninstall')]
    [string] $Action,
    [string] $Package
)

$ErrorActionPreference = 'Stop'
$serviceName = 'SpQuizWorker'
$displayName = 'SP Quiz Worker'
$installDir = Join-Path $env:ProgramData $displayName
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this command in an administrator PowerShell to manage the Windows service.'
}

function Invoke-ServiceControl([string[]] $Arguments) {
    & "$env:SystemRoot/System32/sc.exe" @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Service Control Manager returned $LASTEXITCODE."
    }
}

$registered = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
$installedExe = Join-Path $installDir 'SpQuizWorker.exe'
if ($Action -eq 'Uninstall') {
    if (!$registered) { return }
    if ($registered.PathName -ne ('"' + $installedExe + '"')) {
        throw 'The registered service is outside the SP installation directory.'
    }
    if ((Get-Service $serviceName).Status -ne 'Stopped') {
        Stop-Service -Name $serviceName
        (Get-Service $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    Invoke-ServiceControl @('delete', $serviceName)
    return
}

if ($registered) { throw 'SP Quiz Worker is already registered.' }
if (!$Package) { throw 'Supply the full path to the published worker package.' }
$packagePath = (Resolve-Path -LiteralPath $Package).Path
$packageExe = Join-Path $packagePath 'SpQuizWorker.exe'
$packageConfig = Join-Path $packagePath 'worker.private.json'
if (!(Test-Path -LiteralPath $packageExe -PathType Leaf)) {
    throw 'The service executable is missing from the package.'
}
$config = Get-Content -Raw -LiteralPath $packageConfig | ConvertFrom-Json
$ollamaDir = Split-Path (Resolve-Path -LiteralPath $config.ollama_executable).Path
$modelsDir = (Resolve-Path -LiteralPath $config.ollama_models).Path
if (!(Test-Path -LiteralPath (Join-Path $modelsDir 'manifests') -PathType Container)) {
    throw 'The supplied Ollama directory has no installed model manifests.'
}
if (Test-Path -LiteralPath $installDir) {
    $existing = Get-Item -LiteralPath $installDir -Force
    if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The SP service directory points outside ProgramData.'
    }
} else {
    New-Item -ItemType Directory -Path $installDir | Out-Null
}
& icacls.exe $installDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX'
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the service installation directory.' }

Copy-Item -LiteralPath $packageExe -Destination $installedExe
foreach ($dependency in Get-ChildItem -LiteralPath $packagePath -Filter '*.dll' -File) {
    Copy-Item -LiteralPath $dependency.FullName -Destination $installDir
}
$installedOllama = Join-Path $installDir 'runtime'
$installedModels = Join-Path $installDir 'models'
foreach ($copy in @(@{From=$ollamaDir; To=$installedOllama}, @{From=$modelsDir; To=$installedModels})) {
    & robocopy.exe $copy.From $copy.To /E /XJ /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) { throw 'Could not copy the Ollama runtime or model files.' }
}
& icacls.exe $installedModels /grant:r '*S-1-5-19:(OI)(CI)M'
if ($LASTEXITCODE -ne 0) { throw 'Could not set the model directory permissions.' }
$config.ollama_executable = Join-Path $installedOllama 'ollama.exe'
$config.ollama_models = $installedModels
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installDir 'worker.private.json') -Encoding UTF8
if (![Diagnostics.EventLog]::SourceExists($displayName)) {
    [Diagnostics.EventLog]::CreateEventSource($displayName, 'Application')
}
# SCM needs literal quotes in ImagePath. Preserve them when calling sc.exe
# from either Windows PowerShell or PowerShell 7.
$create = [Diagnostics.ProcessStartInfo]::new()
$create.FileName = Join-Path $env:SystemRoot 'System32/sc.exe'
$create.Arguments = 'create SpQuizWorker binPath= "\"' + $installedExe +
    '\"" start= auto obj= "NT AUTHORITY\LocalService" DisplayName= "SP Quiz Worker"'
$create.UseShellExecute = $false
$create.CreateNoWindow = $true
$create.RedirectStandardOutput = $true
$process = [Diagnostics.Process]::Start($create)
try {
    $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Windows Service Control Manager returned $($process.ExitCode)."
    }
} finally {
    $process.Dispose()
}
try {
    Invoke-ServiceControl @('failure', $serviceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/15000/restart/30000')
    Invoke-ServiceControl @('failureflag', $serviceName, '1')
    Start-Service -Name $serviceName
    (Get-Service $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Get-Service -Name $serviceName
} catch {
    if ((Get-Service $serviceName).Status -eq 'Stopped') {
        Invoke-ServiceControl @('delete', $serviceName)
    }
    throw
}
