param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ImageVersion
)

$ErrorActionPreference = "Stop"

Write-Host "Reading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId

# ------------------------------------------------------------
# Validate required environment variables from Key Vault
# ------------------------------------------------------------
if (-not $env:LocalAdminUsername) {
    throw "LocalAdminUsername environment variable is missing. Check Azure Key Vault task in pipeline."
}

if (-not $env:LocalAdminPassword) {
    throw "LocalAdminPassword environment variable is missing. Check Azure Key Vault task in pipeline."
}

if (-not $env:DomainJoinUsername) {
    throw "DomainJoinUsername environment variable is missing. Check Azure Key Vault task in pipeline."
}

if (-not $env:DomainJoinPassword) {
    throw "DomainJoinPassword environment variable is missing. Check Azure Key Vault task in pipeline."
}

# ------------------------------------------------------------
# Local admin credential
# ------------------------------------------------------------
$adminUsername = $env:LocalAdminUsername
$adminPassword = ConvertTo-SecureString $env:LocalAdminPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ($adminUsername, $adminPassword)

# ------------------------------------------------------------
# Domain join details
# ------------------------------------------------------------
$domainJoinUsername = $env:DomainJoinUsername
$domainJoinPassword = $env:DomainJoinPassword

# ------------------------------------------------------------
# Defaults
# ------------------------------------------------------------
$registrationTokenHours = 8

if ($null -ne $config.AvdRegistrationTokenHours) {
    $registrationTokenHours = [int]$config.AvdRegistrationTokenHours
}

$avdDscModuleUrl = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_09-08-2022.zip"

if ($config.AvdDscModuleUrl -and $config.AvdDscModuleUrl.Trim() -ne "") {
    $avdDscModuleUrl = $config.AvdDscModuleUrl
}

# ------------------------------------------------------------
# Helper: Resolve the latest non-excluded gallery image version
# ------------------------------------------------------------
function Get-LatestGalleryImageVersion {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$GalleryName,

        [Parameter(Mandatory)]
        [string]$ImageDefinitionName
    )

    Write-Host "No ImageVersion supplied. Resolving latest version from gallery: $GalleryName / $ImageDefinitionName"

    $allVersions = Get-AzGalleryImageVersion `
        -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $ImageDefinitionName

    if (-not $allVersions -or $allVersions.Count -eq 0) {
        throw "No image versions found for $ImageDefinitionName in gallery $GalleryName."
    }

    $eligibleVersions = $allVersions | Where-Object {
        ($_.PublishingProfile.ExcludeFromLatest -ne $true) -and
        ($_.ProvisioningState -eq "Succeeded")
    }

    if (-not $eligibleVersions -or $eligibleVersions.Count -eq 0) {
        throw "No eligible non-excluded, successfully provisioned image versions found for $ImageDefinitionName."
    }

    $latest = $eligibleVersions |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1

    Write-Host "Resolved latest image version: $($latest.Name)"

    return $latest.Name
}

# ------------------------------------------------------------
# Helper: Generate AVD host pool registration token
# ------------------------------------------------------------
function New-AvdHostPoolRegistrationToken {
    param(
        [Parameter(Mandatory)]
        [string]$AvdResourceGroup,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [int]$TokenValidHours
    )

    $expirationTime = (Get-Date).ToUniversalTime().AddHours($TokenValidHours).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

    Write-Host "Generating AVD registration token for host pool: $HostPoolName"
    Write-Host "Token expiration UTC: $expirationTime"

    $registrationInfo = New-AzWvdRegistrationInfo `
        -ResourceGroupName $AvdResourceGroup `
        -HostPoolName $HostPoolName `
        -ExpirationTime $expirationTime

    if (-not $registrationInfo -or [string]::IsNullOrWhiteSpace($registrationInfo.Token)) {
        throw "Failed to generate AVD registration token for host pool $HostPoolName."
    }

    Write-Host "AVD registration token generated successfully."

    return $registrationInfo.Token
}

