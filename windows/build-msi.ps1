param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [string]$ProfileDirectory,
    [Parameter(Mandatory = $true)]
    [string]$ConanConfigDirectory,
    [Parameter(Mandatory = $true)]
    [string]$TargetConanProfile,
    [Parameter(Mandatory = $true)]
    [string]$BuildConanProfile,
    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory,
    [string]$BuildMode = "DEV",
    [string]$BuildProduct = "ENTERPRISE",
    [int]$Concurrency = 12,
    [string]$WixVersion = "5.0.2",
    [string]$ArtifactoryTunnelHost = "",
    [int]$ArtifactoryTunnelPort = 0,
    [string]$ConanCredentialDatabase = "",
    [switch]$BootstrapTools
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host "> $Command $($Arguments -join ' ')"
    & $Command @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command"
    }
}

function Find-VisualStudioInstallation {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "Visual Studio Installer (vswhere.exe) was not found. Install Visual Studio 2022 using the repository .vsconfig."
    }

    $installationPath = & $vswhere -latest -version "[17.0,18.0)" -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $installationPath) {
        throw "Visual Studio 2022 with the x86/x64 C++ toolchain was not found."
    }

    return $installationPath.Trim()
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:PATH = "$machinePath;$userPath"
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [string]$Override = ""
    )

    $arguments = @(
        "install", "--id", $Id, "--exact", "--silent", "--disable-interactivity",
        "--accept-package-agreements", "--accept-source-agreements"
    )
    if ($Override) {
        $arguments += @("--override", $Override)
    }
    Invoke-NativeCommand "winget.exe" $arguments
}

function Initialize-BuildTools {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        Install-WingetPackage "Microsoft.VisualStudio.2022.BuildTools" (
            "--wait --passive --norestart " +
            "--add Microsoft.VisualStudio.Workload.VCTools " +
            "--add Microsoft.VisualStudio.Component.VC.ATL " +
            "--add Microsoft.VisualStudio.Component.VC.CMake.Project " +
            "--add Microsoft.VisualStudio.Component.Windows11SDK.26100 " +
            "--includeRecommended"
        )
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $python -or $python.Source -like "*WindowsApps*") {
        Install-WingetPackage "Python.Python.3.12"
    }
    if (-not (Get-Command dotnet.exe -ErrorAction SilentlyContinue)) {
        Install-WingetPackage "Microsoft.DotNet.SDK.8"
    }
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Install-WingetPackage "Git.Git"
    }
    if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
        Install-WingetPackage "OpenJS.NodeJS.LTS"
    }

    Refresh-ProcessPath
}

