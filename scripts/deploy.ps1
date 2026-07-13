param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$Location = 'eastus',

    [Parameter()]
    [string]$ResourceGroupName = 'rg-nap-metrics',

    [Parameter()]
    [string]$VNetName = 'vnet-nap-metrics',

    [Parameter()]
    [string]$VNetAddressPrefix = '10.225.0.0/16',

    [Parameter()]
    [string]$NodeSubnetName = 'snet-aks-nodes',

    [Parameter()]
    [string]$NodeSubnetPrefix = '10.225.1.0/24',

    [Parameter()]
    [string]$ApiServerSubnetName = 'snet-aks-apiserver',

    [Parameter()]
    [string]$ApiServerSubnetPrefix = '10.225.2.0/28',

    [Parameter()]
    [string]$ClusterName = 'aks-nap-metrics',

    [Parameter()]
    [string]$NodeResourceGroupName = 'rg-nap-metrics-nodes',

    [Parameter()]
    [string]$ManagedIdentityName = 'id-nap-metrics-aks',

    [Parameter()]
    [string]$AcrName = 'napmetrics'+(Get-Random -Minimum 10 -Maximum 15),

    [Parameter()]
    [string]$AcrSku = 'Standard',

    [Parameter()]
    [string]$KubernetesVersion = '1.33',

    [Parameter()]
    [int]$SystemNodeCount = 3,

    [Parameter()]
    [string]$SystemNodeVmSize = 'Standard_D4s_v5',

    [Parameter()]
    [string]$ImageName = 'nap-custom-exporter',

    [Parameter()]
    [string]$ImageTag = 'latest',

    [Parameter()]
    [string]$PrometheusNamespace = 'monitoring',

    [Parameter()]
    [string]$PrometheusReleaseName = 'prometheus',

    [Parameter()]
    [switch]$SkipBuild,

    [Parameter()]
    [switch]$SkipAksCreate,

    [Parameter()]
    [switch]$SkipPrometheus,

    [Parameter()]
    [switch]$SkipDeploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Require-Command {
    param([string]$CommandName)

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' was not found in PATH."
    }
}

function Invoke-Az {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter()]
        [switch]$ReturnJson,

        [Parameter()]
        [switch]$ReturnText
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$output"
    }

    if ($ReturnJson) {
        if (-not $output) {
            return $null
        }

        $outputText = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            return $null
        }

        $firstBrace = $outputText.IndexOf('{')
        $firstBracket = $outputText.IndexOf('[')
        $jsonStart = -1
        if ($firstBrace -ge 0 -and $firstBracket -ge 0) {
            $jsonStart = [Math]::Min($firstBrace, $firstBracket)
        }
        elseif ($firstBrace -ge 0) {
            $jsonStart = $firstBrace
        }
        elseif ($firstBracket -ge 0) {
            $jsonStart = $firstBracket
        }

        $lastBrace = $outputText.LastIndexOf('}')
        $lastBracket = $outputText.LastIndexOf(']')
        $jsonEnd = [Math]::Max($lastBrace, $lastBracket)

        if ($jsonStart -lt 0 -or $jsonEnd -lt $jsonStart) {
            throw "Expected JSON output from az, but received:`n$outputText"
        }

        $jsonText = $outputText.Substring($jsonStart, ($jsonEnd - $jsonStart + 1))
        return $jsonText | ConvertFrom-Json
    }

    if ($ReturnText) {
        return ($output | Out-String).Trim()
    }

    return $output
}

function Test-VersionGreaterOrEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Current,

        [Parameter(Mandatory = $true)]
        [string]$Minimum
    )

    return ([version]$Current) -ge ([version]$Minimum)
}

