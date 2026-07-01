param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

Write-Host "Reading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId

$now = Get-Date

Write-Host "Starting cleanup. Current time: $now"

# ------------------------------------------------------------
# Config flag: Entra ID device cleanup
# ------------------------------------------------------------
$cleanupEntraDevice = $false

if ($null -ne $config.CleanupEntraDevice) {
    $cleanupEntraDevice = [System.Convert]::ToBoolean($config.CleanupEntraDevice)
}

Write-Host "CleanupEntraDevice: $cleanupEntraDevice"

# ------------------------------------------------------------
# Helper: Remove Entra ID device object
# ------------------------------------------------------------
function Remove-EntraDeviceObject {
    param(
        [Parameter(Mandatory)]
        [string]$DeviceName
    )

    Write-Host "Starting Entra ID device cleanup for: $DeviceName"

    try {
        $devices = @(Get-AzADDevice `
            -DisplayName $DeviceName `
            -ErrorAction SilentlyContinue)

        if (-not $devices -or $devices.Count -eq 0) {
            Write-Warning "No Entra ID device found with display name: $DeviceName"
            return
        }

        foreach ($device in $devices) {

            Write-Host "Found Entra ID device:"
            Write-Host "DisplayName: $($device.DisplayName)"
            Write-Host "ObjectId: $($device.Id)"
            Write-Host "DeviceId: $($device.DeviceId)"

            if ($device.DisplayName -ne $DeviceName) {
                Write-Warning "Skipping device because display name is not an exact match: $($device.DisplayName)"
                continue
            }

            Write-Host "Removing Entra ID device object: $($device.DisplayName)"

            Remove-AzADDevice `
                -ObjectId $device.Id `
                -ErrorAction Stop

            Write-Host "Entra ID device removed successfully: $($device.DisplayName)"
        }
    }
    catch {
        Write-Warning "Failed to remove Entra ID device object for $DeviceName. Error: $($_.Exception.Message)"
        Write-Warning "Check whether the service connection has permission to delete devices in Entra ID."
    }
}

# ------------------------------------------------------------
# Get AVD session hosts
# ------------------------------------------------------------
$sessionHosts = Get-AzWvdSessionHost `
    -ResourceGroupName $config.AvdResourceGroup `
    -HostPoolName $config.HostPoolName `
    -ErrorAction Stop

if (-not $sessionHosts) {
    Write-Host "No session hosts found in host pool: $($config.HostPoolName)"
    return
}

foreach ($sessionHost in $sessionHosts) {

    $sessionHostName = ($sessionHost.Name -split "/")[-1]
    $vmName = ($sessionHostName -split "\.")[0]

    Write-Host "------------------------------------------------------------"
    Write-Host "Checking session host: $sessionHostName"
    Write-Host "Resolved VM name: $vmName"
    Write-Host "------------------------------------------------------------"

    $vm = Get-AzVM `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Name $vmName `
        -ErrorAction SilentlyContinue

    if (-not $vm) {
        Write-Warning "VM not found for session host: $sessionHostName"
        continue
    }

    if (-not $vm.Tags) {
        Write-Host "Skipping $vmName. No tags found."
        continue
    }

    if (-not $vm.Tags.ContainsKey("PendingDelete")) {
        Write-Host "Skipping $vmName. PendingDelete tag not found."
        continue
    }

    if ($vm.Tags["PendingDelete"] -ne "true") {
        Write-Host "Skipping $vmName. PendingDelete is not true."
        continue
    }

    if (-not $vm.Tags.ContainsKey("RetireAfter")) {
        Write-Warning "VM $vmName has PendingDelete=true but no RetireAfter tag."
        continue
    }

    $retireAfterRaw = $vm.Tags["RetireAfter"]

    if ([string]::IsNullOrWhiteSpace($retireAfterRaw)) {
        Write-Warning "VM $vmName has PendingDelete=true but RetireAfter tag is empty."
        continue
    }

    try {
        $retireAfter = [datetime]$retireAfterRaw
    }
    catch {
        Write-Warning "VM $vmName has invalid RetireAfter value: $retireAfterRaw"
        continue
    }

    if ($retireAfter -gt $now) {
        Write-Host "Skipping $vmName. RetireAfter not reached yet: $retireAfter"
        continue
    }

    Write-Host "RetireAfter reached for $vmName. Checking user sessions for host: $sessionHostName"

    $userSessions = @(Get-AzWvdUserSession `
        -ResourceGroupName $config.AvdResourceGroup `
        -HostPoolName $config.HostPoolName `
        -SessionHostName $sessionHostName `
        -ErrorAction SilentlyContinue)

    if ($userSessions.Count -gt 0) {
        Write-Warning "Skipping $vmName. Active/disconnected sessions still exist: $($userSessions.Count)"
        continue
    }

    Write-Host "No user sessions found. Proceeding with cleanup for VM: $vmName"

    $vmObject = Get-AzVM `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Name $vmName `
        -ErrorAction Stop

    $nicIds = @($vmObject.NetworkProfile.NetworkInterfaces.Id)
    $osDiskName = $vmObject.StorageProfile.OsDisk.Name

    $dataDiskNames = @()
    if ($vmObject.StorageProfile.DataDisks) {
        $dataDiskNames = @($vmObject.StorageProfile.DataDisks.Name)
    }

    # --------------------------------------------------------
    # Remove AVD session host object
    # --------------------------------------------------------
    Write-Host "Removing AVD session host object first: $sessionHostName"

    Remove-AzWvdSessionHost `
        -ResourceGroupName $config.AvdResourceGroup `
        -HostPoolName $config.HostPoolName `
        -Name $sessionHostName `
        -Force `
        -ErrorAction SilentlyContinue

    # --------------------------------------------------------
    # Remove Azure VM
    # --------------------------------------------------------
    Write-Host "Removing VM: $vmName"

    Remove-AzVM `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Name $vmName `
        -Force `
        -ErrorAction Stop

    # --------------------------------------------------------
    # Remove NICs
    # --------------------------------------------------------
    foreach ($nicId in $nicIds) {
        if ([string]::IsNullOrWhiteSpace($nicId)) {
            continue
        }

        $nicName = ($nicId -split "/")[-1]

        Write-Host "Removing NIC: $nicName"

        Remove-AzNetworkInterface `
            -ResourceGroupName $config.SessionHostResourceGroup `
            -Name $nicName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------
    # Remove OS disk
    # --------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($osDiskName)) {
        Write-Host "Removing OS disk: $osDiskName"

        Remove-AzDisk `
            -ResourceGroupName $config.SessionHostResourceGroup `
            -DiskName $osDiskName `
            -Force `
            -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "OS disk name not found for VM: $vmName"
    }

    # --------------------------------------------------------
    # Remove data disks
    # --------------------------------------------------------
    foreach ($dataDiskName in $dataDiskNames) {
        if ([string]::IsNullOrWhiteSpace($dataDiskName)) {
            continue
        }

        Write-Host "Removing data disk: $dataDiskName"

        Remove-AzDisk `
            -ResourceGroupName $config.SessionHostResourceGroup `
            -DiskName $dataDiskName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------
    # Remove Entra ID device object
    # --------------------------------------------------------
    if ($cleanupEntraDevice) {
        Remove-EntraDeviceObject `
            -DeviceName $vmName
    }
    else {
        Write-Host "Skipping Entra ID device cleanup because CleanupEntraDevice is false."
    }

    Write-Host "Cleanup completed for: $vmName"
}

Write-Host "------------------------------------------------------------"
Write-Host "Cleanup job completed."
Write-Host "------------------------------------------------------------"