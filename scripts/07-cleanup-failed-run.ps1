param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    # The golden VM name from Stage 2. May be empty if the run failed before
    # the golden VM was created - in that case there is nothing to clean up.
    [Parameter(Mandatory = $false)]
    [string]$GoldenVmName
)

# ============================================================================
#  Runs only when the automated patch run FAILED.
#  If a golden VM was created but the run failed before it was captured and
#  deleted, that temporary VM (plus its NIC and OS disk) would be left behind
#  running and costing money. This removes it, best-effort.
# ============================================================================

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($GoldenVmName)) {
    Write-Host "No golden VM name was provided. The run likely failed before the golden VM was created. Nothing to clean up."
    return
}

Write-Host "Reading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId | Out-Null

Write-Host "Looking for orphaned golden VM: $GoldenVmName"

$vm = Get-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName `
    -ErrorAction SilentlyContinue

if (-not $vm) {
    Write-Host "Golden VM '$GoldenVmName' not found (already cleaned up or never created). Nothing to do."
    return
}

# Collect dependent resource names BEFORE deleting the VM.
$nicIds = @()
if ($vm.NetworkProfile.NetworkInterfaces) {
    $nicIds = $vm.NetworkProfile.NetworkInterfaces.Id
}

$osDiskName = $vm.StorageProfile.OsDisk.Name

$dataDiskNames = @()
if ($vm.StorageProfile.DataDisks) {
    $dataDiskNames = $vm.StorageProfile.DataDisks | ForEach-Object { $_.Name }
}

# ------------------------------------------------------------
# Delete VM
# ------------------------------------------------------------
Write-Host "Deleting orphaned golden VM: $GoldenVmName"
Remove-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $GoldenVmName `
    -Force `
    -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# Delete NICs
# ------------------------------------------------------------
foreach ($nicId in $nicIds) {
    if ([string]::IsNullOrWhiteSpace($nicId)) { continue }
    $nicName = ($nicId -split "/")[-1]
    Write-Host "Deleting NIC: $nicName"
    Remove-AzNetworkInterface `
        -ResourceGroupName $config.BuildResourceGroup `
        -Name $nicName `
        -Force `
        -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# Delete OS disk
# ------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($osDiskName)) {
    Write-Host "Deleting OS disk: $osDiskName"
    Remove-AzDisk `
        -ResourceGroupName $config.BuildResourceGroup `
        -DiskName $osDiskName `
        -Force `
        -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# Delete data disks (if any)
# ------------------------------------------------------------
foreach ($dataDiskName in $dataDiskNames) {
    if ([string]::IsNullOrWhiteSpace($dataDiskName)) { continue }
    Write-Host "Deleting data disk: $dataDiskName"
    Remove-AzDisk `
        -ResourceGroupName $config.BuildResourceGroup `
        -DiskName $dataDiskName `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Host "Orphaned golden VM cleanup completed for: $GoldenVmName"
