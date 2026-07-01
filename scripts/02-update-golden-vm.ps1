param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [string]$GoldenVmName
)

$ErrorActionPreference = "Stop"

Write-Host "Reading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId

# ------------------------------------------------------------
# Config defaults
# ------------------------------------------------------------
$maxUpdateRounds = 2
if ($null -ne $config.WindowsUpdateMaxRounds) {
    $maxUpdateRounds = [int]$config.WindowsUpdateMaxRounds
}

$waitMinutesAfterReboot = 30
if ($null -ne $config.WindowsUpdateWaitMinutesAfterReboot) {
    $waitMinutesAfterReboot = [int]$config.WindowsUpdateWaitMinutesAfterReboot
}

$windowsUpdateLimit = 25
if ($null -ne $config.WindowsUpdateLimit) {
    $windowsUpdateLimit = [int]$config.WindowsUpdateLimit
}

$servicingWaitMinutes = 60
if ($null -ne $config.WindowsServicingWaitMinutes) {
    $servicingWaitMinutes = [int]$config.WindowsServicingWaitMinutes
}

$fslogixPackageUrl = "https://aka.ms/fslogix_download"
if ($config.FslogixPackageUrl -and $config.FslogixPackageUrl.Trim() -ne "") {
    $fslogixPackageUrl = $config.FslogixPackageUrl
}

$fslogixInstallerName = "FSLogixAppsSetup.exe"
if ($config.FslogixInstallerName -and $config.FslogixInstallerName.Trim() -ne "") {
    $fslogixInstallerName = $config.FslogixInstallerName
}

Write-Host "WindowsUpdateMaxRounds: $maxUpdateRounds"
Write-Host "WindowsUpdateWaitMinutesAfterReboot: $waitMinutesAfterReboot"
Write-Host "WindowsUpdateLimit: $windowsUpdateLimit"
Write-Host "WindowsServicingWaitMinutes: $servicingWaitMinutes"
Write-Host "FslogixPackageUrl: $fslogixPackageUrl"
Write-Host "FslogixInstallerName: $fslogixInstallerName"

# ------------------------------------------------------------
# Validate golden VM exists
# ------------------------------------------------------------
Write-Host "Checking golden VM: $GoldenVmName"

$vm = Get-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName `
    -ErrorAction SilentlyContinue

if (-not $vm) {
    throw "Golden VM $GoldenVmName not found in resource group $($config.BuildResourceGroup)."
}

Write-Host "Golden VM found."

# ------------------------------------------------------------
# Helper: Wait for VM Agent
# ------------------------------------------------------------
function Wait-GoldenVmReady {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [int]$TimeoutMinutes = 30
    )

    Write-Host "Waiting for VM to become ready: $VmName"

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {

        $status = Get-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Name $VmName `
            -Status

        $powerState = ($status.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus

        $agentStatus = $null
        if ($status.VMAgent -and $status.VMAgent.Statuses) {
            $agentStatus = ($status.VMAgent.Statuses | Select-Object -First 1).DisplayStatus
        }

        Write-Host "VM power state: $powerState | VM Agent: $agentStatus"

        if ($powerState -eq "VM running" -and $agentStatus -eq "Ready") {
            Write-Host "VM is running and VM Agent is ready."
            return
        }

        Start-Sleep -Seconds 30
    }

    throw "VM $VmName did not become ready within $TimeoutMinutes minutes."
}