function Import-VisualStudioEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallationPath
    )

    $vcvarsall = Join-Path $InstallationPath "VC\Auxiliary\Build\vcvarsall.bat"
    if (-not (Test-Path $vcvarsall)) {
        throw "vcvarsall.bat was not found at $vcvarsall"
    }

    $environmentLines = & cmd.exe /d /s /c "`"$vcvarsall`" x64_x86 >nul && set"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load the Visual Studio x64-to-x86 build environment."
    }

    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf("=")
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }

    $cmakeDirectory = Join-Path $InstallationPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
    $ninjaDirectory = Join-Path $InstallationPath "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
    $env:PATH = "$cmakeDirectory;$ninjaDirectory;$env:PATH"
}

function Resolve-Wix {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $wixCommand = Get-Command wix.exe -ErrorAction SilentlyContinue
    if ($wixCommand) {
        $wixExecutable = $wixCommand.Source
    }
    else {
        $wixExecutable = Join-Path $ToolDirectory "wix.exe"
    }

    if (-not (Test-Path $wixExecutable)) {
        $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        if (-not $dotnetCommand) {
            throw "WiX was not found and dotnet is unavailable. Install WiX $Version or the .NET SDK."
        }

        New-Item -ItemType Directory -Force -Path $ToolDirectory | Out-Null
        Invoke-NativeCommand $dotnetCommand.Source @(
            "tool", "install", "wix", "--tool-path", $ToolDirectory, "--version", $Version
        )
    }

    Invoke-NativeCommand $wixExecutable @(
        "extension", "add", "-g", "WixToolset.Util.wixext/$Version"
    )
    Invoke-NativeCommand $wixExecutable @(
        "extension", "add", "-g", "WixToolset.UI.wixext/$Version"
    )

    return $wixExecutable
}

function Initialize-PythonEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapPython,
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentDirectory,
        [Parameter(Mandatory = $true)]
        [string]$RequirementsFile
    )

    $pythonExecutable = Join-Path $EnvironmentDirectory "Scripts\python.exe"
    if (-not (Test-Path $pythonExecutable)) {
        Invoke-NativeCommand $BootstrapPython @("-m", "venv", $EnvironmentDirectory)
    }

    Invoke-NativeCommand $pythonExecutable @(
        "-m", "pip", "install",
        "--require-hashes",
        "--no-build-isolation",
        "--use-deprecated=legacy-resolver",
        "pip", "setuptools",
        "-c", $RequirementsFile
    )
    Invoke-NativeCommand $pythonExecutable @(
        "-m", "pip", "install",
        "--require-hashes",
        "--no-build-isolation",
        "-r", $RequirementsFile
    )
    Invoke-NativeCommand $pythonExecutable @("-m", "pip", "install", "conan>=1,<2")

    return $pythonExecutable
}

function Enable-ArtifactoryTunnel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [string]$ConanHome
    )

    $hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
    $remotesPath = Join-Path $ConanHome "remotes.json"
    $hostsContent = [IO.File]::ReadAllText($hostsPath)
    $remotesContent = [IO.File]::ReadAllText($remotesPath)

    [IO.File]::AppendAllText($hostsPath, "`r`n127.0.0.1 $HostName`r`n")

    if ($Port -ne 443) {
        $remotes = $remotesContent | ConvertFrom-Json
        foreach ($remote in $remotes.remotes) {
            $remote.url = $remote.url -replace "https://$([regex]::Escape($HostName))", "https://${HostName}:$Port"
        }
        $remotes | ConvertTo-Json -Depth 10 | Set-Content -Path $remotesPath -Encoding UTF8
    }

    return [PSCustomObject]@{
        HostsPath = $hostsPath
        HostsContent = $hostsContent
        RemotesPath = $remotesPath
        RemotesContent = $remotesContent
    }
}

function Restore-ArtifactoryTunnel {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    [IO.File]::WriteAllText($State.HostsPath, $State.HostsContent)
    [IO.File]::WriteAllText($State.RemotesPath, $State.RemotesContent)
}

function Enable-ConanCredentials {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDatabase,
        [Parameter(Mandatory = $true)]
        [string]$ConanHome,
        [Parameter(Mandatory = $true)]
        [string]$BackupDirectory,
        [Parameter(Mandatory = $true)]
        [string]$PythonExecutable,
        [string]$TunnelHost = "",
        [int]$TunnelPort = 0
    )

    $destinationDatabase = Join-Path $ConanHome ".conan.db"
    $backupDatabase = Join-Path $BackupDirectory "conan-database-backup-$PID.db"
    $hadExistingDatabase = Test-Path $destinationDatabase
    if ($hadExistingDatabase) {
        Copy-Item $destinationDatabase $backupDatabase -Force
    }
    Copy-Item $SourceDatabase $destinationDatabase -Force

    if ($TunnelHost -and $TunnelPort -gt 0 -and $TunnelPort -ne 443) {
        $updateRemoteScript = "import sqlite3, sys; database, host, port = sys.argv[1:]; " +
            "source_url = f'https://{host}'; tunnel_url = f'{source_url}:{port}'; " +
            "connection = sqlite3.connect(database); " +
            "connection.execute('UPDATE users_remotes SET remote_url = replace(remote_url, ?, ?)', " +
            "(source_url, tunnel_url)); connection.commit(); connection.close()"
        Invoke-NativeCommand $PythonExecutable @(
            "-c", $updateRemoteScript, $destinationDatabase, $TunnelHost, $TunnelPort.ToString()
        )
    }

    return [PSCustomObject]@{
        SourceDatabase = $SourceDatabase
        DestinationDatabase = $destinationDatabase
        BackupDatabase = $backupDatabase
        HadExistingDatabase = $hadExistingDatabase
    }
}

function Restore-ConanCredentials {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State
    )

    Remove-Item $State.DestinationDatabase -Force -ErrorAction SilentlyContinue
    if ($State.HadExistingDatabase -and (Test-Path $State.BackupDatabase)) {
        Move-Item $State.BackupDatabase $State.DestinationDatabase -Force
    }
    Remove-Item $State.SourceDatabase -Force -ErrorAction SilentlyContinue
}

$sourceDirectory = Join-Path $WorkDirectory "source-$PID"
$artifactDirectory = Join-Path $WorkDirectory "artifacts"
$toolDirectory = Join-Path $WorkDirectory "tools\wix"

if (Test-Path $artifactDirectory) {
    Remove-Item -Recurse -Force $artifactDirectory
}

New-Item -ItemType Directory -Force -Path $sourceDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
Invoke-NativeCommand "tar.exe" @("-xf", $ArchivePath, "-C", $sourceDirectory)

if ($BootstrapTools) {
    Initialize-BuildTools
}

$conanProfileDirectory = Join-Path $env:USERPROFILE ".conan\profiles"
New-Item -ItemType Directory -Force -Path $conanProfileDirectory | Out-Null
Copy-Item (Join-Path $ProfileDirectory $TargetConanProfile) $conanProfileDirectory -Force
Copy-Item (Join-Path $ProfileDirectory $BuildConanProfile) $conanProfileDirectory -Force

$conanHomeDirectory = Join-Path $env:USERPROFILE ".conan"
Copy-Item (Join-Path $ConanConfigDirectory "*") $conanHomeDirectory -Recurse -Force

$visualStudioInstallation = Find-VisualStudioInstallation
Import-VisualStudioEnvironment $visualStudioInstallation

$bootstrapPython = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $bootstrapPython) {
    throw "Python was not found. Install Python 3.12 and add it to PATH."
}
if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) {
    throw "CMake was not found in the Visual Studio installation."
}
if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) {
    throw "Ninja was not found in the Visual Studio installation."
}

$wixExecutable = Resolve-Wix $toolDirectory $WixVersion
$env:WIX5 = Split-Path $wixExecutable -Parent
$env:PATH = "$env:WIX5;$env:PATH"

$buildDirectory = Join-Path $sourceDirectory "build32"
$pythonExecutable = Initialize-PythonEnvironment `
    $bootstrapPython.Source `
    (Join-Path $WorkDirectory "venv") `
    (Join-Path $sourceDirectory "scripts\requirements.txt")
