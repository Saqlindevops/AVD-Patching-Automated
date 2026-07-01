param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [string]$GoldenVmName,

    [Parameter(Mandatory)]
    [string]$ImageVersion
)

$ErrorActionPreference = "Stop"

Write-Host "Reading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId

# ------------------------------------------------------------
# Validate golden VM exists
# ------------------------------------------------------------
Write-Host "Checking golden VM: $GoldenVmName"

$sourceVm = Get-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName `
    -ErrorAction SilentlyContinue

if (-not $sourceVm) {
    throw "Golden VM $GoldenVmName not found in resource group $($config.BuildResourceGroup)."
}

Write-Host "Golden VM found."
Write-Host "Golden VM ID: $($sourceVm.Id)"

# ------------------------------------------------------------
# Collect VM dependency details for cleanup
# Must be collected before VM deletion
# ------------------------------------------------------------
Write-Host "Collecting VM dependency details for later cleanup..."

$nicIds = @()
if ($sourceVm.NetworkProfile.NetworkInterfaces) {
    $nicIds = $sourceVm.NetworkProfile.NetworkInterfaces.Id
}

$osDiskName = $sourceVm.StorageProfile.OsDisk.Name

$dataDiskNames = @()
if ($sourceVm.StorageProfile.DataDisks) {
    $dataDiskNames = $sourceVm.StorageProfile.DataDisks | ForEach-Object { $_.Name }
}

Write-Host "OS Disk: $osDiskName"

if ($nicIds.Count -gt 0) {
    Write-Host "NICs attached:"
    $nicIds | ForEach-Object { Write-Host $_ }
}
else {
    Write-Warning "No NICs found on VM."
}

if ($dataDiskNames.Count -gt 0) {
    Write-Host "Data disks attached:"
    $dataDiskNames | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host "No data disks attached."
}

# ------------------------------------------------------------
# Check whether image version already exists
# ------------------------------------------------------------
Write-Host "Checking if image version already exists: $ImageVersion"

$existingImageVersion = Get-AzGalleryImageVersion `
    -ResourceGroupName $config.ImageResourceGroup `
    -GalleryName $config.GalleryName `
    -GalleryImageDefinitionName $config.ImageDefinitionName `
    -Name $ImageVersion `
    -ErrorAction SilentlyContinue

if ($existingImageVersion) {
    throw "Image version $ImageVersion already exists. Delete it first or use a new version number."
}

# ------------------------------------------------------------
# Run Sysprep inside the golden VM
# ------------------------------------------------------------
Write-Host "Running Sysprep on VM: $GoldenVmName"

$sysprepScript = @'
$ErrorActionPreference = "Stop"

New-Item -Path "C:\AVDImageBuild" -ItemType Directory -Force | Out-Null
Start-Transcript -Path "C:\AVDImageBuild\sysprep.log" -Append

Write-Host "Starting Sysprep process..."

$sysprepPath = "C:\Windows\System32\Sysprep\Sysprep.exe"

if (-not (Test-Path $sysprepPath)) {
    throw "Sysprep.exe not found at $sysprepPath"
}

# FIX: do NOT -Wait here. /shutdown powers the VM off while Sysprep is still
# running. If this in-guest script blocks on -Wait, the VM goes down mid-wait
# and the Run Command extension can never report completion back to ARM -
# which is exactly what was making Invoke-AzVMRunCommand hang indefinitely on
# the orchestrator side (the pipeline appearing "stuck" with no further
# output). Launch Sysprep detached and let this script exit immediately; the
# orchestrator already polls VM power state afterward to detect shutdown.
Write-Host "Launching Sysprep (detached, not waiting on shutdown)..."

Start-Process `
    -FilePath $sysprepPath `
    -ArgumentList "/oobe /generalize /shutdown /quiet" `
    -PassThru | Out-Null

Write-Host "SYSPREP_LAUNCHED"

Stop-Transcript
'@

Invoke-AzVMRunCommand `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName `
    -CommandId 'RunPowerShellScript' `
    -ScriptString $sysprepScript

Write-Host "Sysprep command submitted."

# ------------------------------------------------------------
# Wait for VM to stop after Sysprep
# ------------------------------------------------------------
Write-Host "Waiting for VM to shut down after Sysprep..."

$maxWaitMinutes = 30
$waitedMinutes = 0
$vmStopped = $false

