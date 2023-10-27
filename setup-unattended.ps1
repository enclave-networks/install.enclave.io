#
# This script will silently install or update enclave on a Windows system.
#
[CmdletBinding()]
param (
    [Parameter(HelpMessage = "The enclave enrolment key to use when enrolling")]
    [string]
    $EnrolmentKey
)

# Hide progress bars to speed up downloads
$ProgressPreference = 'SilentlyContinue';
$ErrorActionPreference = 'Stop';

$manifestDoc = Invoke-WebRequest -Uri "https://install.enclave.io/manifest/windows/setup-unattended-msi.json" -UseBasicParsing | ConvertFrom-Json;

$latestGaRelease = $manifestDoc.ReleaseVersions | Where-Object ReleaseType -EQ "GA" | Select-Object -Last 1;

$newEnclaveVersion = "$($latestGaRelease.MajorVersion).$($latestGaRelease.MinorVersion).$($latestGaRelease.BuildVersion).$($latestGaRelease.RevisionVersion)";

$ErrorActionPreference = 'SilentlyContinue';

$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles);

$enclaveBinaryPath = "$programFiles\Enclave Networks\Enclave\Agent\bin\enclave.exe";
$enclaveTrayPath = "$programFiles\Enclave Networks\Enclave\Agent\bin\enclave-tray.exe";

$existingEnclaveVersion = $(get-command $enclaveBinaryPath);

$existingEnclaveVersion = ($existingEnclaveVersion.Version).ToString();

$ErrorActionPreference = 'Stop';

if ($newEnclaveVersion -ne $existingEnclaveVersion)
{
    # We need to install.
    # Get the architecture
    $systemArch = [System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine');
    $enclaveArch = '';
    $vcRedistUrl = '';

    if ($systemArch -eq 'AMD64')
    {
        $enclaveArch = 'X64';
        $vcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe';
    }
    elseif ($systemArch -eq 'ARM64')
    {
        $enclaveArch = 'Arm64';
        $vcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.arm64.exe';
    }
    elseif ($systemArch -eq 'X86')
    {
        $enclaveArch = 'X86';
        $vcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x86.exe';
    }

    if ($enclaveArch -eq '')
    {
        Write-Error "Unsupported architecture $systemArch";
        return 1;
    }

    # Now grab the latest installer.        
    $selectedPackage = $latestGaRelease.Packages | Where Architecture -EQ $enclaveArch;

    if (!$existingEnclaveVersion)
    {
        "Installing VC++ Redistributable";

        $vcRedistInstallPath = Join-Path $env:TEMP "enclave_vcredist.exe";
    
        # No existing version; install latest VC++ (will quickly complete if it already exists)
        Invoke-WebRequest -Uri $vcRedistUrl -UseBasicParsing -OutFile $vcRedistInstallPath;

        & $vcRedistInstallPath "/install" "/silent" "/norestart";
    }

    "Downloading latest enclave version $newEnclaveVersion from $($selectedPackage.Url)";

    $enclaveInstallerFile = Join-Path $env:TEMP "enclave-$newEnclaveVersion.msi";
    $enclaveInstallLogFile = Join-Path $env:TEMP "enclave-$newEnclaveVersion.install.log"

    Invoke-WebRequest $selectedPackage.Url -UseBasicParsing -OutFile $enclaveInstallerFile;

    if ($existingEnclaveVersion)
    {
        "Closing any open instances of the enclave tray"
        Get-Process "enclave-tray" -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
    }
    
    if ($existingEnclaveVersion -or !$EnrolmentKey)
    {
        # Don't need to re-enrol, we're already installed, or we don't have an enrolment key, so don't provide one to the installer.
        "Installing enclave; writing install log to $enclaveInstallLogFile"
        Start-Process msiexec "/i $enclaveInstallerFile /qn /l*v $enclaveInstallLogFile" -Wait
    }
    else 
    {
        # Not installed, provide the enrolment key.
        "Installing enclave and enrolling; writing install log to $enclaveInstallLogFile"
        Start-Process msiexec "/i $enclaveInstallerFile /qn /l*v $enclaveInstallLogFile ENROLMENT_KEY=$EnrolmentKey" -Wait

        # Make sure we purge the enrolment key from the log file.
        (Get-Content $enclaveInstallLogFile) -replace "$EnrolmentKey", '************' | Set-Content $enclaveInstallLogFile
    }

    # Give enclave 5s to get set up after the installer completes.
    Start-Sleep -Seconds 5

    if([Environment]::UserInteractive)
    {
        # Launch the tray.
        & $enclaveTrayPath --tray
    }
}
else 
{
    "Nothing to do; local installation is already at latest version $existingEnclaveVersion"
}

# Get installed enclave status.
$enclaveStatus = $(& $enclaveBinaryPath status --json) | ConvertFrom-Json

$subjectId = $enclaveStatus.Profile.Certificate.SubjectDistinguishedName;
$virtualIp = $enclaveStatus.Profile.VirtualAddress;
$installedVersion = $enclaveStatus.ProductVersion;

return @{
    SystemId = $subjectId;
    VirtualIp = $virtualIp;
    PreviousVersion = $existingEnclaveVersion
    NewVersion = $installedVersion
}