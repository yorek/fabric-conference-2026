# Update Data API Builder deployment with new configuration
# 
# This script updates an existing DAB deployment with a new dab-config.json file.
# It builds a new Docker image and updates the Container App.
# The script will display available DAB resource groups and let you select one.
#
# Parameters:
#   -ConfigPath: Path to DAB config file (default: ./dab-config.json)
#
# Examples:
#   .\update.ps1
#   .\update.ps1 -ConfigPath .\configs\prod.json
#
param(
    [string]$ConfigPath = "./dab-config.json"
)

$ScriptVersion = "0.1.0"
$MinimumDabVersion = "1.7.90"
$DockerDabVersion = $MinimumDabVersion

Set-StrictMode -Version Latest

# Verify PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Host "ERROR: PowerShell 5.1 or higher is required" -ForegroundColor Red
    Write-Host "Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    throw "PowerShell version $($PSVersionTable.PSVersion) is not supported"
}

$ErrorActionPreference = 'Stop'
$startTime = Get-Date
$runTimestamp = Get-Date -Format "yyyyMMddHHmmss"

$script:CliLog = Join-Path $PSScriptRoot "$runTimestamp.log"
"[$(Get-Date -Format o)] Update CLI command log - version $ScriptVersion" | Out-File $script:CliLog

# Helper functions
function OK { param($r, $msg) if($r.ExitCode -ne 0) { throw "$msg`n$($r.Text)" } }

function Test-ScriptVersion {
    param([Parameter(Mandatory)][string]$CurrentVersion)
    try {
        $scriptContent = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/JerryNixon/dab-demo-environment-script/refs/heads/main/update.ps1" -TimeoutSec 5 -ErrorAction Stop
        if ($scriptContent -match '\$ScriptVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"') {
            $latestVersion = $matches[1]
            $current = [version]$CurrentVersion
            $latest = [version]$latestVersion
            if ($current -lt $latest) {
                Write-Host ""
                Write-Host "NOTE: A newer version is available!" -ForegroundColor Yellow
                Write-Host "  Current: $CurrentVersion" -ForegroundColor White
                Write-Host "  Latest:  $latestVersion" -ForegroundColor Green
                Write-Host "  Script:  https://github.com/JerryNixon/dab-demo-environment-script/blob/main/update.ps1" -ForegroundColor Cyan
                Write-Host ""
            }
        }
    } catch {}
}

Write-Host "dab-update version $ScriptVersion" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "  Azure CLI: Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: Azure CLI is required" -ForegroundColor Red
    Write-Host "Install from: https://aka.ms/installazurecliwindows" -ForegroundColor White
    throw "Azure CLI is not installed"
}
Write-Host "  Azure CLI: Installed" -ForegroundColor Green

if (-not (Test-Path $ConfigPath)) {
    Write-Host "  dab-config.json: Not found" -ForegroundColor Red
    throw "dab-config.json not found at: $ConfigPath"
}
Write-Host "  dab-config.json: Found" -ForegroundColor Green

$dockerfilePath = "./Dockerfile"
if (-not (Test-Path $dockerfilePath)) {
    Write-Host "  Dockerfile: Not found" -ForegroundColor Red
    throw "Dockerfile not found at: $dockerfilePath"
}
Write-Host "  Dockerfile: Found" -ForegroundColor Green
Write-Host "  Build tag: $runTimestamp" -ForegroundColor Green
Write-Host ""
Test-ScriptVersion -CurrentVersion $ScriptVersion

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

try {
    az login --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure login failed"
    }
    Write-Host "Azure authentication completed successfully" -ForegroundColor Green
} catch {
    Write-Host "Azure authentication failed" -ForegroundColor Red
    Write-Host "Please ensure you have access to an Azure subscription and try again." -ForegroundColor Yellow
    throw "Azure authentication failed: $($_.Exception.Message)"
}

$accountInfoJson = az account show --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to retrieve account information after login"
}

$accountInfo = $accountInfoJson | ConvertFrom-Json
$currentSub = $accountInfo.name
$currentSubId = $accountInfo.id

