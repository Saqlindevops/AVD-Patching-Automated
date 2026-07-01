param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

Write-Host "Reading configuration from: $ConfigPath"
$config = Get-Content $ConfigPath | ConvertFrom-Json

Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId

# ------------------------------------------------------------
# Validate or create build resource group
# ------------------------------------------------------------
$buildRg = Get-AzResourceGroup `
    -Name $config.BuildResourceGroup `
    -ErrorAction SilentlyContinue

if (-not $buildRg) {
    Write-Host "Build resource group not found. Creating: $($config.BuildResourceGroup)"

    New-AzResourceGroup `
        -Name $config.BuildResourceGroup `
        -Location $config.Location
}
else {
    Write-Host "Build resource group found: $($config.BuildResourceGroup)"
}

# ------------------------------------------------------------
# Generate unique golden VM name
# ------------------------------------------------------------
if ($config.GoldenVmNameSuffixFormat -and $config.GoldenVmNameSuffixFormat.Trim() -ne "") {
    $suffixFormat = $config.GoldenVmNameSuffixFormat
}
else {
    $suffixFormat = "yyyyMMdd-HHmmss"
}

$runSuffix = Get-Date -Format $suffixFormat
$goldenVmName = "$($config.GoldenVmNamePrefix)-$runSuffix"

# Windows computer name must be 15 characters or less
$computerName = "gavd" + (Get-Date -Format "MMddHHmmss")

if ($computerName.Length -gt 15) {
    $computerName = $computerName.Substring(0, 15)
}

Write-Host "Golden VM resource name: $goldenVmName"
Write-Host "Golden VM computer name: $computerName"

# ------------------------------------------------------------
# Validate Key Vault variables passed from Azure DevOps
# ------------------------------------------------------------
if (-not $env:LocalAdminUsername) {
    throw "LocalAdminUsername environment variable is missing. Check Azure Key Vault task in pipeline."
}

if (-not $env:LocalAdminPassword) {
    throw "LocalAdminPassword environment variable is missing. Check Azure Key Vault task in pipeline."
}

$adminUsername = $env:LocalAdminUsername
$adminPassword = ConvertTo-SecureString $env:LocalAdminPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ($adminUsername, $adminPassword)

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
# Get latest image version from Azure Compute Gallery
# ------------------------------------------------------------
Write-Host "Getting latest image version from gallery..."
Write-Host "Gallery RG: $($config.ImageResourceGroup)"
Write-Host "Gallery Name: $($config.GalleryName)"
Write-Host "Image Definition: $($config.ImageDefinitionName)"

$latestImage = Get-AzGalleryImageVersion `
    -ResourceGroupName $config.ImageResourceGroup `
    -GalleryName $config.GalleryName `
    -GalleryImageDefinitionName $config.ImageDefinitionName |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1

if (-not $latestImage) {
    throw "No image version found in gallery image definition $($config.ImageDefinitionName)."
}

Write-Host "Using source image version: $($latestImage.Name)"
Write-Host "Image ID: $($latestImage.Id)"

# ------------------------------------------------------------
# Create NIC
# ------------------------------------------------------------
$nicName = "$goldenVmName-nic"

Write-Host "Checking if NIC already exists: $nicName"

$existingNic = Get-AzNetworkInterface `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $nicName `
    -ErrorAction SilentlyContinue

if ($existingNic) {
    throw "NIC $nicName already exists. Delete the old NIC or rerun the pipeline with a unique name."
}

Write-Host "Creating NIC: $nicName"

$nic = New-AzNetworkInterface `
    -Name $nicName `
    -ResourceGroupName $config.BuildResourceGroup `
    -Location $config.Location `
    -SubnetId $subnet.Id

# ------------------------------------------------------------
# Security type configuration
# ------------------------------------------------------------
$securityType = $config.SecurityType

if ([string]::IsNullOrWhiteSpace($securityType)) {
    $securityType = "Standard"
}

$enableSecureBoot = $false
$enableVtpm = $false

if ($null -ne $config.EnableSecureBoot) {
    $enableSecureBoot = [System.Convert]::ToBoolean($config.EnableSecureBoot)
}

if ($null -ne $config.EnableVtpm) {
    $enableVtpm = [System.Convert]::ToBoolean($config.EnableVtpm)
}

Write-Host "SecurityType from config: $securityType"
Write-Host "EnableSecureBoot from config: $enableSecureBoot"
Write-Host "EnableVtpm from config: $enableVtpm"

# ------------------------------------------------------------
# Check if VM already exists
# ------------------------------------------------------------
Write-Host "Checking if VM already exists: $goldenVmName"

$existingVm = Get-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Name $goldenVmName `
    -ErrorAction SilentlyContinue