$env:PATH = "$(Split-Path $pythonExecutable -Parent);$env:PATH"

$artifactoryTunnelState = $null
$conanCredentialState = $null
if ($ConanCredentialDatabase) {
    $conanCredentialState = Enable-ConanCredentials `
        $ConanCredentialDatabase `
        $conanHomeDirectory `
        $WorkDirectory `
        $pythonExecutable `
        $ArtifactoryTunnelHost `
        $ArtifactoryTunnelPort
}
if ($ArtifactoryTunnelHost -and $ArtifactoryTunnelPort -gt 0) {
    $artifactoryTunnelState = Enable-ArtifactoryTunnel `
        $ArtifactoryTunnelHost `
        $ArtifactoryTunnelPort `
        $conanHomeDirectory
}

Push-Location $sourceDirectory
try {
    Invoke-NativeCommand $pythonExecutable @(
        "scripts\configure.py",
        "--build_dir", $buildDirectory,
        "--build_mode", $BuildMode,
        "--build_product", $BuildProduct,
        "--profile", $TargetConanProfile,
        "--build_conan_profile", $BuildConanProfile,
        "--use_default_cmake_defines",
        "--cmake_add_define", "USE_PCH", "OFF",
        "--cmake_add_define", "Python_EXECUTABLE", $pythonExecutable,
        "--concurrency", $Concurrency.ToString(),
        "--fresh"
    )

    Invoke-NativeCommand $pythonExecutable @(
        "scripts\build.py",
        "--build_dir", $buildDirectory,
        "--build_mode", $BuildMode,
        "--build_product", $BuildProduct,
        "--build_config", "Release",
        "--arch", "32",
        "--concurrency", $Concurrency.ToString(),
        "--target", "all",
        "--target", "installer"
    )
}
finally {
    Pop-Location
    if ($artifactoryTunnelState) {
        Restore-ArtifactoryTunnel $artifactoryTunnelState
    }
    if ($conanCredentialState) {
        Restore-ConanCredentials $conanCredentialState
    }
}

$msiFiles = @(Get-ChildItem (Join-Path $buildDirectory "installer\win") -Filter "*.msi" -File)
if ($msiFiles.Count -ne 1) {
    throw "Expected one MSI in the x86 installer output, found $($msiFiles.Count)."
}

$msi = $msiFiles[0]
Copy-Item $msi.FullName (Join-Path $artifactDirectory "artifact.msi") -Force
Set-Content -Path (Join-Path $artifactDirectory "artifact-name.txt") -Value $msi.Name -NoNewline
Write-Host "MSI ready: $($msi.FullName)"