Write-Host ""
Write-Host "Current subscription:" -ForegroundColor Cyan
Write-Host "  Name: $currentSub" -ForegroundColor White
Write-Host "  ID:   $currentSubId" -ForegroundColor DarkGray

$confirm = Read-Host "`nUse this subscription? (y/n/list) [y]"
if ($confirm) { $confirm = $confirm.Trim().ToLowerInvariant() }

if ($confirm -eq 'list' -or $confirm -eq 'l') {
    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    $subscriptionListJson = az account list --query '[].{name:name, id:id, isDefault:isDefault}' --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list subscriptions"
    }
    $subscriptions = $subscriptionListJson | ConvertFrom-Json
    
    for ($i = 0; $i -lt $subscriptions.Count; $i++) {
        $sub = $subscriptions[$i]
        $marker = if ($sub.isDefault) { " (current)" } else { "" }
        $color = if ($sub.isDefault) { "Green" } else { "White" }
        Write-Host "$($i + 1). $($sub.name)$marker" -ForegroundColor $color
        Write-Host "   ID: $($sub.id)" -ForegroundColor DarkGray
    }
    
    do {
        $choice = Read-Host "`nSelect subscription (1-$($subscriptions.Count)) or press Enter to keep current"
        if ([string]::IsNullOrWhiteSpace($choice)) { 
            break 
        }
    } while ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $subscriptions.Count)
    
    if (-not [string]::IsNullOrWhiteSpace($choice)) {
        $selectedSub = $subscriptions[[int]$choice - 1]
        Write-Host "Switching to subscription: $($selectedSub.name)" -ForegroundColor Yellow
        az account set --subscription $selectedSub.id 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to switch subscription"
        }
        $accountInfoJson = az account show --output json 2>&1
        $accountInfo = $accountInfoJson | ConvertFrom-Json
        $currentSub = $accountInfo.name
        $currentSubId = $accountInfo.id
        Write-Host "Now using: $currentSub" -ForegroundColor Green
    }
} elseif ($confirm -and $confirm -ne 'y') {
    Write-Host "Update cancelled by user" -ForegroundColor Yellow
    exit 0
}
Write-Host ""

function Wait-Seconds {
    param([int]$Seconds, [string]$Reason = "Waiting")
    Start-Sleep -Seconds $Seconds
}

function Invoke-RetryOperation {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 0,
        [int]$TimeoutSeconds = 0,
        [int]$BaseDelaySeconds = 10,
        [switch]$UseExponentialBackoff,
        [switch]$UseJitter,
        [int]$MaxDelaySeconds = 120,
        [string]$RetryMessage = "attempt {attempt}/{max}, wait {delay}s",
        [string]$OperationName = "operation"
    )
    
    if ($MaxRetries -eq 0 -and $TimeoutSeconds -eq 0) {
        throw "Must specify either MaxRetries or TimeoutSeconds"
    }
    if ($MaxRetries -gt 0 -and $TimeoutSeconds -gt 0) {
        throw "Cannot specify both MaxRetries and TimeoutSeconds"
    }
    
    $attempt = 0
    $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { $null }
    
    while ($true) {
        $attempt++
        
        if ($MaxRetries -gt 0 -and $attempt -gt $MaxRetries) {
            throw "Operation '$OperationName' failed after $MaxRetries attempts"
        }
        if ($deadline -and (Get-Date) -ge $deadline) {
            throw "Operation '$OperationName' timed out after $TimeoutSeconds seconds"
        }
        
        try {
            $result = & $ScriptBlock
            if ($result -eq $true) {
                return $true
            }
        } catch {}
        
        if ($MaxRetries -gt 0 -and $attempt -ge $MaxRetries) {
            break
        }
        if ($deadline -and (Get-Date) -ge $deadline) {
            break
        }
        
        if ($UseExponentialBackoff) {
            $delay = [Math]::Min($MaxDelaySeconds, $BaseDelaySeconds * [Math]::Pow(2, ($attempt - 1)))
        } else {
            $delay = $BaseDelaySeconds
        }
        
        if ($UseJitter) {
            $delay += (Get-Random -Minimum 0 -Maximum 4)
        }
        
        $delay = [int][Math]::Round($delay)
        
        $message = $RetryMessage
        $message = $message -replace '\{attempt\}', $attempt
        $message = $message -replace '\{max\}', $(if ($MaxRetries -gt 0) { $MaxRetries } else { "" })
        $message = $message -replace '\{delay\}', $delay
        
        Write-StepStatus -Status Retrying -Detail $message
        Start-Sleep -Seconds $delay
    }
    
    return $false
}