# ------------------------------------------------------------
# Helper: Restart VM from Azure
# ------------------------------------------------------------
function Restart-GoldenVmFromAzure {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [int]$TimeoutMinutes = 30
    )

    Write-Host "Restarting VM from Azure side: $VmName"

    Restart-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VmName

    Write-Host "Restart command completed. Waiting for VM Agent readiness..."

    Wait-GoldenVmReady `
        -ResourceGroupName $ResourceGroupName `
        -VmName $VmName `
        -TimeoutMinutes $TimeoutMinutes
}

# ------------------------------------------------------------
# Helper: Invoke PowerShell inside VM
# ------------------------------------------------------------
function Invoke-GoldenVmScript {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$Script
    )

    Write-Host "Running script inside VM: $VmName"

    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -Name $VmName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $Script

    $message = ""

    if ($result.Value) {
        $message = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
    }

    if ($message) {
        Write-Host "Run Command output:"
        Write-Host $message
    }

    # Surface a clear failure if the Run Command extension itself reported an error
    # status, since Invoke-AzVMRunCommand does not throw on a failed in-guest script
    # by default - it just returns the error text inside $result.Value.
    if ($message -match "(?im)^\s*ERROR_IN_SCRIPT:") {
        throw "In-guest script reported an error. See output above / C:\AVDImageBuild\patching.log on $VmName."
    }

    return $message
}

# ------------------------------------------------------------
# Helper: Check pending reboot inside VM
# ------------------------------------------------------------
function Test-GoldenVmPendingReboot {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName
    )

    $pendingRebootScript = @'
$ErrorActionPreference = "Stop"

New-Item -Path "C:\AVDImageBuild" -ItemType Directory -Force | Out-Null
Start-Transcript -Path "C:\AVDImageBuild\patching.log" -Append

Write-Host "Checking pending reboot state..."

$pendingReboot = $false

$pendingRebootKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile"
)

foreach ($key in $pendingRebootKeys) {
    if (Test-Path $key) {
        Write-Host "Pending reboot marker found: $key"
        $pendingReboot = $true
    }
}

try {
    $sessionManager = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction SilentlyContinue

    if ($sessionManager.PendingFileRenameOperations) {
        Write-Host "PendingFileRenameOperations found."
        $pendingReboot = $true
    }
}
catch {
    Write-Host "Could not check PendingFileRenameOperations."
}

if ($pendingReboot) {
    Write-Host "PENDING_REBOOT_TRUE"
}
else {
    Write-Host "PENDING_REBOOT_FALSE"
}

Stop-Transcript
'@

    $output = Invoke-GoldenVmScript `
        -ResourceGroupName $ResourceGroupName `
        -VmName $VmName `
        -Script $pendingRebootScript

    return ($output -match "PENDING_REBOOT_TRUE")
}

# ------------------------------------------------------------
# Helper: Wait for Windows servicing to clear
# ------------------------------------------------------------
function Wait-GoldenVmWindowsServicingClear {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [int]$TimeoutMinutes = 60
    )

    $servicingScript = @"
`$ErrorActionPreference = "Stop"

New-Item -Path "C:\AVDImageBuild" -ItemType Directory -Force | Out-Null
Start-Transcript -Path "C:\AVDImageBuild\patching.log" -Append

Write-Host "Checking Windows servicing processes..."

`$maxWaitMinutes = $TimeoutMinutes
`$waitedMinutes = 0

while (`$waitedMinutes -lt `$maxWaitMinutes) {

    `$trustedInstaller = Get-Process TrustedInstaller -ErrorAction SilentlyContinue
    `$tiWorker = Get-Process TiWorker -ErrorAction SilentlyContinue
    `$moUso = Get-Process MoUsoCoreWorker -ErrorAction SilentlyContinue

    if (-not `$trustedInstaller -and -not `$tiWorker -and -not `$moUso) {
        Write-Host "WINDOWS_SERVICING_CLEAR"
        Write-Host "No active Windows servicing process detected."
        Stop-Transcript
        exit 0
    }

    if (`$trustedInstaller) {
        Write-Host "TrustedInstaller is running."
    }

    if (`$tiWorker) {
        Write-Host "TiWorker is running."
    }

    if (`$moUso) {
        Write-Host "MoUsoCoreWorker is running."
    }

    Start-Sleep -Seconds 60
    `$waitedMinutes++
}

Write-Host "ERROR_IN_SCRIPT: Windows servicing did not clear within `$maxWaitMinutes minutes."
Stop-Transcript
exit 1
"@

    $output = Invoke-GoldenVmScript `
        -ResourceGroupName $ResourceGroupName `
        -VmName $VmName `
        -Script $servicingScript

    if ($output -notmatch "WINDOWS_SERVICING_CLEAR") {
        throw "Windows servicing did not clear. Do not continue."
    }
}

# ------------------------------------------------------------
# Ensure VM is ready
# ------------------------------------------------------------
Wait-GoldenVmReady `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -TimeoutMinutes 30