# ------------------------------------------------------------
# Helper: Wait for VM and VM Agent to become ready
# ------------------------------------------------------------
function Wait-AvdVmReady {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VMName,

        [int]$TimeoutMinutes = 30
    )

    Write-Host "Waiting for VM to become ready: $VMName"

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {

        try {
            $vmStatus = Get-AzVM `
                -ResourceGroupName $ResourceGroupName `
                -Name $VMName `
                -Status `
                -ErrorAction Stop

            $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
            $agentStatus = ($vmStatus.VMAgent.Statuses | Select-Object -First 1).DisplayStatus

            Write-Host "VM: $VMName | PowerState: $powerState | AgentStatus: $agentStatus"

            if ($powerState -eq "VM running" -and $agentStatus -eq "Ready") {
                Write-Host "VM is ready: $VMName"
                return
            }
        }
        catch {
            Write-Warning "VM readiness check failed for $VMName. Retrying. Error: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 30
    }

    throw "Timed out waiting for VM Agent to become ready on VM: $VMName"
}

# ------------------------------------------------------------
# Helper: Wait for AVD session host registration
# ------------------------------------------------------------
function Wait-AvdSessionHostRegistration {
    param(
        [Parameter(Mandatory)]
        [string]$AvdResourceGroup,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$VMName,

        [int]$TimeoutMinutes = 30
    )

    Write-Host "Waiting for VM to register as AVD session host: $VMName"

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {

        try {
            $sessionHosts = Get-AzWvdSessionHost `
                -ResourceGroupName $AvdResourceGroup `
                -HostPoolName $HostPoolName `
                -ErrorAction Stop

            $matchedSessionHost = $sessionHosts | Where-Object {
                $rawName = ($_.Name -split "/")[-1]
                $shortName = ($rawName -split "\.")[0]
                $shortName -ieq $VMName
            } | Select-Object -First 1

            if ($matchedSessionHost) {
                Write-Host "AVD session host registration found: $($matchedSessionHost.Name)"
                return
            }
        }
        catch {
            Write-Warning "Session host registration check failed for $VMName. Retrying. Error: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 30
    }

    throw "Timed out waiting for VM to appear as AVD session host: $VMName"
}

# ------------------------------------------------------------
# Resolve ImageVersion if not explicitly provided
# ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ImageVersion)) {
    $ImageVersion = Get-LatestGalleryImageVersion `
        -ResourceGroupName $config.ImageResourceGroup `
        -GalleryName $config.GalleryName `
        -ImageDefinitionName $config.ImageDefinitionName
}
else {
    Write-Host "Using explicitly supplied ImageVersion: $ImageVersion"
}

# ------------------------------------------------------------
# Get target image version
# ------------------------------------------------------------
Write-Host "Getting image version: $ImageVersion"

$image = Get-AzGalleryImageVersion `
    -ResourceGroupName $config.ImageResourceGroup `
    -GalleryName $config.GalleryName `
    -GalleryImageDefinitionName $config.ImageDefinitionName `
    -Name $ImageVersion

if (-not $image) {
    throw "Image version $ImageVersion not found in gallery $($config.GalleryName)."
}

Write-Host "Using image ID: $($image.Id)"

# ------------------------------------------------------------
# Get subnet details
# ------------------------------------------------------------
Write-Host "Getting VNet: $($config.VnetName) from RG: $($config.VnetResourceGroup)"

$vnet = Get-AzVirtualNetwork `
    -ResourceGroupName $config.VnetResourceGroup `
    -Name $config.VnetName

$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $config.SubnetName }

if (-not $subnet) {
    throw "Subnet $($config.SubnetName) not found in VNet $($config.VnetName)."
}

Write-Host "Using subnet: $($subnet.Name)"

# ------------------------------------------------------------
# Security type configuration
# ------------------------------------------------------------
$securityType = $config.SecurityType

if ([string]::IsNullOrWhiteSpace($securityType)) {
    $securityType = "Standard"
}

$enableSecureBoot = $false
if ($null -ne $config.EnableSecureBoot) {
    $enableSecureBoot = [System.Convert]::ToBoolean($config.EnableSecureBoot)
}

$enableVtpm = $false
if ($null -ne $config.EnableVtpm) {
    $enableVtpm = [System.Convert]::ToBoolean($config.EnableVtpm)
}

Write-Host "SecurityType from config: $securityType"
Write-Host "EnableSecureBoot from config: $enableSecureBoot"
Write-Host "EnableVtpm from config: $enableVtpm"

# ------------------------------------------------------------
# Helper: Collect VM name indices already in use
# ------------------------------------------------------------
function Get-UsedVmIndices {
    param(
        [Parameter(Mandatory)]
        [string]$SessionHostResourceGroup,

        [Parameter(Mandatory)]
        [string]$VmNamePrefix,

        [Parameter(Mandatory)]
        [string]$AvdResourceGroup,

        [Parameter(Mandatory)]
        [string]$HostPoolName
    )

    $usedIndices = New-Object 'System.Collections.Generic.HashSet[int]'
    $namePattern = "^$([regex]::Escape($VmNamePrefix))-(\d+)$"

    Write-Host "Checking existing VMs in resource group: $SessionHostResourceGroup"

    $existingVms = Get-AzVM `
        -ResourceGroupName $SessionHostResourceGroup `
        -ErrorAction SilentlyContinue

    if ($existingVms) {
        foreach ($existingVm in $existingVms) {
            if ($existingVm.Name -match $namePattern) {
                Write-Host "Found existing VM using index: $($existingVm.Name)"
                [void]$usedIndices.Add([int]$Matches[1])
            }
        }
    }
    else {
        Write-Host "No existing VM resources found in resource group: $SessionHostResourceGroup"
    }

    Write-Host "Checking existing session hosts in host pool: $HostPoolName"

    try {
        $sessionHosts = Get-AzWvdSessionHost `
            -ResourceGroupName $AvdResourceGroup `
            -HostPoolName $HostPoolName `
            -ErrorAction Stop

        if ($sessionHosts) {
            foreach ($sessionHost in $sessionHosts) {
                $rawName = ($sessionHost.Name -split '/')[-1]
                $shortName = ($rawName -split '\.')[0]

                if ($shortName -match $namePattern) {
                    Write-Host "Found registered session host using index: $shortName"
                    [void]$usedIndices.Add([int]$Matches[1])
                }
            }
        }
        else {
            Write-Host "No existing session hosts found in host pool: $HostPoolName"
        }
    }
    catch {
        Write-Warning "Could not query existing session hosts in host pool '$HostPoolName': $($_.Exception.Message)"
        Write-Warning "Continuing with VM-resource-based index check only."
    }

    return ,$usedIndices
}

# ------------------------------------------------------------
# Helper: Find next available index
# ------------------------------------------------------------
function Get-NextAvailableIndex {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[int]]$UsedIndices,

        [int]$StartFrom = 0
    )

    if ($null -eq $UsedIndices) {
        Write-Host "UsedIndices was null inside Get-NextAvailableIndex. Initializing empty index set."
        $UsedIndices = New-Object 'System.Collections.Generic.HashSet[int]'
    }

    $candidate = $StartFrom

    while ($UsedIndices.Contains($candidate)) {
        $candidate++
    }

    return $candidate
}

# ------------------------------------------------------------
# Helper: Determine blue/green deployment block
# ------------------------------------------------------------
function Get-NextDeploymentBlockStart {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[int]]$UsedIndices
    )

    if ($null -eq $UsedIndices) {
        Write-Host "UsedIndices was null inside Get-NextDeploymentBlockStart. Initializing empty index set."
        $UsedIndices = New-Object 'System.Collections.Generic.HashSet[int]'
    }

    $block100 = 100
    $block200 = 200

    $usedIndexArray = @($UsedIndices)

    $hasBlock200 = $usedIndexArray | Where-Object { $_ -ge 200 -and $_ -lt 300 }
    $hasBlock100 = $usedIndexArray | Where-Object { $_ -ge 100 -and $_ -lt 200 }

    if ($hasBlock200) {
        Write-Host "Existing hosts found in the 200 block. Deploying new batch into the 100 block."
        return $block100
    }

    if ($hasBlock100) {
        Write-Host "Existing hosts found in the 100 block. Deploying new batch into the 200 block."
        return $block200
    }

    Write-Host "No existing hosts found in either block. Defaulting new batch to the 100 block."
    return $block100
}

# ------------------------------------------------------------
# Build VM tracking
# ------------------------------------------------------------
$buildDate = Get-Date -Format "yyyyMMdd"
$newVmNames = @()

$usedIndices = Get-UsedVmIndices `
    -SessionHostResourceGroup $config.SessionHostResourceGroup `
    -VmNamePrefix $config.VmNamePrefix `
    -AvdResourceGroup $config.AvdResourceGroup `
    -HostPoolName $config.HostPoolName

if ($null -eq $usedIndices) {
    Write-Host "UsedIndices returned as null. Initializing empty HashSet as fallback."
    $usedIndices = New-Object 'System.Collections.Generic.HashSet[int]'
}

$usedIndexText = (@($usedIndices) | Sort-Object) -join ', '

if ([string]::IsNullOrWhiteSpace($usedIndexText)) {
    Write-Host "Indices already in use: none"
}
else {
    Write-Host "Indices already in use: $usedIndexText"
}

$deploymentBlockStart = Get-NextDeploymentBlockStart -UsedIndices $usedIndices
Write-Host "New batch will be deployed starting from index: $deploymentBlockStart"

# ------------------------------------------------------------
# Generate AVD registration token once for this batch
# ------------------------------------------------------------
$hostPoolRegistrationToken = New-AvdHostPoolRegistrationToken `
    -AvdResourceGroup $config.AvdResourceGroup `
    -HostPoolName $config.HostPoolName `
    -TokenValidHours $registrationTokenHours

# ------------------------------------------------------------
# Create new AVD session host VMs
# ------------------------------------------------------------
for ($i = 1; $i -le $config.NewHostCount; $i++) {

    $nextIndex = Get-NextAvailableIndex `
        -UsedIndices $usedIndices `
        -StartFrom $deploymentBlockStart

    [void]$usedIndices.Add($nextIndex)

    $vmName = "$($config.VmNamePrefix)-$nextIndex"
    $nicName = "$vmName-nic"

    if ($vmName.Length -gt 15) {
        throw "Generated computer name '$vmName' exceeds the 15 character Windows computer name limit. Shorten VmNamePrefix in config."
    }

    if ($vmName -match '^\d+$') {
        throw "Generated computer name '$vmName' is entirely numeric, which Windows does not allow. Adjust VmNamePrefix in config so it contains at least one letter."
    }

    Write-Host "------------------------------------------------------------"
    Write-Host "Creating new AVD session host VM: $vmName"
    Write-Host "------------------------------------------------------------"

    # --------------------------------------------------------
    # Create NIC
    # --------------------------------------------------------
    Write-Host "Creating NIC: $nicName"

    $nic = New-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Location $config.Location `
        -SubnetId $subnet.Id

    # --------------------------------------------------------
    # Create VM config with security settings
    # --------------------------------------------------------
    if ($securityType -eq "TrustedLaunch") {

        Write-Host "Creating VM config with Trusted Launch enabled."

        $vmConfig = New-AzVMConfig `
            -VMName $vmName `
            -VMSize $config.VmSize `
            -SecurityType "TrustedLaunch"

        $vmConfig = Set-AzVMUefi `
            -VM $vmConfig `
            -EnableVtpm $enableVtpm `
            -EnableSecureBoot $enableSecureBoot
    }
    else {

        Write-Host "Creating VM config with Standard security type."

        $vmConfig = New-AzVMConfig `
            -VMName $vmName `
            -VMSize $config.VmSize
    }

    # --------------------------------------------------------
    # Configure OS
    # --------------------------------------------------------
    Write-Host "Azure VM resource name / Windows computer name: $vmName"

    $vmConfig = Set-AzVMOperatingSystem `
        -VM $vmConfig `
        -Windows `
        -ComputerName $vmName `
        -Credential $credential `
        -ProvisionVMAgent `
        -EnableAutoUpdate

    # --------------------------------------------------------
    # Set source image
    # --------------------------------------------------------
    $vmConfig = Set-AzVMSourceImage `
        -VM $vmConfig `
        -Id $image.Id

    # --------------------------------------------------------
    # Attach NIC
    # --------------------------------------------------------
    $vmConfig = Add-AzVMNetworkInterface `
        -VM $vmConfig `
        -Id $nic.Id

    # --------------------------------------------------------
    # Configure OS disk
    # --------------------------------------------------------
    $vmConfig = Set-AzVMOSDisk `
        -VM $vmConfig `
        -CreateOption FromImage `
        -StorageAccountType Premium_LRS

    # --------------------------------------------------------
    # Disable boot diagnostics
    # This prevents Azure from creating boot diagnostics storage accounts.
    # --------------------------------------------------------
    Write-Host "Disabling boot diagnostics for VM: $vmName"

    $vmConfig = Set-AzVMBootDiagnostic `
        -VM $vmConfig `
        -Disable

    # --------------------------------------------------------
    # Tags
    # --------------------------------------------------------
    $tags = @{
        "Role"          = "AVDSessionHost"
        "ImageVersion"  = $ImageVersion
        "Generation"    = "new"
        "BuildDate"     = $buildDate
        "HostPool"      = $config.HostPoolName
        "SecurityType"  = $securityType
        "PendingDelete" = "false"
    }

    # --------------------------------------------------------
    # Create VM
    # --------------------------------------------------------
    Write-Host "Creating VM: $vmName"

    New-AzVM `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Location $config.Location `
        -VM $vmConfig `
        -Tag $tags

    Write-Host "VM created successfully: $vmName"

    # --------------------------------------------------------
    # Apply hybrid domain join extension
    # --------------------------------------------------------
    Write-Host "Starting domain join for VM: $vmName"

    $domainJoinSettings = @{
        Name    = $config.DomainName
        User    = "$($config.DomainName)\$domainJoinUsername"
        Restart = "true"
        Options = 3
    }

    if ($config.DomainJoinOUPath -and $config.DomainJoinOUPath.Trim() -ne "") {
        $domainJoinSettings["OUPath"] = $config.DomainJoinOUPath
        Write-Host "Using OU Path: $($config.DomainJoinOUPath)"
    }
    else {
        Write-Host "No OU Path provided. Computer object will be created in default Computers container."
    }

    $domainJoinProtectedSettings = @{
        Password = $domainJoinPassword
    }

    Set-AzVMExtension `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Location $config.Location `
        -VMName $vmName `
        -Name "joindomain" `
        -Publisher "Microsoft.Compute" `
        -ExtensionType "JsonADDomainExtension" `
        -TypeHandlerVersion "1.3" `
        -Settings $domainJoinSettings `
        -ProtectedSettings $domainJoinProtectedSettings

    Write-Host "Domain join extension applied to VM: $vmName"
    Write-Host "VM will restart as part of domain join process."

    # --------------------------------------------------------
    # Wait for domain join reboot to complete
    # --------------------------------------------------------
    Wait-AvdVmReady `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -VMName $vmName `
        -TimeoutMinutes 30

    # --------------------------------------------------------
    # Register VM to AVD host pool using DSC extension
    # --------------------------------------------------------
    Write-Host "Starting AVD host pool registration for VM: $vmName"

    $avdRegistrationSettings = @{
        modulesUrl            = $avdDscModuleUrl
        configurationFunction = "Configuration.ps1\AddSessionHost"
        properties            = @{
            hostPoolName = $config.HostPoolName
            aadJoin      = $false
        }
    }

    $avdRegistrationProtectedSettings = @{
        properties = @{
            registrationInfoToken = $hostPoolRegistrationToken
        }
    }

    Set-AzVMExtension `
        -ResourceGroupName $config.SessionHostResourceGroup `
        -Location $config.Location `
        -VMName $vmName `
        -Name "AVDRegistration" `
        -Publisher "Microsoft.Powershell" `
        -ExtensionType "DSC" `
        -TypeHandlerVersion "2.83" `
        -Settings $avdRegistrationSettings `
        -ProtectedSettings $avdRegistrationProtectedSettings

    Write-Host "AVD registration extension applied to VM: $vmName"

    # --------------------------------------------------------
    # Wait until VM appears in AVD host pool
    # --------------------------------------------------------
    Wait-AvdSessionHostRegistration `
        -AvdResourceGroup $config.AvdResourceGroup `
        -HostPoolName $config.HostPoolName `
        -VMName $vmName `
        -TimeoutMinutes 30

    Write-Host "VM successfully registered as AVD session host: $vmName"

    $newVmNames += $vmName
}

Write-Host "------------------------------------------------------------"
Write-Host "New VM deployment and AVD registration completed."
Write-Host "------------------------------------------------------------"

Write-Host "New VMs created and registered:"
$newVmNames | ForEach-Object { Write-Host $_ }

Write-Host "Image version used: $ImageVersion"
Write-Host "Host pool: $($config.HostPoolName)"
Write-Host "------------------------------------------------------------"