if ($existingVm) {
    throw "VM $goldenVmName already exists. Delete the old VM or rerun the pipeline with a unique name."
}

# ------------------------------------------------------------
# Create VM config
# ------------------------------------------------------------
if ($securityType -eq "TrustedLaunch") {

    Write-Host "Creating VM config with Trusted Launch enabled."

    $vmConfig = New-AzVMConfig `
        -VMName $goldenVmName `
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
        -VMName $goldenVmName `
        -VMSize $config.VmSize
}

# ------------------------------------------------------------
# Configure OS
# ------------------------------------------------------------
$vmConfig = Set-AzVMOperatingSystem `
    -VM $vmConfig `
    -Windows `
    -ComputerName $computerName `
    -Credential $credential `
    -ProvisionVMAgent `
    -EnableAutoUpdate

# ------------------------------------------------------------
# Set source image from gallery image version
# ------------------------------------------------------------
$vmConfig = Set-AzVMSourceImage `
    -VM $vmConfig `
    -Id $latestImage.Id

# ------------------------------------------------------------
# Attach NIC
# ------------------------------------------------------------
$vmConfig = Add-AzVMNetworkInterface `
    -VM $vmConfig `
    -Id $nic.Id

# ------------------------------------------------------------
# Configure OS disk
# ------------------------------------------------------------
$vmConfig = Set-AzVMOSDisk `
    -VM $vmConfig `
    -CreateOption FromImage `
    -StorageAccountType Premium_LRS

# ------------------------------------------------------------
# Boot diagnostics configuration
# If EnableBootDiagnostics = false, no boot diagnostics storage account is created.
# Recommended for temporary golden image build VMs.
# ------------------------------------------------------------
$enableBootDiagnostics = $false

if ($null -ne $config.EnableBootDiagnostics) {
    $enableBootDiagnostics = [System.Convert]::ToBoolean($config.EnableBootDiagnostics)
}

if ($enableBootDiagnostics -eq $true) {
    Write-Host "Boot diagnostics is enabled from config."

    # This enables managed boot diagnostics.
    # No custom storage account is specified here.
    $vmConfig = Set-AzVMBootDiagnostic `
        -VM $vmConfig `
        -Enable
}
else {
    Write-Host "Boot diagnostics is disabled for temporary golden VM."

    $vmConfig = Set-AzVMBootDiagnostic `
        -VM $vmConfig `
        -Disable
}

# ------------------------------------------------------------
# Tags
# ------------------------------------------------------------
$tags = @{
    "Purpose" = "AVD-GoldenImage-Patching"
    "BuildDate" = (Get-Date -Format "yyyyMMdd")
    "BuildTimestamp" = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    "SourceImageVersion" = $latestImage.Name
    "SecurityType" = $securityType
    "BootDiagnostics" = $enableBootDiagnostics.ToString()
    "DeleteCandidate" = "false"
}

# ------------------------------------------------------------
# Create VM
# ------------------------------------------------------------
Write-Host "Creating golden VM: $goldenVmName"

New-AzVM `
    -ResourceGroupName $config.BuildResourceGroup `
    -Location $config.Location `
    -VM $vmConfig `
    -Tag $tags

Write-Host "Golden VM created successfully: $goldenVmName"

# Output variable for Azure DevOps
Write-Host "##vso[task.setvariable variable=GoldenVmName;isOutput=true]$goldenVmName"