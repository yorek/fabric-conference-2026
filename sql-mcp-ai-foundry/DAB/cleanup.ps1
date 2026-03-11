# cleanup.ps1
# 
# Deletes resource groups created by dab-deploy-demo script
# Uses the 'author=dab-demo' tag to identify them
#
# Parameters:
#   -WhatIf: Show what would be deleted without actually deleting
#
# Examples:
#   .\cleanup.ps1                    # Interactive selection mode (default)
#   .\cleanup.ps1 -WhatIf            # Dry run
#
param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

Write-Host "DAB Deployment Cleanup Script" -ForegroundColor Cyan
Write-Host ""

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Azure CLI is not installed" -ForegroundColor Red
    Write-Host "Please install from: https://aka.ms/installazurecliwindows" -ForegroundColor White
    exit 1
}

# Login check
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
    exit 1
}

$accountInfoJson = az account show --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to retrieve account information after login" -ForegroundColor Red
    exit 1
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
        Write-Host "ERROR: Failed to list subscriptions" -ForegroundColor Red
        exit 1
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
            Write-Host "ERROR: Failed to switch subscription" -ForegroundColor Red
            exit 1
        }
        $accountInfoJson = az account show --output json 2>&1
        $accountInfo = $accountInfoJson | ConvertFrom-Json
        $currentSub = $accountInfo.name
        $currentSubId = $accountInfo.id
        Write-Host "Now using: $currentSub" -ForegroundColor Green
    }
} elseif ($confirm -and $confirm -ne 'y') {
    Write-Host "Cleanup cancelled by user" -ForegroundColor Yellow
    exit 0
}
Write-Host ""

# Find resource groups with the author tag
Write-Host "Searching for dab-demo resource groups..." -ForegroundColor Cyan
$groupsJson = az group list --tag author=dab-demo --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to list resource groups" -ForegroundColor Red
    Write-Host $groupsJson -ForegroundColor DarkRed
    exit 1
}

$resourceGroups = @()
if ($groupsJson.Trim()) {
    $resourceGroups = $groupsJson | ConvertFrom-Json
}

