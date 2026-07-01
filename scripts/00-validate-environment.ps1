param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
)

# ============================================================================
#  Pre-flight validation for the automated AVD patching run.
#  Purpose: fail FAST, before any resource is created, if the configuration
#  or the Azure environment is not in a state where the run can succeed.
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host "Reading configuration from: $ConfigPath"

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at path: $ConfigPath"
}

$config = Get-Content $ConfigPath | ConvertFrom-Json

# ------------------------------------------------------------
# 1. Required fields must be present and non-empty
# ------------------------------------------------------------
$requiredFields = @(
    "SubscriptionId",
    "Location",
    "ImageResourceGroup",
    "GalleryName",
    "ImageDefinitionName",
    "BuildResourceGroup",
    "KeyVaultName",
    "VnetResourceGroup",
    "VnetName",
    "SubnetName",
    "AvdResourceGroup",
    "HostPoolName",
    "SessionHostResourceGroup",
    "VmNamePrefix",
    "VmSize",
    "DomainName"
)

$missing = @()

foreach ($field in $requiredFields) {
    $value = $config.$field
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        $missing += $field
    }
}

if ($missing.Count -gt 0) {
    throw "The following required config fields are missing or empty: $($missing -join ', ')"
}

Write-Host "All required config fields are present."

# ------------------------------------------------------------
# 2. Azure context
# ------------------------------------------------------------
Write-Host "Setting Azure context to subscription: $($config.SubscriptionId)"
Set-AzContext -SubscriptionId $config.SubscriptionId | Out-Null

# ------------------------------------------------------------
# 3. Key Vault must exist and be reachable
# ------------------------------------------------------------
Write-Host "Checking Key Vault: $($config.KeyVaultName)"

$keyVault = Get-AzKeyVault -VaultName $config.KeyVaultName -ErrorAction SilentlyContinue

if (-not $keyVault) {
    throw "Key Vault '$($config.KeyVaultName)' was not found or is not accessible with this service connection."
}

Write-Host "Key Vault found: $($keyVault.VaultName)"

# ------------------------------------------------------------
# 4. Source gallery image definition must have at least one version
#    (the golden VM is built from the latest version)
# ------------------------------------------------------------
Write-Host "Checking source image definition: $($config.GalleryName) / $($config.ImageDefinitionName)"

$imageVersions = Get-AzGalleryImageVersion `
    -ResourceGroupName $config.ImageResourceGroup `
    -GalleryName $config.GalleryName `
    -GalleryImageDefinitionName $config.ImageDefinitionName `
    -ErrorAction SilentlyContinue

if (-not $imageVersions -or $imageVersions.Count -eq 0) {
    throw "No image versions found in gallery '$($config.GalleryName)' image definition '$($config.ImageDefinitionName)'. A base image is required to build the golden VM."
}

Write-Host "Source image versions available: $($imageVersions.Count)"

# ------------------------------------------------------------
# 5. VNet and subnet must exist
# ------------------------------------------------------------
Write-Host "Checking VNet: $($config.VnetName) in RG: $($config.VnetResourceGroup)"

$vnet = Get-AzVirtualNetwork `
    -ResourceGroupName $config.VnetResourceGroup `
    -Name $config.VnetName `
    -ErrorAction SilentlyContinue

if (-not $vnet) {
    throw "VNet '$($config.VnetName)' not found in resource group '$($config.VnetResourceGroup)'."
}

$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $config.SubnetName }

if (-not $subnet) {
    throw "Subnet '$($config.SubnetName)' not found in VNet '$($config.VnetName)'."
}

Write-Host "Subnet found: $($subnet.Name)"

# ------------------------------------------------------------
# 6. AVD host pool must exist
# ------------------------------------------------------------
Write-Host "Checking AVD host pool: $($config.HostPoolName) in RG: $($config.AvdResourceGroup)"

$hostPool = Get-AzWvdHostPool `
    -ResourceGroupName $config.AvdResourceGroup `
    -Name $config.HostPoolName `
    -ErrorAction SilentlyContinue

if (-not $hostPool) {
    throw "AVD host pool '$($config.HostPoolName)' not found in resource group '$($config.AvdResourceGroup)'."
}

Write-Host "Host pool found: $($hostPool.Name)"

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
Write-Host "------------------------------------------------------------"
Write-Host "Pre-flight validation passed. The environment is ready to build."
Write-Host "------------------------------------------------------------"
