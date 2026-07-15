param(
    [Parameter(Mandatory = $true)] [string] $WorkDirectory,
    [Parameter(Mandatory = $true)] [int] $TimeoutSeconds
)

$ErrorActionPreference = 'Stop'
$payloadDirectory = Join-Path $WorkDirectory 'payload'
$archivePath = Join-Path $WorkDirectory 'tests.tar.gz'
$resultArchivePath = Join-Path $WorkDirectory 'test-results.tar.gz'

Remove-Item -Recurse -Force $payloadDirectory -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $payloadDirectory | Out-Null
tar.exe -xf $archivePath -C $payloadDirectory
if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract $archivePath"
}

$failed = $false
$testResults = @()
Push-Location $payloadDirectory
try {
    foreach ($testExecutable in Get-Content 'tests.txt') {
        $testName = [System.IO.Path]::GetFileNameWithoutExtension($testExecutable)
        $testResultPath = Join-Path $payloadDirectory "${testName}.TestJUnit.xml"
        $testPassed = $false
        Write-Host "Running $testName..."
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $process.StartInfo.FileName = Join-Path $payloadDirectory $testExecutable
        $process.StartInfo.Arguments = "--gtest_output=`"xml:$testResultPath`""
        $process.StartInfo.WorkingDirectory = $payloadDirectory
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.EnvironmentVariables['GTEST_OUTPUT'] = "xml:$testResultPath"
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void] $process.Start()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            Write-Error "$testName timed out after $TimeoutSeconds seconds" -ErrorAction Continue
            $testResults += "$testName TIMED_OUT"
            $failed = $true
        }
        else {
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                Write-Error "$testName failed with exit code $($process.ExitCode)" -ErrorAction Continue
                $testResults += "$testName FAILED $($process.ExitCode)"
                $failed = $true
            }
            else {
                $testPassed = $true
            }
        }
        $standardOutput.Result | Set-Content "$testName.stdout.log"
        $standardError.Result | Set-Content "$testName.stderr.log"
        if (-not (Test-Path $testResultPath)) {
            Write-Error "$testName did not produce $testResultPath" -ErrorAction Continue
            $testResults += "$testName MISSING_JUNIT"
            $failed = $true
        }
        elseif ($testPassed) {
            $testResults += "$testName PASSED"
        }
    }

    $testResults | Set-Content 'test-results.txt'
    Remove-Item -Force $resultArchivePath -ErrorAction SilentlyContinue
    $resultFiles = @('test-results.txt')
    $resultFiles += Get-ChildItem -Name '*.TestJUnit.xml'
    $resultFiles += Get-ChildItem -Name '*.log'
    tar.exe -czf $resultArchivePath $resultFiles
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create $resultArchivePath"
    }
}
finally {
    Pop-Location
}

if ($failed) {
    exit 1
}