function Write-StepStatus {
    param(
        [string]$Step,
        [Parameter(Mandatory)]
        [ValidateSet('Started','Retrying','Success','Error','Info')]
        [string]$Status,
        [string]$Detail = ''
    )

    $timestamp = (Get-Date).ToString('HH:mm:ss')

    switch ($Status) {
        'Started' {
            if ($Step) {
                Write-Host ""
                Write-Host $Step -ForegroundColor Cyan
            }
            Write-Host "[Started] (est $Detail at $timestamp)" -ForegroundColor Yellow
        }
        'Retrying' {
            Write-Host "[Retrying] ($Detail)" -ForegroundColor DarkYellow
        }
        'Success' {
            Write-Host "[Success] ($Detail)" -ForegroundColor Green
        }
        'Error' {
            Write-Host "[Error] $Detail" -ForegroundColor Red
        }
        'Info' {
            Write-Host "[Info] $Detail" -ForegroundColor Gray
        }
    }
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $cmd = "az " + ($Arguments -join ' ')
    $output = & az @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    $text = $output | Out-String

    $timestamp = Get-Date -Format o
    $tag = if ($exitCode -eq 0) { "[OK]" } else { "[ERR]" }
    Add-Content -Path $script:CliLog -Value "$timestamp $tag $cmd"
    Add-Content -Path $script:CliLog -Value $text

    [pscustomobject]@{
        ExitCode    = $exitCode
        Output      = $output
        Text        = $text
        TrimmedText = $text.Trim()
    }
}

# Find and select resource group
Write-Host "Searching for DAB resource groups..." -ForegroundColor Cyan
$groupsJson = az group list --tag author=dab-demo --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to list resource groups" -ForegroundColor Red
    Write-Host $groupsJson -ForegroundColor DarkRed
    throw "Failed to list resource groups"
}

$resourceGroups = @()
if ($groupsJson.Trim()) {
    $resourceGroups = $groupsJson | ConvertFrom-Json
}

if ($resourceGroups.Count -eq 0) {
    Write-Host ""
    Write-Host "No DAB resource groups found" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No resource groups were found with tag 'author=dab-demo'" -ForegroundColor White
    Write-Host "Please deploy a new environment using create.ps1 first" -ForegroundColor Cyan
    throw "No DAB resource groups found"
}

# Build display table with index
$rgTable = @()
$index = 1
foreach ($rg in $resourceGroups) {
    $owner = "unknown"
    if ($rg.tags) {
        $ownerProp = $rg.tags.PSObject.Properties['owner']
        if ($ownerProp) {
            $owner = $ownerProp.Value
        }
    }
    
    # Get provisioning state
    $statusProp = $rg.properties.PSObject.Properties['provisioningState']
    $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
    
    $rgTable += [PSCustomObject]@{
        '#'    = $index
        Name   = $rg.name
        Owner  = $owner
        Status = $status
    }
    $index++
}

$rgTable | Format-Table -AutoSize

# Interactive selection
Write-Host "Select a resource group to update:" -ForegroundColor Cyan
Write-Host "  - Enter a number (1-$($resourceGroups.Count))" -ForegroundColor White
Write-Host "  - Press Enter to cancel" -ForegroundColor White
Write-Host ""

$selection = Read-Host "Selection"

if ([string]::IsNullOrWhiteSpace($selection)) {
    Write-Host "Update cancelled by user" -ForegroundColor Yellow
    exit 0
}