# ------------------------------------------------------------
# Preparation inside VM
# ------------------------------------------------------------
$prepScript = @'
$ErrorActionPreference = "Stop"

New-Item -Path "C:\AVDImageBuild" -ItemType Directory -Force | Out-Null
Start-Transcript -Path "C:\AVDImageBuild\patching.log" -Append

Write-Host "Preparing golden VM for patching..."

Write-Host "Setting TLS 1.2..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    Write-Host "Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -Confirm:$false | Out-Null

    Write-Host "Trusting PowerShell Gallery..."
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Write-Host "Installing PSWindowsUpdate module..."
    Install-Module PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -Confirm:$false

    Write-Host "Importing PSWindowsUpdate module..."
    Import-Module PSWindowsUpdate -Force

    # FIX: Get-WindowsUpdate/Install-WindowsUpdate with -MicrosoftUpdate require the
    # Microsoft Update service catalog to be registered. On a freshly built golden
    # image this is frequently NOT registered yet, which causes the scan to silently
    # return nothing or throw. Register it explicitly and idempotently here.
    Write-Host "Registering Microsoft Update service (if not already registered)..."
    $msUpdateServiceId = "7971f918-a847-4430-9279-4a52d1efe18d"
    $existingService = Get-WUServiceManager -ErrorAction SilentlyContinue | Where-Object { $_.ServiceID -eq $msUpdateServiceId }

    if (-not $existingService) {
        Add-WUServiceManager -ServiceID $msUpdateServiceId -Confirm:$false | Out-Null
        Write-Host "Microsoft Update service registered."
    }
    else {
        Write-Host "Microsoft Update service already registered."
    }

    # FIX: verify registration actually took effect before moving on. If this
    # silently fails (blocked by GPO/proxy/etc.), every later call using
    # -MicrosoftUpdate will fail with a confusing "term not recognized as a
    # cmdlet" error instead of a clear root cause. Fail fast here instead.
    $verifyService = Get-WUServiceManager -ErrorAction SilentlyContinue | Where-Object { $_.ServiceID -eq $msUpdateServiceId }

    if (-not $verifyService) {
        throw "Microsoft Update service registration did not take effect. Check Group Policy / WSUS settings on $env:COMPUTERNAME that may be blocking it."
    }

    Write-Host "Preparation completed."
    Write-Host "PREP_SUCCESS"
}
catch {
    Write-Host "ERROR_IN_SCRIPT: $($_.Exception.Message)"
}

Stop-Transcript
'@

Invoke-GoldenVmScript `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -Script $prepScript

# ------------------------------------------------------------
# Reboot first if VM is already pending reboot
# ------------------------------------------------------------
Write-Host "Checking for pending reboot before Windows Update starts..."

$pendingBeforeUpdate = Test-GoldenVmPendingReboot `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName

if ($pendingBeforeUpdate) {
    Write-Host "Pending reboot found before update scan. Restarting VM first."

    Restart-GoldenVmFromAzure `
        -ResourceGroupName $config.BuildResourceGroup `
        -VmName $GoldenVmName `
        -TimeoutMinutes $waitMinutesAfterReboot

    Write-Host "Waiting extra 5 minutes after pre-update reboot."
    Start-Sleep -Seconds 300
}
else {
    Write-Host "No pending reboot before Windows Update."
}

# ------------------------------------------------------------
# Wait for Windows servicing to clear
# ------------------------------------------------------------
Wait-GoldenVmWindowsServicingClear `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -TimeoutMinutes $servicingWaitMinutes

# ------------------------------------------------------------
# Windows Update rounds
# ------------------------------------------------------------
for ($round = 1; $round -le $maxUpdateRounds; $round++) {

    Write-Host "------------------------------------------------------------"
    Write-Host "Starting Windows Update round $round of $maxUpdateRounds"
    Write-Host "------------------------------------------------------------"

    $windowsUpdateScript = @"
`$ErrorActionPreference = "Stop"

Start-Transcript -Path "C:\AVDImageBuild\patching.log" -Append

Write-Host "Starting Windows Update round ${round}."

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Import-Module PSWindowsUpdate -Force

try {

    Write-Host "Searching for applicable updates..."
    Write-Host "Criteria: IsInstalled=0"
    Write-Host "Excluding Preview updates and Drivers."
    Write-Host "Update limit: $windowsUpdateLimit"

    `$scanParams = @{
        MicrosoftUpdate = `$true
        Criteria        = "IsInstalled=0"
        NotTitle        = "Preview"
        NotCategory     = "Drivers"
        IgnoreReboot    = `$true
        ErrorAction     = "Stop"
    }

    `$updates = Get-WindowsUpdate @scanParams

    if (-not `$updates -or `$updates.Count -eq 0) {
        Write-Host "NO_UPDATES_FOUND"
        Write-Host "No applicable updates found in round ${round}."
        Stop-Transcript
        exit 0
    }

    `$updatesToInstall = `$updates | Select-Object -First $windowsUpdateLimit

    Write-Host "Found `$(`$updatesToInstall.Count) update(s) in round ${round}."

    # NOTE: the detailed update table is written to the log file only (not
    # Write-Host), because Invoke-AzVMRunCommand truncates captured stdout to
    # ~4096 characters. A large table here can push the UPDATES_INSTALLED /
    # NO_UPDATES_FOUND marker out of the captured output, which then makes
    # the orchestrator throw a false "unexpected status" error.
    `$updatesToInstall | Select-Object KB, Title, Size | Format-Table -AutoSize | Out-String | Out-File -FilePath "C:\AVDImageBuild\update-details.log" -Append

    `$kbList = @()

    foreach (`$update in `$updatesToInstall) {
        if (`$update.KB) {
            foreach (`$kb in `$update.KB) {
                if (`$kb -and `$kb.ToString().Trim() -ne "") {
                    `$kbList += `$kb.ToString().Trim()
                }
            }
        }
    }

    `$kbList = `$kbList | Sort-Object -Unique

    if (`$kbList.Count -gt 0) {

        Write-Host "Installing `$(`$kbList.Count) update(s) by KB list."

        `$installParams = @{
            MicrosoftUpdate = `$true
            KBArticleID     = `$kbList
            AcceptAll       = `$true
            IgnoreReboot    = `$true
            Confirm         = `$false
            ErrorAction     = "Stop"
        }

        `$installResult = Install-WindowsUpdate @installParams
        `$installResult | Select-Object KB, Result | Format-Table -AutoSize | Out-String | Out-File -FilePath "C:\AVDImageBuild\update-details.log" -Append
    }
    else {

        Write-Host "No KB list detected. Installing filtered updates using criteria."

        `$installFallbackParams = @{
            MicrosoftUpdate = `$true
            Criteria        = "IsInstalled=0"
            NotTitle        = "Preview"
            NotCategory     = "Drivers"
            AcceptAll       = `$true
            IgnoreReboot    = `$true
            Confirm         = `$false
            ErrorAction     = "Stop"
        }

        `$installResult = Install-WindowsUpdate @installFallbackParams
        `$installResult | Select-Object KB, Result | Format-Table -AutoSize | Out-String | Out-File -FilePath "C:\AVDImageBuild\update-details.log" -Append
    }

    Write-Host "UPDATES_INSTALLED"
    Write-Host "Windows Update round ${round} completed."
}
catch {
    Write-Host "ERROR_IN_SCRIPT: Windows Update round ${round} failed: `$(`$_.Exception.Message)"
}

Stop-Transcript
"@

    $updateOutput = Invoke-GoldenVmScript `
        -ResourceGroupName $config.BuildResourceGroup `
        -VmName $GoldenVmName `
        -Script $windowsUpdateScript

    if ($updateOutput -match "NO_UPDATES_FOUND") {
        Write-Host "No more updates found. Windows Update rounds completed."
        break
    }

    if ($updateOutput -match "UPDATES_INSTALLED") {
        Write-Host "Updates were installed in round $round. Restarting VM."

        Restart-GoldenVmFromAzure `
            -ResourceGroupName $config.BuildResourceGroup `
            -VmName $GoldenVmName `
            -TimeoutMinutes $waitMinutesAfterReboot

        Write-Host "Waiting extra 5 minutes after update reboot."
        Start-Sleep -Seconds 300

        Wait-GoldenVmWindowsServicingClear `
            -ResourceGroupName $config.BuildResourceGroup `
            -VmName $GoldenVmName `
            -TimeoutMinutes $servicingWaitMinutes

        $pendingAfterRound = Test-GoldenVmPendingReboot `
            -ResourceGroupName $config.BuildResourceGroup `
            -VmName $GoldenVmName

        if ($pendingAfterRound) {
            Write-Host "Pending reboot still found after round $round reboot. Restarting VM again."

            Restart-GoldenVmFromAzure `
                -ResourceGroupName $config.BuildResourceGroup `
                -VmName $GoldenVmName `
                -TimeoutMinutes $waitMinutesAfterReboot

            Write-Host "Waiting extra 5 minutes after additional reboot."
            Start-Sleep -Seconds 300
        }
    }
    else {
        throw "Windows Update round $round did not return expected status. Check C:\AVDImageBuild\patching.log."
    }
}

