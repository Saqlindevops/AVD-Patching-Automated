param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [string]$NewImageVersion
)

$ErrorActionPreference = "Stop"

Write-Host "Reading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId

Write-Host "Finding current AVD session hosts..."

$sessionHosts = Get-AzWvdSessionHost `
    -ResourceGroupName $config.AvdResourceGroup `
    -HostPoolName $config.HostPoolName

if (-not $sessionHosts) {
    throw "No session hosts found in host pool $($config.HostPoolName)."
}

$oldHosts = @()

foreach ($sessionHost in $sessionHosts) {

    $hostName = ($sessionHost.Name -split "/")[-1]
    $vmName = ($hostName -split "\.")[0]

    Write-Host "Checking session host: $hostName | VM: $vmName"

    $vm = Get-AzVM `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Name $vmName `
        -ErrorAction SilentlyContinue

    if (-not $vm) {
        Write-Warning "VM not found for session host: $hostName"
        continue
    }

    $vmImageVersion = $null

    if ($vm.Tags -and $vm.Tags.ContainsKey("ImageVersion")) {
        $vmImageVersion = $vm.Tags["ImageVersion"]
    }

    if ([string]::IsNullOrWhiteSpace($vmImageVersion)) {
        Write-Warning "VM $vmName does not have ImageVersion tag. Treating it as old."
    }

    if ($vmImageVersion -ne $NewImageVersion) {

        Write-Host "Old host detected: $hostName | VM: $vmName | ImageVersion: $vmImageVersion"

        $oldHosts += [PSCustomObject]@{
            SessionHostName = $hostName
            VmName          = $vmName
            ResourceId      = $vm.Id
            ImageVersion    = $vmImageVersion
        }
    }
    else {
        Write-Host "Host is on new image version. Keeping host: $hostName"
    }
}

if ($oldHosts.Count -eq 0) {
    Write-Host "No old hosts found."
    return
}

$deleteOldHostsAfterHours = 24

if ($null -ne $config.DeleteOldHostsAfterHours) {
    $deleteOldHostsAfterHours = [int]$config.DeleteOldHostsAfterHours
}

$retireAfter = (Get-Date).AddHours($deleteOldHostsAfterHours).ToString("o")

Write-Host "Old hosts will be tagged for deletion after: $retireAfter"

foreach ($oldHost in $oldHosts) {

    Write-Host "------------------------------------------------------------"
    Write-Host "Putting host in drain mode: $($oldHost.SessionHostName)"
    Write-Host "VM name: $($oldHost.VmName)"
    Write-Host "------------------------------------------------------------"

    Update-AzWvdSessionHost `
        -ResourceGroupName $config.AvdResourceGroup `
        -HostPoolName $config.HostPoolName `
        -Name $oldHost.SessionHostName `
        -AllowNewSession:$false

    Write-Host "Drain mode enabled for session host: $($oldHost.SessionHostName)"

    $vm = Get-AzVM `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Name $oldHost.VmName `
        -ErrorAction Stop

    $tags = @{}

    if ($vm.Tags) {
        foreach ($tagKey in $vm.Tags.Keys) {
            $tags[$tagKey] = $vm.Tags[$tagKey]
        }
    }

    $tags["PendingDelete"] = "true"
    $tags["RetireAfter"] = $retireAfter
    $tags["DrainModeEnabled"] = "true"
    $tags["OldImageVersion"] = "$($oldHost.ImageVersion)"
    $tags["ReplacementImageVersion"] = $NewImageVersion

    Set-AzResource `
        -ResourceId $vm.Id `
        -Tag $tags `
        -Force

    Write-Host "Tagged old host for deletion after: $retireAfter"
}

Write-Host "------------------------------------------------------------"
Write-Host "Drain mode and tagging completed."
Write-Host "Old hosts marked:"
$oldHosts | ForEach-Object {
    Write-Host "SessionHost: $($_.SessionHostName) | VM: $($_.VmName) | ImageVersion: $($_.ImageVersion)"
}
Write-Host "------------------------------------------------------------"