if ($resourceGroups.Count -eq 0) {
    Write-Host "No resource groups found with tag 'author=dab-demo'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Nothing to clean up!" -ForegroundColor Green
    exit 0
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

# WhatIf mode
if ($WhatIf) {
    Write-Host "WhatIf mode: The following resource groups would be deleted:" -ForegroundColor Yellow
    $resourceGroups | ForEach-Object { 
        $owner = "unknown"
        if ($_.tags) {
            $ownerProp = $_.tags.PSObject.Properties['owner']
            if ($ownerProp) {
                $owner = $ownerProp.Value
            }
        }
        $statusProp = $_.properties.PSObject.Properties['provisioningState']
        $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
        Write-Host "  - $($_.name) (owner: $owner, status: $status)" -ForegroundColor White 
    }
    Write-Host ""
    Write-Host "No changes made (WhatIf mode)" -ForegroundColor Cyan
    exit 0
}

# Selection logic
$selectedGroups = @()

# Interactive selection
Write-Host "Select resource groups to delete:" -ForegroundColor Cyan
Write-Host "  - Enter numbers separated by commas (e.g., 1,3,5)" -ForegroundColor White
Write-Host "  - Enter 'all' to delete all" -ForegroundColor White
Write-Host "  - Press Enter to cancel" -ForegroundColor White
Write-Host ""

$selection = Read-Host "Selection"

if ([string]::IsNullOrWhiteSpace($selection)) {
    Write-Host "Cleanup cancelled by user" -ForegroundColor Yellow
    exit 0
}

if ($selection.Trim().ToLower() -eq 'all') {
    $selectedGroups = $resourceGroups
} else {
    # Parse comma-separated numbers
    $numbers = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    
    foreach ($num in $numbers) {
        if ($num -ge 1 -and $num -le $resourceGroups.Count) {
            $selectedGroups += $resourceGroups[$num - 1]
        } else {
            Write-Host "WARNING: Invalid selection '$num' (valid range: 1-$($resourceGroups.Count))" -ForegroundColor Yellow
        }
    }
}

if ($selectedGroups.Count -eq 0) {
    Write-Host "No resource groups selected" -ForegroundColor Yellow
    exit 0
}

# Confirmation
Write-Host ""
Write-Host "Selected resource groups for deletion:" -ForegroundColor Red
foreach ($rg in $selectedGroups) {
    $owner = "unknown"
    if ($rg.tags) {
        $ownerProp = $rg.tags.PSObject.Properties['owner']
        if ($ownerProp) {
            $owner = $ownerProp.Value
        }
    }
    $statusProp = $rg.properties.PSObject.Properties['provisioningState']
    $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
    Write-Host "  - $($rg.name) (owner: $owner, status: $status, location: $($rg.location))" -ForegroundColor White
}
Write-Host ""
Write-Host "WARNING: This action cannot be undone!" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "Type 'DELETE' to confirm"

if ($confirm -ne 'DELETE') {
    Write-Host "Cleanup cancelled by user" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Deleting resource groups..." -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$failCount = 0
$skippedCount = 0
$failedGroups = @()

foreach ($rg in $selectedGroups) {
    $rgName = $rg.name
    $owner = "unknown"
    if ($rg.tags) {
        $ownerProp = $rg.tags.PSObject.Properties['owner']
        if ($ownerProp) {
            $owner = $ownerProp.Value
        }
    }
    
    # Check if already deleting
    $statusProp = $rg.properties.PSObject.Properties['provisioningState']
    $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
    
    if ($status -eq 'Deleting') {
        Write-Host "  Skipping: $rgName (owner: $owner) - already deleting" -ForegroundColor DarkGray
        $skippedCount++
        continue
    }
    
    Write-Host "  Deleting: $rgName (owner: $owner)..." -NoNewline -ForegroundColor Yellow
    
    $deleteResult = az group delete --name $rgName --yes --no-wait 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host " queued" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        $failCount++
        $failedGroups += $rgName
        Write-Host "    Error: $deleteResult" -ForegroundColor DarkRed
    }
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  CLEANUP SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource groups selected:      $($selectedGroups.Count)" -ForegroundColor White
Write-Host "Successfully queued:           $successCount" -ForegroundColor Green
Write-Host "Skipped (already deleting):    $skippedCount" -ForegroundColor DarkGray
Write-Host "Failed:                        $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host ""

# Refresh and display current status of all DAB resource groups
Write-Host "Current status of all DAB resource groups:" -ForegroundColor Cyan
Write-Host ""

$currentGroupsJson = az group list --tag author=dab-demo --output json 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentGroupsJson)) {
    $currentGroups = $currentGroupsJson | ConvertFrom-Json
    
    if ($currentGroups.Count -gt 0) {
        # Display table header
        $header = "{0,-4} {1,-45} {2,-20} {3,-15}" -f "#", "Name", "Owner", "Status"
        Write-Host $header -ForegroundColor White
        Write-Host ("-" * 85) -ForegroundColor DarkGray
        
        # Display each resource group
        for ($i = 0; $i -lt $currentGroups.Count; $i++) {
            $grp = $currentGroups[$i]
            $num = $i + 1
            $grpName = $grp.name
            
            $grpOwner = "unknown"
            if ($grp.tags) {
                $grpOwnerProp = $grp.tags.PSObject.Properties['owner']
                if ($grpOwnerProp) { $grpOwner = $grpOwnerProp.Value }
            }
            
            $grpStatusProp = $grp.properties.PSObject.Properties['provisioningState']
            $grpStatus = if ($grpStatusProp) { $grpStatusProp.Value } else { "unknown" }
            
            $statusColor = switch ($grpStatus) {
                'Succeeded' { 'Green' }
                'Deleting' { 'Yellow' }
                'Failed' { 'Red' }
                default { 'White' }
            }
            
            $row = "{0,-4} {1,-45} {2,-20} {3,-15}" -f $num, $grpName, $grpOwner, $grpStatus
            Write-Host $row -ForegroundColor $statusColor
        }
        Write-Host ""
    } else {
        Write-Host "  No DAB resource groups found" -ForegroundColor Green
        Write-Host ""
    }
} else {
    Write-Host "  Unable to retrieve current status" -ForegroundColor DarkGray
    Write-Host ""
}

if ($successCount -gt 0) {
    Write-Host "NOTE: Deletions are running in the background." -ForegroundColor Yellow
    Write-Host "It may take several minutes for resources to be fully deleted." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Check status: az group list --tag author=dab-demo --output table" -ForegroundColor Cyan
}

if ($failCount -gt 0) {
    Write-Host "Failed resource groups:" -ForegroundColor Red
    $failedGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
    Write-Host ""
    Write-Host "Manual cleanup may be required." -ForegroundColor Yellow
}

Write-Host "================================================================================" -ForegroundColor Cyan

exit $(if ($failCount -eq 0) { 0 } else { 1 })