while ($waitedMinutes -lt $maxWaitMinutes) {

    $vmStatus = Get-AzVM `
        -ResourceGroupName $config.BuildResourceGroup `
        -Name $GoldenVmName `
        -Status

    $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus

    Write-Host "Current VM power state: $powerState"

    if ($powerState -eq "VM stopped" -or $powerState -eq "VM deallocated") {
        $vmStopped = $true
        break
    }

    Start-Sleep -Seconds 60
    $waitedMinutes++
}

if (-not $vmStopped) {
    throw "VM did not stop within $maxWaitMinutes minutes after Sysprep. Check C:\AVDImageBuild\sysprep.log."
}

# ------------------------------------------------------------
# Stop/deallocate VM
# ------------------------------------------------------------
Write-Host "Stopping and deallocating VM: $GoldenVmName"

Stop-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName `
    -Force

Write-Host "VM stopped and deallocated."

# ------------------------------------------------------------
# Tag VM before marking it generalized
# Important:
# Do not tag VM after Set-AzVM -Generalized.
# ------------------------------------------------------------
Write-Host "Tagging golden VM before generalization..."

$sourceVm = Get-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName

$tags = @{}

if ($sourceVm.Tags) {
    foreach ($key in $sourceVm.Tags.Keys) {
        $tags[$key] = $sourceVm.Tags[$key]
    }
}

$tags["ImageCaptureStarted"] = "true"
$tags["TargetImageVersion"] = $ImageVersion
$tags["DeleteCandidate"] = "true"
$tags["CaptureStartDate"] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Set-AzResource `
    -ResourceId $sourceVm.Id `
    -Tag $tags `
    -Force

Write-Host "Golden VM tagged before generalization."

# ------------------------------------------------------------
# Mark VM as generalized
# ------------------------------------------------------------
Write-Host "Marking VM as generalized..."

Set-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName `
    -Generalized

Write-Host "VM marked as generalized."

# Refresh source VM object after generalization
$sourceVm = Get-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName

Write-Host "Source VM ID for image capture:"
Write-Host $sourceVm.Id

# ------------------------------------------------------------
# Build target region list
# ------------------------------------------------------------
$targetRegions = @()

$targetRegions += @{
    name = $config.Location
    regionalReplicaCount = 1
    storageAccountType = "Standard_LRS"
}

if ($config.AdditionalTargetRegions) {
    foreach ($region in $config.AdditionalTargetRegions) {

        $replicaCount = 1
        if ($region.ReplicaCount) {
            $replicaCount = [int]$region.ReplicaCount
        }

        $storageAccountType = "Standard_LRS"
        if ($region.StorageAccountType) {
            $storageAccountType = $region.StorageAccountType
        }

        $targetRegions += @{
            name = $region.Name
            regionalReplicaCount = $replicaCount
            storageAccountType = $storageAccountType
        }
    }
}

Write-Host "Target regions:"
$targetRegions | ConvertTo-Json -Depth 10 | Write-Host

# ------------------------------------------------------------
# Create gallery image version using Azure REST API
# This avoids Az.Compute parameter compatibility issues.
# ------------------------------------------------------------
Write-Host "Creating image version using REST API: $ImageVersion"

$apiVersion = "2023-07-03"

$imageVersionUri = "/subscriptions/$($config.SubscriptionId)/resourceGroups/$($config.ImageResourceGroup)/providers/Microsoft.Compute/galleries/$($config.GalleryName)/images/$($config.ImageDefinitionName)/versions/$($ImageVersion)?api-version=$apiVersion"

$endOfLifeDate = (Get-Date).AddMonths(6).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$bodyObject = @{
    location = $config.Location
    properties = @{
        publishingProfile = @{
            targetRegions = $targetRegions
            endOfLifeDate = $endOfLifeDate
        }
        storageProfile = @{
            source = @{
                virtualMachineId = $sourceVm.Id
            }
        }
    }
}

$bodyJson = $bodyObject | ConvertTo-Json -Depth 20

Write-Host "Image version REST URI:"
Write-Host $imageVersionUri

Write-Host "Submitting image version creation request..."

$response = Invoke-AzRestMethod `
    -Method PUT `
    -Path $imageVersionUri `
    -Payload $bodyJson

Write-Host "Initial REST response status code: $($response.StatusCode)"

if ($response.StatusCode -notin 200, 201, 202) {
    Write-Host "REST response content:"
    Write-Host $response.Content
    throw "Failed to start image version creation."
}

# ------------------------------------------------------------
# Poll image version provisioning state
# ------------------------------------------------------------
Write-Host "Image creation started. Waiting for completion..."

$maxWaitMinutes = 120
$waitedMinutes = 0
$provisioningState = "Unknown"

while ($waitedMinutes -lt $maxWaitMinutes) {

    Start-Sleep -Seconds 60
    $waitedMinutes++

    $statusResponse = Invoke-AzRestMethod `
        -Method GET `
        -Path $imageVersionUri

    if ($statusResponse.StatusCode -notin 200, 201, 202) {
        Write-Host "Status response content:"
        Write-Host $statusResponse.Content
        throw "Failed to read image version status."
    }

    $statusObject = $statusResponse.Content | ConvertFrom-Json
    $provisioningState = $statusObject.properties.provisioningState

    Write-Host "Current image provisioning state: $provisioningState"

    if ($provisioningState -eq "Succeeded") {
        break
    }

    if ($provisioningState -eq "Failed") {
        Write-Host "Image version failed."
        Write-Host ($statusObject | ConvertTo-Json -Depth 20)
        throw "Image version creation failed."
    }
}

if ($provisioningState -ne "Succeeded") {
    throw "Image version creation did not complete within $maxWaitMinutes minutes. Last state: $provisioningState"
}

Write-Host "Image version created successfully: $ImageVersion"

# ------------------------------------------------------------
# Delete temporary golden VM, NIC, OS disk and data disks
# ------------------------------------------------------------
$deleteGoldenVmAfterCapture = $true

if ($null -ne $config.DeleteGoldenVmAfterCapture) {
    $deleteGoldenVmAfterCapture = [System.Convert]::ToBoolean($config.DeleteGoldenVmAfterCapture)
}

if ($deleteGoldenVmAfterCapture -eq $true) {

    Write-Host "DeleteGoldenVmAfterCapture is true."
    Write-Host "Starting cleanup of temporary golden VM resources..."

    # --------------------------------------------------------
    # Delete VM
    # --------------------------------------------------------
    $vmStillExists = Get-AzVM `
        -ResourceGroupName $config.BuildResourceGroup `
        -Name $GoldenVmName `
        -ErrorAction SilentlyContinue

    if ($vmStillExists) {
        Write-Host "Deleting golden VM: $GoldenVmName"

        Remove-AzVM `
            -ResourceGroupName $config.BuildResourceGroup `
            -Name $GoldenVmName `
            -Force

        Write-Host "Golden VM deleted: $GoldenVmName"
    }
    else {
        Write-Host "Golden VM already deleted or not found: $GoldenVmName"
    }

    # --------------------------------------------------------
    # Delete NICs
    # --------------------------------------------------------
    foreach ($nicId in $nicIds) {

        $nicName = ($nicId -split "/")[-1]

        Write-Host "Checking NIC: $nicName"

        $nic = Get-AzNetworkInterface `
            -ResourceGroupName $config.BuildResourceGroup `
            -Name $nicName `
            -ErrorAction SilentlyContinue

        if ($nic) {
            Write-Host "Deleting NIC: $nicName"

            Remove-AzNetworkInterface `
                -ResourceGroupName $config.BuildResourceGroup `
                -Name $nicName `
                -Force

            Write-Host "NIC deleted: $nicName"
        }
        else {
            Write-Host "NIC already deleted or not found: $nicName"
        }
    }

    # --------------------------------------------------------
    # Delete OS disk
    # --------------------------------------------------------
    if ($osDiskName) {
        Write-Host "Checking OS disk: $osDiskName"

        $osDisk = Get-AzDisk `
            -ResourceGroupName $config.BuildResourceGroup `
            -DiskName $osDiskName `
            -ErrorAction SilentlyContinue

        if ($osDisk) {
            Write-Host "Deleting OS disk: $osDiskName"

            Remove-AzDisk `
                -ResourceGroupName $config.BuildResourceGroup `
                -DiskName $osDiskName `
                -Force

            Write-Host "OS disk deleted: $osDiskName"
        }
        else {
            Write-Host "OS disk already deleted or not found: $osDiskName"
        }
    }
    else {
        Write-Warning "OS disk name was not captured. Skipping OS disk deletion."
    }

    # --------------------------------------------------------
    # Delete data disks if any
    # --------------------------------------------------------
    foreach ($dataDiskName in $dataDiskNames) {

        Write-Host "Checking data disk: $dataDiskName"

        $dataDisk = Get-AzDisk `
            -ResourceGroupName $config.BuildResourceGroup `
            -DiskName $dataDiskName `
            -ErrorAction SilentlyContinue

        if ($dataDisk) {
            Write-Host "Deleting data disk: $dataDiskName"

            Remove-AzDisk `
                -ResourceGroupName $config.BuildResourceGroup `
                -DiskName $dataDiskName `
                -Force

            Write-Host "Data disk deleted: $dataDiskName"
        }
        else {
            Write-Host "Data disk already deleted or not found: $dataDiskName"
        }
    }

    Write-Host "Golden VM cleanup completed successfully."
}
else {
    Write-Host "DeleteGoldenVmAfterCapture is false. Golden VM resources will be retained."
}

Write-Host "Phase 2 completed successfully."