if ($selection -notmatch '^\d+$') {
    Write-Host "ERROR: Invalid selection '$selection'" -ForegroundColor Red
    Write-Host "Please enter a number between 1 and $($resourceGroups.Count)" -ForegroundColor Yellow
    throw "Invalid selection"
}

$selectedIndex = [int]$selection
if ($selectedIndex -lt 1 -or $selectedIndex -gt $resourceGroups.Count) {
    Write-Host "ERROR: Selection out of range" -ForegroundColor Red
    Write-Host "Please enter a number between 1 and $($resourceGroups.Count)" -ForegroundColor Yellow
    throw "Selection out of range"
}

$selectedRg = $resourceGroups[$selectedIndex - 1]
$ResourceGroup = $selectedRg.name

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  UPDATE IMAGE MODE" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor White
Write-Host "  Config File:    $ConfigPath" -ForegroundColor White
Write-Host ""

$estimatedFinishTime = (Get-Date).AddMinutes(3).ToString("HH:mm:ss")
Write-Host "Starting image update. Estimated time to complete: 3m (finish ~$estimatedFinishTime)" -ForegroundColor Cyan

# Verify resource group exists
Write-StepStatus "Verifying resource group" "Started" "5s"
$rgCheckResult = Invoke-AzCli -Arguments @('group', 'exists', '--name', $ResourceGroup)
if ($rgCheckResult.TrimmedText -ne 'true') {
    Write-Host "ERROR: Resource group '$ResourceGroup' does not exist" -ForegroundColor Red
    exit 1
}
Write-StepStatus "" "Success" "Resource group exists"

# Discover existing resources
Write-StepStatus "Discovering existing resources" "Started" "5s"

# Find ACR
$acrListResult = Invoke-AzCli -Arguments @('acr', 'list', '--resource-group', $ResourceGroup, '--query', "[?tags.author=='dab-demo'].name", '--output', 'tsv')
if ([string]::IsNullOrWhiteSpace($acrListResult.TrimmedText)) {
    Write-Host "ERROR: Azure Container Registry not found in '$ResourceGroup'" -ForegroundColor Red
    exit 1
}
$acrName = $acrListResult.TrimmedText.Trim()
Write-Host "  Found ACR: $acrName" -ForegroundColor Gray

# Get ACR login server
$acrLoginServerResult = Invoke-AzCli -Arguments @('acr', 'show', '--name', $acrName, '--resource-group', $ResourceGroup, '--query', 'loginServer', '--output', 'tsv')
OK $acrLoginServerResult "Failed to get ACR login server"
$acrLoginServer = $acrLoginServerResult.TrimmedText

# Find Container App
$containerListResult = Invoke-AzCli -Arguments @('containerapp', 'list', '--resource-group', $ResourceGroup, '--query', "[?tags.author=='dab-demo'].name", '--output', 'tsv', '--only-show-errors')
if ([string]::IsNullOrWhiteSpace($containerListResult.TrimmedText)) {
    Write-Host "ERROR: Container App not found in '$ResourceGroup'" -ForegroundColor Red
    exit 1
}
$container = $containerListResult.TrimmedText.Trim()
Write-Host "  Found Container App: $container" -ForegroundColor Gray

Write-StepStatus "" "Success" "Resources discovered"

# Compose new timestamp-based image tag
$imageTag = "$acrLoginServer/dab-baked:$runTimestamp"
Write-Host "  New image tag: $imageTag" -ForegroundColor Gray

Write-StepStatus "Building updated DAB image" "Started" "40s"
$buildStartTime = Get-Date

$buildArgs = @(
    'acr', 'build',
    '--resource-group', $ResourceGroup,
    '--registry', $acrName,
    '--image', $imageTag,
    '--file', 'Dockerfile',
    '--build-arg', "DAB_VERSION=$DockerDabVersion",
    '.'
)
$buildResult = Invoke-AzCli -Arguments $buildArgs
OK $buildResult "Failed to build updated DAB image"

$buildElapsed = [math]::Round(((Get-Date) - $buildStartTime).TotalSeconds, 1)
Write-StepStatus "" "Success" "$imageTag ($($buildElapsed)`s)"