# ------------------------------------------------------------
# Final post-update check
# ------------------------------------------------------------
Write-Host "Performing final Windows Update pending reboot check."

$pendingAfterUpdates = Test-GoldenVmPendingReboot `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName

if ($pendingAfterUpdates) {
    Write-Host "Pending reboot found after update rounds. Restarting VM."

    Restart-GoldenVmFromAzure `
        -ResourceGroupName $config.BuildResourceGroup `
        -VmName $GoldenVmName `
        -TimeoutMinutes $waitMinutesAfterReboot

    Write-Host "Waiting extra 5 minutes after post-update reboot."
    Start-Sleep -Seconds 300
}

Wait-GoldenVmWindowsServicingClear `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -TimeoutMinutes $servicingWaitMinutes

# ------------------------------------------------------------
# FSLogix update
# ------------------------------------------------------------
Write-Host "------------------------------------------------------------"
Write-Host "Starting FSLogix installation/update"
Write-Host "------------------------------------------------------------"

$fslogixScript = @"
`$ErrorActionPreference = "Stop"

Start-Transcript -Path "C:\AVDImageBuild\patching.log" -Append

Write-Host "Starting FSLogix update."

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {

    `$fslogixUrl = "$fslogixPackageUrl"
    `$installerName = "$fslogixInstallerName"

    `$downloadFolder = "C:\AVDImageBuild\FSLogixDownload"
    `$extractFolder = "C:\AVDImageBuild\FSLogixExtract"
    `$zipPath = Join-Path `$downloadFolder "FSLogix.zip"

    Remove-Item -Path `$downloadFolder -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path `$extractFolder -Recurse -Force -ErrorAction SilentlyContinue

    New-Item -Path `$downloadFolder -ItemType Directory -Force | Out-Null
    New-Item -Path `$extractFolder -ItemType Directory -Force | Out-Null

    Write-Host "FSLogix package URL: `$fslogixUrl"
    Write-Host "Downloading FSLogix package..."

    `$downloadParams = @{
        Uri             = `$fslogixUrl
        OutFile         = `$zipPath
        UseBasicParsing = `$true
    }

    Invoke-WebRequest @downloadParams

    if (-not (Test-Path `$zipPath)) {
        throw "FSLogix ZIP download failed. File not found: `$zipPath"
    }

    Write-Host "Extracting FSLogix package..."

    `$expandParams = @{
        Path            = `$zipPath
        DestinationPath = `$extractFolder
        Force           = `$true
    }

    Expand-Archive @expandParams

    Write-Host "Searching for FSLogix installer: `$installerName"

    `$installer = Get-ChildItem -Path `$extractFolder -Recurse -Filter `$installerName | Select-Object -First 1

    if (-not `$installer) {
        throw "FSLogix installer `$installerName not found after extraction."
    }

    Write-Host "FSLogix installer found: `$(`$installer.FullName)"

    `$existingVersion = `$null

    try {
        `$existingApps = Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Apps" -ErrorAction SilentlyContinue

        if (`$existingApps) {
            `$existingVersion = `$existingApps.InstallVersion
        }
    }
    catch {
        Write-Warning "Could not read existing FSLogix version."
    }

    if (`$existingVersion) {
        Write-Host "Existing FSLogix version: `$existingVersion"
    }
    else {
        Write-Host "Existing FSLogix version not found or FSLogix not installed."
    }

    Write-Host "Installing/upgrading FSLogix silently..."

    `$process = Start-Process -FilePath `$installer.FullName -ArgumentList "/install /quiet /norestart" -Wait -PassThru

    Write-Host "FSLogix installer exit code: `$(`$process.ExitCode)"

    if (`$process.ExitCode -ne 0 -and `$process.ExitCode -ne 3010) {
        throw "FSLogix installation failed with exit code `$(`$process.ExitCode)."
    }

    `$fslogixApps = Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Apps" -ErrorAction SilentlyContinue

    if (-not `$fslogixApps) {
        throw "FSLogix registry key not found after installation."
    }

    if (`$fslogixApps.InstallVersion) {
        Write-Host "FSLogix installed version: `$(`$fslogixApps.InstallVersion)"
    }
    else {
        Write-Host "FSLogix installed but InstallVersion value was not found."
    }

    Write-Host "FSLOGIX_INSTALL_SUCCESS"
}
catch {
    Write-Host "ERROR_IN_SCRIPT: `$(`$_.Exception.Message)"
}

Stop-Transcript
"@

$fslogixOutput = Invoke-GoldenVmScript `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -Script $fslogixScript

if ($fslogixOutput -notmatch "FSLOGIX_INSTALL_SUCCESS") {
    throw "FSLogix installation did not complete successfully. Check C:\AVDImageBuild\patching.log on the golden VM."
}

Write-Host "FSLogix update completed. Restarting VM."

Restart-GoldenVmFromAzure `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -TimeoutMinutes $waitMinutesAfterReboot

Write-Host "Waiting extra 5 minutes after FSLogix reboot."
Start-Sleep -Seconds 300

# ------------------------------------------------------------
# Final validation before Sysprep
# ------------------------------------------------------------
Write-Host "------------------------------------------------------------"
Write-Host "Starting final validation before Sysprep"
Write-Host "------------------------------------------------------------"

Wait-GoldenVmWindowsServicingClear `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -TimeoutMinutes $servicingWaitMinutes

$finalPendingReboot = Test-GoldenVmPendingReboot `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName

if ($finalPendingReboot) {
    throw "Pending reboot still exists after FSLogix update. Do not proceed to Sysprep."
}

$finalValidationScript = @'
$ErrorActionPreference = "Stop"

Start-Transcript -Path "C:\AVDImageBuild\patching.log" -Append

try {

    Write-Host "Validating FSLogix registry..."

    $fslogixApps = Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Apps" -ErrorAction SilentlyContinue

    if (-not $fslogixApps) {
        throw "FSLogix registry key not found."
    }

    if ($fslogixApps.InstallVersion) {
        Write-Host "FSLogix version: $($fslogixApps.InstallVersion)"
    }
    else {
        Write-Host "FSLogix installed, but InstallVersion value was not found."
    }

    Write-Host "Cleaning temporary files..."

    Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "FINAL_VALIDATION_SUCCESS"
}
catch {
    Write-Host "ERROR_IN_SCRIPT: $($_.Exception.Message)"
}

Stop-Transcript
'@

$finalValidationOutput = Invoke-GoldenVmScript `
    -ResourceGroupName $config.BuildResourceGroup `
    -VmName $GoldenVmName `
    -Script $finalValidationScript

if ($finalValidationOutput -notmatch "FINAL_VALIDATION_SUCCESS") {
    throw "Final validation failed. Do not proceed to Sysprep."
}

Write-Host "------------------------------------------------------------"
Write-Host "Golden VM patching completed successfully."
Write-Host "The VM is ready for Sysprep and image capture."
Write-Host "------------------------------------------------------------"