function Get-DefaultAcrName {
    param([string]$Seed)

    $sanitized = ($Seed.ToLower() -replace '[^a-z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $sanitized = 'napmetrics'
    }

    $prefix = if ($sanitized.Length -gt 18) { $sanitized.Substring(0, 18) } else { $sanitized }
    $suffix = Get-Random -Minimum 10000 -Maximum 99999
    return "$prefix$suffix"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$dockerfilePath = Join-Path $repoRoot 'Dockerfile'
$manifestPath = Join-Path $scriptRoot 'manifests\nap-custom-exporter.yaml'

Require-Command 'az'
if (-not $SkipBuild) {
    Require-Command 'docker'
}
if (-not $SkipPrometheus) {
    Require-Command 'helm'
}

if (-not (Test-Path $manifestPath)) {
    throw "Expected manifest not found: $manifestPath"
}

if (-not $SkipBuild -and -not (Test-Path $dockerfilePath)) {
    throw "Expected Dockerfile not found: $dockerfilePath"
}

if ([string]::IsNullOrWhiteSpace($Location)) {
    $Location = 'eastus'
}

Write-Step 'Checking Azure CLI version and login context'
$azVersionInfo = Invoke-Az -Arguments @('version', '--output', 'json') -ReturnJson
$azCliVersion = $azVersionInfo.'azure-cli'
if (-not (Test-VersionGreaterOrEqual -Current $azCliVersion -Minimum '2.76.0')) {
    throw "Azure CLI 2.76.0 or later is required for AKS NAP. Current version: $azCliVersion"
}

$account = Invoke-Az -Arguments @('account', 'show', '--output', 'json') -ReturnJson
if (-not $SubscriptionId) {
    $SubscriptionId = $account.id
}

Invoke-Az -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

if (-not $AcrName) {
    $AcrName = Get-DefaultAcrName -Seed $ClusterName
}

Write-Step 'Resolved deployment settings'
Write-Host "SubscriptionId      : $SubscriptionId"
Write-Host "Location            : $Location"
Write-Host "ResourceGroup       : $ResourceGroupName"
Write-Host "VNet                : $VNetName"
Write-Host "AKS Cluster         : $ClusterName"
Write-Host "Kubernetes Version  : $KubernetesVersion"
Write-Host "ACR                 : $AcrName"
Write-Host "Prometheus Release  : $PrometheusReleaseName"

Write-Step 'Validating the requested AKS version is available in the target region'
$availableVersionsText = Invoke-Az -Arguments @(
    'aks', 'get-versions',
    '--location', $Location,
    '--query', 'values[].version',
    '--output', 'tsv'
) -ReturnText

$availableVersionList = @($availableVersionsText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($availableVersionList -notcontains $KubernetesVersion) {
    $matchingMinor = @($availableVersionList | select-string 1.33)
    $hint = if ($matchingMinor.Count -gt 0) {
        "Available 1.31 builds in ${Location}: $($matchingMinor -join ', ')"
    }
    else {
        "Run 'az aks get-versions --location $Location -o table' to choose a supported version."
    }

    throw "Kubernetes version $KubernetesVersion is not available in $Location. $hint"
}

Write-Step 'Creating resource group'
Invoke-Az -Arguments @('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '--output', 'none') | Out-Null

Write-Step 'Creating virtual network and subnets for AKS NAP'
Invoke-Az -Arguments @(
    'network', 'vnet', 'create',
    '--resource-group', $ResourceGroupName,
    '--name', $VNetName,
    '--location', $Location,
    '--address-prefixes', $VNetAddressPrefix,
    '--output', 'none'
) | Out-Null

Invoke-Az -Arguments @(
    'network', 'vnet', 'subnet', 'create',
    '--resource-group', $ResourceGroupName,
    '--vnet-name', $VNetName,
    '--name', $NodeSubnetName,
    '--address-prefixes', $NodeSubnetPrefix,
    '--output', 'none'
) | Out-Null

Invoke-Az -Arguments @(
    'network', 'vnet', 'subnet', 'create',
    '--resource-group', $ResourceGroupName,
    '--vnet-name', $VNetName,
    '--name', $ApiServerSubnetName,
    '--address-prefixes', $ApiServerSubnetPrefix,
    '--delegations', 'Microsoft.ContainerService/managedClusters',
    '--output', 'none'
) | Out-Null

$nodeSubnetId = Invoke-Az -Arguments @(
    'network', 'vnet', 'subnet', 'show',
    '--resource-group', $ResourceGroupName,
    '--vnet-name', $VNetName,
    '--name', $NodeSubnetName,
    '--query', 'id',
    '--output', 'tsv'
) -ReturnText

$apiServerSubnetId = Invoke-Az -Arguments @(
    'network', 'vnet', 'subnet', 'show',
    '--resource-group', $ResourceGroupName,
    '--vnet-name', $VNetName,
    '--name', $ApiServerSubnetName,
    '--query', 'id',
    '--output', 'tsv'
) -ReturnText

Write-Step 'Creating user-assigned managed identity for the AKS control plane'
Invoke-Az -Arguments @(
    'identity', 'create',
    '--resource-group', $ResourceGroupName,
    '--name', $ManagedIdentityName,
    '--location', $Location,
    '--output', 'none'
) | Out-Null

$managedIdentity = Invoke-Az -Arguments @(
    'identity', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $ManagedIdentityName,
    '--output', 'json'
) -ReturnJson

$vnetScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$VNetName"

Write-Step 'Granting the AKS managed identity network permissions on the VNet'
try {
    Invoke-Az -Arguments @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $managedIdentity.principalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Network Contributor',
        '--scope', $vnetScope,
        '--output', 'none'
    ) | Out-Null
}
catch {
    $message = $_.Exception.Message
    if ($message -notmatch 'RoleAssignmentExists') {
        throw
    }
}

Write-Step 'Creating Azure Container Registry'
Invoke-Az -Arguments @(
    'acr', 'create',
    '--resource-group', $ResourceGroupName,
    '--name', $AcrName,
    '--sku', $AcrSku,
    '--admin-enabled', 'false',
    '--output', 'none'
) | Out-Null

$acrLoginServer = Invoke-Az -Arguments @(
    'acr', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $AcrName,
    '--query', 'loginServer',
    '--output', 'tsv'
) -ReturnText

$imageUri = "$acrLoginServer/$ImageName`:$ImageTag"

if (-not $SkipBuild) {
    Write-Step 'Logging in to ACR and building the exporter image'
    Invoke-Az -Arguments @('acr', 'login', '--name', $AcrName, '--output', 'none') | Out-Null

    & docker build --file $dockerfilePath --tag $imageUri $repoRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed for image $imageUri"
    }

    Write-Step 'Pushing the exporter image to ACR'
    & docker push $imageUri
    if ($LASTEXITCODE -ne 0) {
        throw "Docker push failed for image $imageUri"
    }
}

if (-not $SkipAksCreate) {
    Write-Step 'Creating the AKS cluster with managed Karpenter via NAP'
    Invoke-Az -Arguments @(
        'aks', 'create',
        '--resource-group', $ResourceGroupName,
        '--name', $ClusterName,
        '--location', $Location,
        '--node-resource-group', $NodeResourceGroupName,
        '--tier', 'standard',
        '--kubernetes-version', $KubernetesVersion,
        '--node-count', $SystemNodeCount.ToString(),
        '--node-vm-size', $SystemNodeVmSize,
        '--nodepool-name', 'systemnp',
        '--os-sku', 'Ubuntu2204',
        '--load-balancer-sku', 'standard',
        '--network-plugin', 'azure',
        '--network-plugin-mode', 'overlay',
        '--network-dataplane', 'cilium',
        '--network-policy', 'cilium',
        '--vnet-subnet-id', $nodeSubnetId,
        '--enable-apiserver-vnet-integration',
        '--apiserver-subnet-id', $apiServerSubnetId,
        '--assign-identity', $managedIdentity.id,
        '--enable-managed-identity',
        '--attach-acr', $AcrName,
        '--enable-oidc-issuer',
        '--enable-workload-identity',
        '--node-provisioning-mode', 'Auto',
        '--node-provisioning-default-pools', 'Auto',
        '--auto-upgrade-channel', 'patch',
        '--generate-ssh-keys',
        '--yes',
        '--output', 'none'
    ) | Out-Null
}

Write-Step 'Ensuring AKS can pull images from ACR'
Invoke-Az -Arguments @(
    'aks', 'update',
    '--resource-group', $ResourceGroupName,
    '--name', $ClusterName,
    '--attach-acr', $AcrName,
    '--output', 'none'
) | Out-Null

Write-Step 'Installing kubectl if needed and fetching cluster credentials'
if (-not (Get-Command 'kubectl' -ErrorAction SilentlyContinue)) {
    Invoke-Az -Arguments @('aks', 'install-cli', '--output', 'none') | Out-Null
}

Invoke-Az -Arguments @(
    'aks', 'get-credentials',
    '--resource-group', $ResourceGroupName,
    '--name', $ClusterName,
    '--overwrite-existing'
) | Out-Null

Write-Step 'Validating managed Karpenter resources exist on the cluster'
& kubectl get crd nodeclaims.karpenter.sh
if ($LASTEXITCODE -ne 0) {
    throw 'The nodeclaims.karpenter.sh CRD was not found. AKS NAP/Karpenter is not ready on the cluster.'
}

& kubectl get nodepools.karpenter.sh
if ($LASTEXITCODE -ne 0) {
    throw 'Karpenter NodePools were not found. The default NAP pools were not created as expected.'
}

& kubectl get nodepool default
if ($LASTEXITCODE -ne 0) {
    throw 'The default managed Karpenter NodePool was not found.'
}

& kubectl get nodepool system-surge
if ($LASTEXITCODE -ne 0) {
    throw 'The system-surge managed Karpenter NodePool was not found.'
}

if (-not $SkipPrometheus) {
    Write-Step 'Installing self-hosted Prometheus with kube-prometheus-stack default values'
    & helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to add the prometheus-community Helm repository.'
    }

    & helm repo update
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to update Helm repositories.'
    }

    & helm upgrade --install $PrometheusReleaseName prometheus-community/kube-prometheus-stack --namespace $PrometheusNamespace --create-namespace
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to install kube-prometheus-stack.'
    }

    & kubectl wait --namespace $PrometheusNamespace --for=condition=Available deployment/$($PrometheusReleaseName)-kube-prometheus-operator --timeout=300s
    if ($LASTEXITCODE -ne 0) {
        throw 'The Prometheus operator deployment did not become available.'
    }

    & kubectl rollout status statefulset/$($PrometheusReleaseName)-prometheus-kube-prometheus-prometheus -n $PrometheusNamespace --timeout=600s
    if ($LASTEXITCODE -ne 0) {
        throw 'The Prometheus StatefulSet did not become ready.'
    }
}