# Update container app
Write-StepStatus "Updating container app with new image" "Started" "30s"
$updateAppStartTime = Get-Date

$updateArgs = @(
    'containerapp', 'update',
    '--name', $container,
    '--resource-group', $ResourceGroup,
    '--image', $imageTag
)

$updateResult = Invoke-AzCli -Arguments $updateArgs
OK $updateResult "Failed to update container app"

$updateElapsed = [math]::Round(((Get-Date) - $updateAppStartTime).TotalSeconds, 1)
Write-StepStatus "" "Success" "Container updated ($($updateElapsed)`s)"

# Wait for new revision to become ready
Write-StepStatus "Waiting for new revision to become ready" "Started" "120s"

$revisionResult = @{ LatestRevision = $null }
$revisionReady = Invoke-RetryOperation `
    -ScriptBlock {
        $statusArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $ResourceGroup, '--query', '{running:properties.runningStatus,revision:properties.latestReadyRevisionName}', '--output', 'json')
        $statusResult = Invoke-AzCli -Arguments $statusArgs
        
        if ($statusResult.ExitCode -eq 0) {
            $cleanedJson = $statusResult.TrimmedText -replace '(?m)^WARNING:.*$', ''
            $status = $cleanedJson.Trim() | ConvertFrom-Json
            
            if ($status.running -eq 'Running') {
                $revisionResult.LatestRevision = $status.revision
                Write-StepStatus "" "Success" "New revision ready: $($revisionResult.LatestRevision)"
                return $true
            }
        }
        return $false
    } `
    -TimeoutSeconds 120 `
    -BaseDelaySeconds 10 `
    -RetryMessage "checking revision status" `
    -OperationName "revision ready check"

if (-not $revisionReady) {
    throw "New revision did not become ready within 2 minutes"
}

# Get container URL
$fqdnResult = Invoke-AzCli -Arguments @('containerapp', 'show', '--name', $container, '--resource-group', $ResourceGroup, '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv')
$cleanFqdn = ($fqdnResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
$containerUrl = "https://$($cleanFqdn.Trim())"

# Health check
Write-StepStatus "Verifying DAB API health" "Started" "30s"
$healthCheckStartTime = Get-Date

$healthCheckPassed = Invoke-RetryOperation `
    -ScriptBlock {
        try {
            $healthResponse = Invoke-RestMethod -Uri "$containerUrl/health" -TimeoutSec 10 -ErrorAction Stop
            if ($healthResponse.status -eq "Healthy") {
                $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Success" "API is healthy ($($healthElapsed)`s)"
                return $true
            }
            return $false
        } catch {
            return $false
        }
    } `
    -MaxRetries 5 `
    -BaseDelaySeconds 10 `
    -RetryMessage "health check attempt {attempt}/{max}, waiting {delay}s" `
    -OperationName "health check"

if (-not $healthCheckPassed) {
    Write-Host "  Warning: Health check failed after 5 attempts" -ForegroundColor Yellow
    Write-Host "  The container may still be starting up" -ForegroundColor Yellow
}

# Summary
$totalTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

Write-Host "`n================================================================================" -ForegroundColor Green
Write-Host "  ✓ IMAGE UPDATE SUCCESSFUL (${totalTime}m)" -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "UPDATED RESOURCES" -ForegroundColor Cyan
Write-Host "  Resource Group:    $ResourceGroup" -ForegroundColor White
Write-Host "  Container App:     $container" -ForegroundColor White
Write-Host "  New Image:         $imageTag" -ForegroundColor White
Write-Host "  API Endpoint:      $containerUrl" -ForegroundColor White
Write-Host ""
Write-Host "QUICK LINKS" -ForegroundColor Cyan
Write-Host "  Swagger:           $containerUrl/swagger" -ForegroundColor White
Write-Host "  GraphQL:           $containerUrl/graphql" -ForegroundColor White
Write-Host "  Health:            $containerUrl/health" -ForegroundColor White
Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Update log saved to: $script:CliLog" -ForegroundColor Green