if (-not $SkipDeploy) {
    Write-Step 'Deploying the exporter manifest to the AKS cluster'
    & kubectl apply -f $manifestPath
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl apply failed for $manifestPath"
    }

    # Keep ServiceMonitor selector aligned with the chosen kube-prometheus-stack release name.
    $serviceMonitorResource = & kubectl get servicemonitor nap-custom-exporter -n nap-exporter --ignore-not-found -o name
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to query ServiceMonitor resource.'
    }
    elseif ($serviceMonitorResource) {
        & kubectl label servicemonitor nap-custom-exporter -n nap-exporter "release=$PrometheusReleaseName" --overwrite
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to align ServiceMonitor release label with Prometheus release name.'
        }
    }
    else {
        Write-Warning 'ServiceMonitor nap-custom-exporter was not found; skipping release label alignment.'
    }

    & kubectl set image deployment/nap-custom-exporter exporter=$imageUri -n nap-exporter
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to update the exporter deployment image.'
    }

    & kubectl rollout status deployment/nap-custom-exporter -n nap-exporter --timeout=180s
    if ($LASTEXITCODE -ne 0) {
        throw 'The exporter deployment did not become ready.'
    }
}

Write-Step 'Deployment complete'
Write-Host "ACR Login Server      : $acrLoginServer" -ForegroundColor Green
Write-Host "Exporter Image        : $imageUri" -ForegroundColor Green
Write-Host "AKS Cluster           : $ClusterName" -ForegroundColor Green
Write-Host "Resource Group        : $ResourceGroupName" -ForegroundColor Green
Write-Host "Karpenter NodePools   : default, system-surge" -ForegroundColor Green
Write-Host "Prometheus            : $([bool](-not $SkipPrometheus))" -ForegroundColor Green
Write-Host "Manifest Applied      : $([bool](-not $SkipDeploy))" -ForegroundColor Green