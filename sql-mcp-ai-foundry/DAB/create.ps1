# Deploy Data API Builder with Azure SQL Database and Container Apps
# 
# Parameters:
#   -Region: Azure region for deployment (default: westus2)
#   -DatabasePath: Path to SQL database file - local or relative from script root (default: ./database.sql)
#   -ConfigPath: Path to DAB config file - used to build custom image (default: ./dab-config.json)
#   -ResourceGroupName: Custom name for resource group (default: dab-demo-TIMESTAMP)
#   -SqlServerName: Custom name for SQL Server (default: dab-demo-sql-TIMESTAMP)
#   -SqlDatabaseName: Custom name for SQL Database (default: sql-database)
#   -ContainerAppName: Custom name for Container App (default: dab-demo-container-TIMESTAMP)
#   -AcrName: Custom name for Azure Container Registry (default: dabdemoTIMESTAMP)
#   -LogAnalyticsName: Custom name for Log Analytics workspace (default: log-workspace)
#   -ContainerEnvironmentName: Custom name for Container App Environment (default: aca-environment)
#   -SqlCommanderName: Custom name for SQL Commander container (default: sql-commander)
#   -NoSqlCommander: Skip SQL Commander deployment (default: deploy SQL Commander)
#   -NoCleanup: Preserve resource group on failure for debugging (default: auto-cleanup)
#
# Notes:
#   The script builds a custom Docker image with dab-config.json baked in using Azure Container Registry.
#   The Dockerfile must be present in the current directory.
#   To update an existing deployment, use update.ps1 instead.
#   Resource names are automatically validated and sanitized according to Azure naming rules.
#   SQL Commander is deployed by default with Azure AD authentication to Azure SQL Database.
#
# Examples:
#   .\create.ps1
#   .\create.ps1 -Region eastus
#   .\create.ps1 -Region westeurope -DatabasePath ".\databases\prod.sql" -ConfigPath ".\configs\prod.json"
#   .\create.ps1 -ResourceGroupName "my-dab-rg" -SqlServerName "my-sql-server"
#   .\create.ps1 -ContainerAppName "my-api" -AcrName "myregistry123"
#   .\create.ps1 -NoSqlCommander
#   .\create.ps1 -SqlCommanderName "my-sql-cmd"
#   .\create.ps1 -NoCleanup
#
param(
    [string]$Region = "westus2",
    
    [string]$DatabasePath = "../Wikipedia/database.sql",
    
    [string]$ConfigPath = "./dab-config.json",
    
    [string]$ResourceGroupName = "",
    
    [string]$SqlServerName = "",
    
    [string]$SqlDatabaseName = "",
    
    [string]$ContainerAppName = "",
    
    [string]$AcrName = "",
    
    [string]$LogAnalyticsName = "",
    
    [string]$ContainerEnvironmentName = "",
    
    [string]$SqlCommanderName = "",
    
    [switch]$NoSqlCommander,
    
    [switch]$NoCleanup,
    
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$UnknownArgs
)

if ($UnknownArgs) {
    Write-Host "`n================================================================================" -ForegroundColor Red
    Write-Host "ERROR: Unknown or misspelled parameter(s) detected" -ForegroundColor Red -BackgroundColor Black
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host "`nUnrecognized argument(s):" -ForegroundColor Yellow
    foreach ($arg in $UnknownArgs) {
        Write-Host "  $arg" -ForegroundColor Red
    }
    exit 1
}

$ScriptVersion = "0.7.0"
$MinimumDabVersion = "1.7.90"
$DockerDabVersion = "latest" #$MinimumDabVersion

Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Host "ERROR: PowerShell 5.1 or higher is required" -ForegroundColor Red
    Write-Host "Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Please upgrade to PowerShell 5.1 or later:" -ForegroundColor White
    Write-Host "  - Windows PowerShell 5.1: https://aka.ms/wmf5download" -ForegroundColor Cyan
    Write-Host "  - PowerShell 7+: https://aka.ms/powershell-release" -ForegroundColor Cyan
    throw "PowerShell version $($PSVersionTable.PSVersion) is not supported"
}

$Config = @{
    SqlRetryAttempts = 12
    SqlRetryBaseDelaySec = 20
    PropagationWaitSec = 30
    LogRetentionDays = 90
    ContainerCpu = 0.5
    ContainerMemory = "1.0Gi"
}

$ErrorActionPreference = 'Stop'
$startTime = Get-Date
$runTimestamp = Get-Date -Format "yyyyMMddHHmmss"

$script:CliLog = Join-Path $PSScriptRoot "$runTimestamp.log"

"[$(Get-Date -Format o)] CLI command log - version $ScriptVersion" | Out-File $script:CliLog

function OK { param($r, $msg) if($r.ExitCode -ne 0) { throw "$msg`n$($r.Text)" } }

function Test-ScriptVersion {
    param(
        [Parameter(Mandatory)]
        [string]$CurrentVersion
    )
    
    try {
        $scriptContent = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/JerryNixon/dab-demo-environment-script/refs/heads/main/create.ps1" -TimeoutSec 5 -ErrorAction Stop
        
        if ($scriptContent -match '\$ScriptVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"') {
            $latestVersion = $matches[1]
            
            $current = [version]$CurrentVersion
            $latest = [version]$latestVersion
            
            if ($current -lt $latest) {
                Write-Host ""
                Write-Host "NOTE: A newer version is available!" -ForegroundColor Yellow
                Write-Host "  Current: $CurrentVersion" -ForegroundColor White
                Write-Host "  Latest:  $latestVersion" -ForegroundColor White
                Write-Host "  Repository:  https://github.com/JerryNixon/dab-demo-environment-script" -ForegroundColor White
                Write-Host ""
            } elseif ($current -gt $latest) {
                Write-Host "INFO: Your script version ($CurrentVersion) is newer than the GitHub version ($latestVersion)" -ForegroundColor Yellow
                Write-Host "  Proceeding with execution. Ensure this is the intended build." -ForegroundColor White
                Write-Host ""
            }
        }
    } catch [System.Management.Automation.RuntimeException] {
        throw
    } catch {
    }
}

Write-Host "dab-deploy-demo version $ScriptVersion" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking prerequisites..." -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "  Azure CLI: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Azure CLI is required but not installed." -ForegroundColor Yellow
    Write-Host "Please install from: https://aka.ms/installazurecliwindows" -ForegroundColor White
    Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
    throw "Azure CLI is not installed"
} else {
    try {
        $azVersionInfo = az version --output json 2>$null | ConvertFrom-Json
        $azVersion = $azVersionInfo.'azure-cli'
        Write-Host "  Azure CLI: " -NoNewline -ForegroundColor Yellow
        Write-Host "Installed ($azVersion)" -ForegroundColor Green
    } catch {
        Write-Host "  Azure CLI: " -NoNewline -ForegroundColor Yellow
        Write-Host "Installed (version unknown)" -ForegroundColor Green
    }
}

if (-not (Get-Command dab -ErrorAction SilentlyContinue)) {
    Write-Host "  DAB CLI: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Data API Builder CLI is required but not installed." -ForegroundColor Yellow
    Write-Host "Please install using: dotnet tool install -g Microsoft.DataApiBuilder" -ForegroundColor White
    Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
    throw "DAB CLI is not installed"
} else {
    Write-Host "  DAB CLI: " -NoNewline -ForegroundColor Yellow
    try {
        $dabVersionOutput = & dab --version 2>&1 | Out-String
        if ($dabVersionOutput -match '(\d+)\.(\d+)\.(\d+)(?:-rc)?') {
            $majorVersion = [int]$Matches[1]
            $minorVersion = [int]$Matches[2]
            $patchVersion = [int]$Matches[3]
            $dabVersion = "$majorVersion.$minorVersion.$patchVersion"
            
            $minRequiredBase = $MinimumDabVersion -replace '-rc$', ''
            $minRequired = [version]$minRequiredBase
            $isOldVersion = ([version]$dabVersion) -lt $minRequired
            
            if ($isOldVersion) {
                Write-Host "Installed ($dabVersion) - TOO OLD" -ForegroundColor Red
                Write-Host ""
                Write-Host "ERROR: DAB CLI version $dabVersion is not supported" -ForegroundColor Red
                Write-Host "Minimum required version: $MinimumDabVersion" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Please update DAB CLI:" -ForegroundColor Yellow
                Write-Host "  dotnet tool update -g Microsoft.DataApiBuilder" -ForegroundColor White
                Write-Host ""
                exit 1
            }
            
            Write-Host "Installed ($dabVersion)" -ForegroundColor Green
        } else {
            Write-Host "Installed (version unknown - cannot verify compatibility)" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "WARNING: Unable to determine DAB CLI version" -ForegroundColor Yellow
            Write-Host "Minimum required version: $MinimumDabVersion" -ForegroundColor Yellow
            Write-Host "If deployment fails, update DAB: dotnet tool update -g Microsoft.DataApiBuilder" -ForegroundColor White
        }
    } catch {
        Write-Host "  DAB CLI: " -NoNewline -ForegroundColor Yellow
        Write-Host "Installed (version check failed)" -ForegroundColor Yellow
    }
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "  sqlcmd: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: sqlcmd is required but not installed." -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install SQL Server command-line tools:" -ForegroundColor Yellow
    Write-Host "  Windows: https://aka.ms/ssmsfullsetup" -ForegroundColor White
    Write-Host "  macOS:   brew install sqlcmd" -ForegroundColor White
    Write-Host "  Linux:   https://learn.microsoft.com/sql/linux/sql-server-linux-setup-tools" -ForegroundColor White
    Write-Host ""
    Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
    throw "sqlcmd is not installed"
} else {
    Write-Host "  sqlcmd: " -NoNewline -ForegroundColor Yellow
    try {
        $sqlcmdVersionOutput = & sqlcmd --version 2>&1 | Out-String
        if ($sqlcmdVersionOutput -match 'v?(\d+)\.(\d+)\.(\d+)') {
            $majorVersion = [int]$Matches[1]
            $minorVersion = [int]$Matches[2]
            $patchVersion = [int]$Matches[3]
            $sqlcmdVersion = "$majorVersion.$minorVersion.$patchVersion"
            Write-Host "Installed ($sqlcmdVersion)" -ForegroundColor Green
        } else {
            $sqlcmdVersionOutput = & sqlcmd -? 2>&1 | Out-String
            if ($sqlcmdVersionOutput -match 'Version\s+(\d+)\.(\d+)\.(\d+)\.(\d+)') {
                $majorVersion = [int]$Matches[1]
                $minorVersion = [int]$Matches[2]
                $sqlcmdVersion = "$majorVersion.$minorVersion.$($Matches[3]).$($Matches[4])"
                
                if ($majorVersion -lt 13 -or ($majorVersion -eq 13 -and $minorVersion -lt 1)) {
                    Write-Host "Installed ($sqlcmdVersion) - TOO OLD" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "ERROR: sqlcmd version $sqlcmdVersion does not support Azure AD authentication" -ForegroundColor Red
                    Write-Host "Minimum required version: 13.1.0.0" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "Please update sqlcmd:" -ForegroundColor Yellow
                    Write-Host "  Windows: https://aka.ms/ssmsfullsetup" -ForegroundColor White
                    Write-Host "  macOS:   brew upgrade sqlcmd" -ForegroundColor White
                    Write-Host "  Linux:   https://learn.microsoft.com/sql/linux/sql-server-linux-setup-tools" -ForegroundColor White
                    throw "sqlcmd version $sqlcmdVersion is too old (requires 13.1+)"
                }
                
                Write-Host "Installed ($sqlcmdVersion)" -ForegroundColor Green
            } else {
                Write-Host "Installed (version unknown)" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "Installed (version unknown)" -ForegroundColor Green
    }
}

if (-not (Test-Path $DatabasePath)) {
    Write-Host "  database.sql: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: database.sql not found at: $DatabasePath" -ForegroundColor Red
    Write-Host "Please create a database.sql file with your database schema and try again." -ForegroundColor Yellow
    Write-Host "Or specify a custom path: -DatabasePath <path>" -ForegroundColor Cyan
    throw "database.sql not found at: $DatabasePath"
}

$databaseContent = Get-Content $DatabasePath -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($databaseContent)) {
    Write-Host "  database.sql: " -NoNewline -ForegroundColor Yellow
    Write-Host "Empty file" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: database.sql is empty at: $DatabasePath" -ForegroundColor Red
    Write-Host "The database script file is empty. Please add SQL commands to create your database." -ForegroundColor Yellow
    throw "database.sql is empty"
}
Write-Host "  database.sql: " -NoNewline -ForegroundColor Yellow
Write-Host "Found" -ForegroundColor Green

if (-not (Test-Path $ConfigPath)) {
    Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: dab-config.json not found at: $ConfigPath" -ForegroundColor Red
    Write-Host "Please create a dab-config.json file with your DAB configuration." -ForegroundColor Yellow
    Write-Host "Or specify a custom path: -ConfigPath <path>" -ForegroundColor Cyan
    throw "dab-config.json not found at: $ConfigPath"
}

try {
    $dabConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    
    $expectedEnvVar = "MSSQL_CONNECTION_STRING"
    $expectedRef = "@env('$expectedEnvVar')"
    $connectionStringRef = $dabConfig.'data-source'.'connection-string'
    
    if ($connectionStringRef -ne $expectedRef) {
        Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
        Write-Host "Invalid connection string" -ForegroundColor Red
        Write-Host ""
        Write-Host "ERROR: dab-config.json has incorrect connection string reference." -ForegroundColor Red
        Write-Host "  Expected: `"connection-string`": `"$expectedRef`"" -ForegroundColor Yellow
        Write-Host "  Found:    `"connection-string`": `"$connectionStringRef`"" -ForegroundColor Red
        Write-Host ""
        Write-Host "The script sets the environment variable '$expectedEnvVar' in the container." -ForegroundColor White
        Write-Host "Please update your dab-config.json to reference this variable:" -ForegroundColor White
        Write-Host ""
        Write-Host '  "data-source": {' -ForegroundColor Cyan
        Write-Host '    "database-type": "mssql",' -ForegroundColor Cyan
        Write-Host "    `"connection-string`": `"$expectedRef`"" -ForegroundColor Green
        Write-Host '  }' -ForegroundColor Cyan
        throw "dab-config.json has incorrect connection string reference. Expected: $expectedRef, Found: $connectionStringRef"
    }
    Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
    Write-Host "Found" -ForegroundColor Green
} catch {
    Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
    Write-Host "Parse error" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: Failed to parse dab-config.json at: $ConfigPath" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Please ensure the file contains valid JSON syntax." -ForegroundColor White
    throw "Failed to parse or validate dab-config.json: $($_.Exception.Message)"
}

$dockerfilePath = "./Dockerfile"
if (-not (Test-Path $dockerfilePath)) {
    Write-Host "  Dockerfile: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: Dockerfile not found at: $dockerfilePath" -ForegroundColor Red
    Write-Host "The script builds a custom image with dab-config.json baked in." -ForegroundColor Yellow
    Write-Host "Please ensure Dockerfile exists in the current directory." -ForegroundColor White
    throw "Dockerfile not found at: $dockerfilePath"
}
Write-Host "  Dockerfile: " -NoNewline -ForegroundColor Yellow
Write-Host "Found" -ForegroundColor Green

Write-Host "  Build tag: " -NoNewline -ForegroundColor Yellow
Write-Host $runTimestamp -ForegroundColor Green

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

$subscriptionId = az account show --query id -o tsv

function Wait-Seconds {
    param([int]$Seconds, [string]$Reason = "Waiting")
    Start-Sleep -Seconds $Seconds
}

function Invoke-RetryOperation {
    <#
    .SYNOPSIS
    Unified retry helper with configurable backoff strategies.
    
    .DESCRIPTION
    Executes a scriptblock with automatic retry logic. Supports both count-based 
    and time-based termination, exponential backoff with optional jitter, and 
    consistent status reporting.
    
    .PARAMETER ScriptBlock
    The code to execute. Should return $true on success, $false on retriable failure.
    
    .PARAMETER MaxRetries
    Maximum number of retry attempts (count-based mode). Mutually exclusive with TimeoutSeconds.
    
    .PARAMETER TimeoutSeconds
    Maximum time to retry in seconds (time-based mode). Mutually exclusive with MaxRetries.
    
    .PARAMETER BaseDelaySeconds
    Starting delay between retries. Used as fixed delay or base for exponential backoff.
    
    .PARAMETER UseExponentialBackoff
    If true, delays grow exponentially (base 2). If false, uses fixed delay.
    
    .PARAMETER UseJitter
    If true, adds random jitter (0-4 seconds) to each delay.
    
    .PARAMETER MaxDelaySeconds
    Maximum delay cap for exponential backoff.
    
    .PARAMETER RetryMessage
    Template message for retry attempts. Can include {attempt}, {max}, {delay} placeholders.
    
    .PARAMETER OperationName
    Name of the operation for error messages.
    
    .EXAMPLE
    Invoke-RetryOperation -ScriptBlock { Test-Something } -MaxRetries 10 -BaseDelaySeconds 5 -UseExponentialBackoff
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
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
        } catch {
        }
        
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
        $message = $message -replace '\{max\}', $(if ($MaxRetries -gt 0) { $MaxRetries } else { "∞" })
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

function Test-AzureTokenExpiry {
    param(
        [int]$ExpiryBufferMinutes = 5
    )
    
    try {
        $tokenInfoResult = Invoke-AzCli -Arguments @('account', 'get-access-token', '--query', 'expiresOn', '--output', 'tsv')
        
        if ($tokenInfoResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($tokenInfoResult.TrimmedText)) {
            $expiresOn = [datetime]::Parse($tokenInfoResult.TrimmedText)
            $bufferTime = (Get-Date).AddMinutes($ExpiryBufferMinutes)
            
            if ($expiresOn -lt $bufferTime) {
                Write-Host "`nAccess token expired or expiring soon (expires: $expiresOn)" -ForegroundColor Yellow
                Write-Host "Refreshing Azure authentication..." -ForegroundColor Cyan
                
                az login --output none 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Token refresh failed"
                }
                
                Write-Host "Token refreshed successfully" -ForegroundColor Green
                return $true
            }
        }
    } catch {
        Write-Host "Warning: Unable to check token expiry, continuing..." -ForegroundColor Yellow
    }
    
    return $false
}

function Get-MI-DisplayName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PrincipalId,
        
        [int]$MaxRetries = 20,
        [int]$BaseDelaySeconds = 6
    )
    
    $result = @{
        DisplayName = $null
        LastError = $null
    }
    
    $success = Invoke-RetryOperation `
        -ScriptBlock {
            try {
                $dn = az ad sp show --id $PrincipalId --query displayName -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($dn)) {
                    $result.DisplayName = $dn.Trim()
                    return $true
                }
                $result.LastError = "displayName not found yet"
            } catch {
                $result.LastError = $_.Exception.Message
            }
            return $false
        } `
        -MaxRetries $MaxRetries `
        -BaseDelaySeconds $BaseDelaySeconds `
        -UseExponentialBackoff `
        -UseJitter `
        -MaxDelaySeconds 120 `
        -RetryMessage "service principal propagation; attempt {attempt}/{max}, wait {delay}s" `
        -OperationName "Get-MI-DisplayName"
    
    if ($success) {
        return $result.DisplayName
    }
    
    throw "Unable to resolve managed identity display name for SP '$PrincipalId' after $MaxRetries attempts. Last error: $($result.LastError)"
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

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

function Write-DeploymentSummary {
    param(
        $ResourceGroup, $Region, $SqlServer, $SqlDatabase, $Container, $ContainerUrl,
        $LogAnalytics, $Environment, $CurrentUser, $DatabaseType, $TotalTime, $ClientIp, $SqlServerFqdn, $FirewallRuleName,
        $SqlCommander, $SqlCommanderUrl
    )
    
    $subscriptionIdResult = Invoke-AzCli -Arguments @('account', 'show', '--query', 'id', '--output', 'tsv')
    OK $subscriptionIdResult "Failed to retrieve subscription id for summary"
    $subscriptionId = $subscriptionIdResult.TrimmedText
    
    Write-Host "`n================================================================================" -ForegroundColor Green
    Write-Host "  ✓ DEPLOYMENT SUCCESSFUL ($TotalTime)" -ForegroundColor Green
    Write-Host "================================================================================" -ForegroundColor Green
    
    Write-Host "`nDEPLOYED RESOURCES" -ForegroundColor Cyan
    Write-Host "  Resource Group:    $ResourceGroup"
    Write-Host "  Region:            $Region"
    Write-Host "  SQL Server:        $SqlServer"
    Write-Host "  Database:          $SqlDatabase ($DatabaseType)"
    Write-Host "  Container App:     $Container"
    
    if ($SqlCommander -and $SqlCommanderUrl -ne "Not deployed") {
        Write-Host "  SQL Commander:     $SqlCommander"
    }
    
    Write-Host "`nQUICK LINKS" -ForegroundColor Cyan
    Write-Host "  Portal:            https://ms.portal.azure.com/#@microsoft.onmicrosoft.com/resource/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/overview"
    Write-Host "  Swagger:           $ContainerUrl/swagger"
    Write-Host "  GraphQL:           $ContainerUrl/graphql"
    Write-Host "  Health:            $ContainerUrl/health"
    
    if ($SqlCommander -and $SqlCommanderUrl -ne "Not deployed") {
        Write-Host "  SQL Commander:     $SqlCommanderUrl"
    }
    
    Write-Host "`n================================================================================" -ForegroundColor Green
}

function Assert-AzureResourceName {
    <#
    .SYNOPSIS
    Validates and sanitizes Azure resource names according to Azure naming rules.
    
    .DESCRIPTION
    Applies resource-type-specific naming rules including:
    - Casing requirements (lowercase for SQL Server, Container Apps, ACR)
    - Character restrictions (alphanumeric only for ACR, no special chars for others)
    - Length constraints (different limits per resource type)
    - Pattern validation (no double hyphens, no starting/ending with hyphen)
    
    .PARAMETER Name
    The proposed resource name to validate and sanitize.
    
    .PARAMETER ResourceType
    The type of Azure resource. Determines which naming rules to apply.
    
    .OUTPUTS
    Returns the sanitized resource name that conforms to Azure naming rules.
    Throws an error if the name cannot be made valid.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [Parameter(Mandatory)]
        [ValidateSet(
            'ResourceGroup',
            'SqlServer',
            'Database',
            'ContainerApp',
            'ContainerEnvironment',
            'LogAnalytics',
            'ACR'
        )]
        [string]$ResourceType
    )
    
    $rules = @{
        'ResourceGroup' = @{
            MinLength = 1
            MaxLength = 90
            AllowedChars = '^[a-zA-Z0-9._()-]+$'
            RequireLowercase = $false
            StripNonAlphanumeric = $false
            NoDoubleHyphen = $false
            NoTrailingHyphen = $false
            NoLeadingHyphen = $false
            Description = 'Resource groups allow alphanumeric, hyphens, underscores, periods, and parentheses'
        }
        'SqlServer' = @{
            MinLength = 1
            MaxLength = 63
            AllowedChars = '^[a-z0-9-]+$'
            RequireLowercase = $true
            StripNonAlphanumeric = $false
            NoDoubleHyphen = $true
            NoTrailingHyphen = $true
            NoLeadingHyphen = $true
            Description = 'SQL Server names must be lowercase alphanumeric and hyphens only, cannot start or end with hyphen'
        }
        'Database' = @{
            MinLength = 1
            MaxLength = 128
            AllowedChars = '^[^<>*%&:\\\/?]+$'  # Most chars allowed, exclude specific special chars
            RequireLowercase = $false
            StripNonAlphanumeric = $false
            NoDoubleHyphen = $false
            NoTrailingHyphen = $false
            NoLeadingHyphen = $false
            Description = 'Database names allow most characters except <>*%&:\/?'
        }
        'ContainerApp' = @{
            MinLength = 2
            MaxLength = 32
            AllowedChars = '^[a-z0-9-]+$'
            RequireLowercase = $true
            StripNonAlphanumeric = $false
            NoDoubleHyphen = $true
            NoTrailingHyphen = $true
            NoLeadingHyphen = $true
            Description = 'Container App names must be lowercase alphanumeric and hyphens, no consecutive hyphens, cannot start or end with hyphen'
        }
        'ContainerEnvironment' = @{
            MinLength = 1
            MaxLength = 60
            AllowedChars = '^[a-zA-Z0-9-]+$'
            RequireLowercase = $false
            StripNonAlphanumeric = $false
            NoDoubleHyphen = $true
            NoTrailingHyphen = $true
            NoLeadingHyphen = $true
            Description = 'Container Environment names allow alphanumeric and hyphens'
        }
        'LogAnalytics' = @{
            MinLength = 4
            MaxLength = 63
            AllowedChars = '^[a-zA-Z0-9-]+$'
            RequireLowercase = $false
            StripNonAlphanumeric = $false
            NoDoubleHyphen = $true
            NoTrailingHyphen = $true
            NoLeadingHyphen = $true
            Description = 'Log Analytics workspace names allow alphanumeric and hyphens'
        }
        'ACR' = @{
            MinLength = 5
            MaxLength = 50
            AllowedChars = '^[a-z0-9]+$'
            RequireLowercase = $true
            StripNonAlphanumeric = $true
            NoDoubleHyphen = $false
            NoTrailingHyphen = $false
            NoLeadingHyphen = $false
            Description = 'Azure Container Registry names must be lowercase alphanumeric only (no hyphens or special characters)'
        }
    }
    
    $rule = $rules[$ResourceType]
    $sanitizedName = $Name
    
    if ($rule.RequireLowercase) {
        $sanitizedName = $sanitizedName.ToLower()
    }
    
    if ($rule.StripNonAlphanumeric) {
        $sanitizedName = $sanitizedName -replace '[^a-zA-Z0-9]', ''
        if ($rule.RequireLowercase) {
            $sanitizedName = $sanitizedName.ToLower()
        }
    }
    
    if ($rule.NoDoubleHyphen) {
        while ($sanitizedName -match '--') {
            $sanitizedName = $sanitizedName -replace '--', '-'
        }
    }
    
    if ($rule.NoLeadingHyphen) {
        $sanitizedName = $sanitizedName.TrimStart('-')
    }
    
    if ($rule.NoTrailingHyphen) {
        $sanitizedName = $sanitizedName.TrimEnd('-')
    }
    
    if ($sanitizedName.Length -lt $rule.MinLength) {
        throw "Resource name '$Name' for $ResourceType is too short after sanitization (min: $($rule.MinLength) chars). Result: '$sanitizedName'. $($rule.Description)"
    }
    
    if ($sanitizedName.Length -gt $rule.MaxLength) {
        $sanitizedName = $sanitizedName.Substring(0, $rule.MaxLength)
        
        if ($rule.NoTrailingHyphen) {
            $sanitizedName = $sanitizedName.TrimEnd('-')
        }
    }
    
    if ($sanitizedName -notmatch $rule.AllowedChars) {
        throw "Resource name '$sanitizedName' for $ResourceType contains invalid characters. $($rule.Description)"
    }
    
    return $sanitizedName
}

$accountInfoResult = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
OK $accountInfoResult "Failed to retrieve account information after login"

$accountInfo = $accountInfoResult.TrimmedText | ConvertFrom-Json
$currentSub = $accountInfo.name
$currentSubId = $accountInfo.id
$currentAccountUser = if ($accountInfo.user) { $accountInfo.user.name } else { $null }
if (-not $currentAccountUser -and $accountInfo.user) { $currentAccountUser = $accountInfo.user.userName }
if (-not $currentAccountUser -and $accountInfo.user) { $currentAccountUser = $accountInfo.user.userPrincipalName }
if (-not $currentAccountUser) { $currentAccountUser = "unknown-principal" }

$ownerTagValue = "unknown-owner"
if ($currentAccountUser -and $currentAccountUser -match '^([^@]+)@') {
    $ownerLocalPart = $Matches[1]
    if ($ownerLocalPart) {
        $ownerTagValue = ($ownerLocalPart -replace '[^a-z0-9._-]', '-').ToLowerInvariant()
    }
}
$commonTagValues = @('author=dab-demo', "version=$ScriptVersion", "owner=$ownerTagValue")

Write-Host "`nCurrent subscription:" -ForegroundColor Cyan
Write-Host "  Name: $currentSub" -ForegroundColor White
Write-Host "  ID:   $currentSubId" -ForegroundColor DarkGray

$confirm = Read-Host "`nDeploy to this subscription? (y/n/list) [y]"
if ($confirm) { $confirm = $confirm.Trim().ToLowerInvariant() }

if ($confirm -eq 'list' -or $confirm -eq 'l') {
    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    $subscriptionListResult = Invoke-AzCli -Arguments @('account', 'list', '--query', '[].{name:name, id:id, isDefault:isDefault}', '--output', 'json')
    OK $subscriptionListResult "Failed to list subscriptions"
    $subscriptions = $subscriptionListResult.TrimmedText | ConvertFrom-Json
    
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
        $setSubscriptionResult = Invoke-AzCli -Arguments @('account', 'set', '--subscription', $selectedSub.id)
        OK $setSubscriptionResult "Failed to switch subscription"
        $accountInfoResult = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
        OK $accountInfoResult "Failed to refresh subscription context"
        $accountInfo = $accountInfoResult.TrimmedText | ConvertFrom-Json
        $currentSub = $accountInfo.name
        $currentSubId = $accountInfo.id
        Write-Host "Now using: $currentSub" -ForegroundColor Green
    }
} elseif ($confirm -and $confirm -ne 'y') {
    Write-Host "Deployment cancelled by user" -ForegroundColor Yellow
    exit 0
}

$estimatedFinishTime = (Get-Date).AddMinutes(8).ToString("HH:mm:ss")
Write-Host "Starting deployment. Estimated time to complete: 8m (finish ~$estimatedFinishTime)" -ForegroundColor Cyan

$rg = $null

try {
    [void](Test-AzureTokenExpiry -ExpiryBufferMinutes 5)
    
    $defaultPrefix = "dab-fabcon26-"
    
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $ResourceGroupName = "${defaultPrefix}$runTimestamp"
    }
    
    if ([string]::IsNullOrWhiteSpace($SqlServerName)) {
        $SqlServerName = "${defaultPrefix}sql-$runTimestamp"
    }
    
    if ([string]::IsNullOrWhiteSpace($SqlDatabaseName)) {
        $SqlDatabaseName = "sql-database"
    }
    
    if ([string]::IsNullOrWhiteSpace($ContainerAppName)) {
        $ContainerAppName = "${defaultPrefix}container-$runTimestamp"
    }
    
    if ([string]::IsNullOrWhiteSpace($AcrName)) {
        $acrPrefix = ($defaultPrefix -replace '[^a-zA-Z0-9]', '').ToLower()
        $AcrName = "${acrPrefix}$runTimestamp".ToLower()
    }
    
    if ([string]::IsNullOrWhiteSpace($LogAnalyticsName)) {
        $LogAnalyticsName = "log-workspace"
    }
    
    if ([string]::IsNullOrWhiteSpace($ContainerEnvironmentName)) {
        $ContainerEnvironmentName = "aca-environment"
    }
    
    if ([string]::IsNullOrWhiteSpace($SqlCommanderName)) {
        $SqlCommanderName = "sql-commander-$runTimestamp"
    }
    
    $rg = Assert-AzureResourceName -Name $ResourceGroupName -ResourceType 'ResourceGroup'
    $sqlServer = Assert-AzureResourceName -Name $SqlServerName -ResourceType 'SqlServer'
    $sqlDb = Assert-AzureResourceName -Name $SqlDatabaseName -ResourceType 'Database'
    $container = Assert-AzureResourceName -Name $ContainerAppName -ResourceType 'ContainerApp'
    $acrName = Assert-AzureResourceName -Name $AcrName -ResourceType 'ACR'
    $logAnalytics = Assert-AzureResourceName -Name $LogAnalyticsName -ResourceType 'LogAnalytics'
    $acaEnv = Assert-AzureResourceName -Name $ContainerEnvironmentName -ResourceType 'ContainerEnvironment'
    $sqlCommander = Assert-AzureResourceName -Name $SqlCommanderName -ResourceType 'ContainerApp'

    Write-StepStatus "Creating resource group" "Started" "5s"
    $rgStartTime = Get-Date
    $rgArgs = @('group', 'create', '--name', $rg, '--location', $Region, '--tags') + $commonTagValues
    $rgCreateResult = Invoke-AzCli -Arguments $rgArgs
    if ($rgCreateResult.ExitCode -ne 0) {
        $rgError = $rgCreateResult.TrimmedText
        if ($rgError -match "AuthorizationFailed") {
            $guidanceLines = @(
                "AuthorizationFailed: The signed-in account '$currentAccountUser' cannot create resource groups in subscription '$currentSub'.",
                "",
                "What to try next:",
                "  1. Confirm you targeted the right subscription: az account list --output table",
                "  2. If you recently changed tenants or accounts, refresh credentials: az login [--tenant TENANT_ID]",
                "  3. Ask a subscription Owner to grant you the Contributor role.",
                "",
                "Raw Azure CLI error:",
                "  $rgError"
            )
            throw ($guidanceLines -join "`n")
        }
        throw "Failed to create resource group. Azure CLI returned: $rgError"
    }
    $rgElapsed = [math]::Round(((Get-Date) - $rgStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$rg ($($rgElapsed)`s)"

    Write-StepStatus "Getting current Azure AD user" "Started" "5s"
    $userInfoResult = Invoke-AzCli -Arguments @('ad', 'signed-in-user', 'show', '--query', '{id:id,upn:userPrincipalName}', '--output', 'json')
    OK $userInfoResult "Failed to identify Azure AD user"
    $userInfo = $userInfoResult.TrimmedText | ConvertFrom-Json
    $currentUser = $userInfo.id
    $currentUserName = $userInfo.upn
    Write-StepStatus "" "Success" "retrieved $currentUserName"

    Write-StepStatus "Creating SQL Server" "Started" "80s"
    
    $sqlStartTime = Get-Date
    $sqlServerArgs = @(
        'sql', 'server', 'create',
        '--name', $sqlServer,
        '--resource-group', $rg,
        '--location', $Region,
        '--enable-ad-only-auth',
        '--external-admin-principal-type', 'User',
        '--external-admin-name', $currentUserName,
        '--external-admin-sid', $currentUser
    )
    $sqlServerResult = Invoke-AzCli -Arguments $sqlServerArgs
    OK $sqlServerResult "Failed to create SQL server"
    
    $sqlTagArgs = @('sql', 'server', 'update', '--name', $sqlServer, '--resource-group', $rg, '--set')
    foreach ($tag in $commonTagValues) {
        if ($tag -match '^([^=]+)=(.+)$') {
            $sqlTagArgs += "tags.$($Matches[1])=$($Matches[2])"
        }
    }
    $sqlTagResult = Invoke-AzCli -Arguments $sqlTagArgs
    OK $sqlTagResult "Failed to apply tags to SQL server"
    
    $sqlElapsed = [math]::Round(((Get-Date) - $sqlStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$sqlServer ($($sqlElapsed)`s)"
    
    $sqlFqdnArgs = @('sql', 'server', 'show', '--name', $sqlServer, '--resource-group', $rg, '--query', 'fullyQualifiedDomainName', '--output', 'tsv')
    $sqlFqdnResult = Invoke-AzCli -Arguments $sqlFqdnArgs
    OK $sqlFqdnResult "Failed to retrieve SQL Server FQDN"
    $sqlServerFqdn = $sqlFqdnResult.TrimmedText

    $startIp = "0.0.0.0"
    $endIp = "255.255.255.255"
    $clientIp = "$startIp-$endIp"
    
    $firewallRuleName = "AllowAll"
    $firewallArgs = @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $rg,
        '--server', $sqlServer,
        '--name', $firewallRuleName,
        '--start-ip-address', $startIp,
        '--end-ip-address', $endIp
    )
    
    $firewallResult = Invoke-AzCli -Arguments $firewallArgs
    OK $firewallResult "Failed to create firewall rule"

    Write-StepStatus "Checking free database capacity" "Started" "5s"
    $freeCheckStartTime = Get-Date
    $canUseFree = $false
    
    try {
        $freeCapArgs = @('sql', 'server', 'list-usages', '--resource-group', $rg, '--name', $sqlServer, '--query', "[?name.value=='FreeDatabaseCount']", '--output', 'json')
        $freeCapResult = Invoke-AzCli -Arguments $freeCapArgs
        
        if ($freeCapResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($freeCapResult.TrimmedText)) {
            $freeCapJson = $freeCapResult.TrimmedText | ConvertFrom-Json
            if ($freeCapJson -and $freeCapJson.Count -gt 0) {
                $currentVal = [int]$freeCapJson[0].currentValue
                $limitVal = [int]$freeCapJson[0].limit
                if ($currentVal -lt $limitVal) {
                    $canUseFree = $true
                }
            }
        }
    } catch {
        $canUseFree = $false
    }
    
    $freeCheckElapsed = [math]::Round(((Get-Date) - $freeCheckStartTime).TotalSeconds, 1)
    
    if ($canUseFree) {
    Write-StepStatus "" "Success" "Free tier available ($($freeCheckElapsed)`s)"
    } else {
    Write-StepStatus "" "Success" "Free tier unavailable, using DTU ($($freeCheckElapsed)`s)"
    }

    if ($canUseFree) {
        Write-StepStatus "Creating SQL database" "Started" "20s"
    } else {
        Write-StepStatus "Creating SQL database" "Started" "60s"
    }
    
    $dbStartTime = Get-Date
    $dbCreated = $false
    
    if ($canUseFree) {
        $freeDbArgs = @('sql', 'db', 'create', '--name', $sqlDb, '--server', $sqlServer, '--resource-group', $rg, '--tags') + $commonTagValues + @('--use-free-limit', 'true', '--edition', 'Free', '--max-size', '1GB', '--query', 'name', '--output', 'tsv')
        $freeDbAttempt = Invoke-AzCli -Arguments $freeDbArgs
        $freeDbOutput = $freeDbAttempt.TrimmedText
        
        if ($freeDbAttempt.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($freeDbOutput)) {
            $dbType = "Free-tier"
            $dbCreated = $true
        } else {
            Write-StepStatus "" "Info" "Free-tier failed, trying Basic DTU"
        }
    }
    
    if (-not $dbCreated) {
        $fallbackDbArgs = @(
            'sql', 'db', 'create',
            '--name', $sqlDb,
            '--server', $sqlServer,
            '--resource-group', $rg,
            '--edition', 'Basic',
            '--service-objective', 'Basic',
            '--tags') + $commonTagValues
        $fallbackDbResult = Invoke-AzCli -Arguments $fallbackDbArgs
        OK $fallbackDbResult "Failed to create fallback SQL database"
        $dbType = "Basic DTU"
    }
    
    $dbElapsed = [math]::Round(((Get-Date) - $dbStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$sqlDb ($dbType, $($dbElapsed)`s)"

    if (Test-Path $DatabasePath) {
        Write-StepStatus "Deploying database schema" "Started" "30s"
        $schemaStartTime = Get-Date
        $schemaResult = @{
            LastError = $null
            LastOutput = $null
            AttemptCount = 0
        }
        
        $schemaSuccess = Invoke-RetryOperation `
            -ScriptBlock {
                $schemaResult.AttemptCount++
                
                $sqlcmdOutput = sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $DatabasePath 2>&1 | Out-String
                $sqlExit = $LASTEXITCODE
                $schemaResult.LastOutput = $sqlcmdOutput
                
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                
                if ($sqlExit -eq 0) {
                    Add-Content -Path $script:CliLog -Value "[$timestamp] [OK] sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $DatabasePath`n$sqlcmdOutput`n"
                    $schemaElapsed = [math]::Round(((Get-Date) - $schemaStartTime).TotalSeconds, 1)
                    Write-StepStatus "" "Success" "schema deployed to $sqlDb ($($schemaElapsed)`s)"
                    return $true
                } else {
                    Add-Content -Path $script:CliLog -Value "[$timestamp] [ERR] sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $DatabasePath (attempt $($schemaResult.AttemptCount)/3)`n$sqlcmdOutput`n"
                    
                    $isAdAuthError = $sqlcmdOutput -match "Login failed.*AzureAD" -or 
                                     $sqlcmdOutput -match "Azure.*authentication.*not.*ready" -or
                                     $sqlcmdOutput -match "configured for Azure AD only authentication"
                    
                    $isPermissionError = $sqlcmdOutput -match "permission.*denied" -or
                                        $sqlcmdOutput -match "The user does not have permission"
                    
                    if ($isPermissionError) {
                        Write-StepStatus "" "Error" "Permission denied. User $currentUserName may lack CREATE TABLE or ALTER permissions"
                        Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
                        Write-Host "  - Verify $currentUserName is set as SQL Server admin" -ForegroundColor White
                        Write-Host "  - Check firewall allows your IP" -ForegroundColor White
                        Write-Host "  - Ensure database.sql has valid permissions" -ForegroundColor White
                        throw "Database schema deployment failed: Permission denied (exit code $sqlExit)"
                    }
                    
                    if (-not $isAdAuthError) {
                        Write-StepStatus "" "Error" "sqlcmd exit code $sqlExit. See $script:CliLog"
                        throw "Database schema deployment failed with exit code $sqlExit"
                    }
                    
                    $schemaResult.LastError = "Azure AD auth not ready (exit code $sqlExit)"
                    return $false
                }
            } `
            -MaxRetries 3 `
            -BaseDelaySeconds 15 `
            -RetryMessage "Azure AD auth not ready, attempt {attempt}/{max}, waiting {delay}s" `
            -OperationName "database schema deployment"
        
        if (-not $schemaSuccess) {
            Write-StepStatus "" "Error" "Failed after 3 attempts"
            Write-Host "`nError details from sqlcmd:" -ForegroundColor Yellow
            Write-Host $schemaResult.LastOutput -ForegroundColor DarkYellow
            Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
            Write-Host "  - Check logs: $script:CliLog" -ForegroundColor White
            Write-Host "  - Verify Azure AD authentication: az sql server ad-only-auth get -g $rg -n $sqlServer" -ForegroundColor White
            Write-Host "  - Test connectivity: sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q 'SELECT @@VERSION'" -ForegroundColor White
            throw "Database schema deployment failed after 3 attempts: $($schemaResult.LastError)"
        }
    } else {
        throw "database.sql file validation failed at path: $DatabasePath"
    }

    Write-StepStatus "Validating DAB configuration" "Started" "5s"
    $validationStartTime = Get-Date
    
    $validationConnectionString = "Server=tcp:${sqlServerFqdn},1433;Database=${sqlDb};Authentication=Active Directory Default;"
    
    $env:MSSQL_CONNECTION_STRING = $validationConnectionString
    
    $dabInstalled = Get-Command dab -ErrorAction SilentlyContinue
    if (-not $dabInstalled) {
        Write-StepStatus "" "Info" "DAB CLI not installed, skipping validation"
    } else {
        try {
            $dabOutput = & dab validate --config $ConfigPath 2>&1
            $dabExit = $LASTEXITCODE
            
            if ($dabExit -ne 0) {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Add-Content -Path $script:CliLog -Value "[$timestamp] [ERR] dab validate --config $ConfigPath`n$dabOutput`n"
                
                Write-StepStatus "" "Error" "Configuration validation failed. See $script:CliLog"
                throw "DAB configuration validation failed. Fix errors in $ConfigPath and database schema before deploying."
            } else {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Add-Content -Path $script:CliLog -Value "[$timestamp] [OK] dab validate --config $ConfigPath`nConfiguration valid`n"
                
                $validationElapsed = [math]::Round(((Get-Date) - $validationStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Success" "$ConfigPath validated ($($validationElapsed)`s)"
            }
        } finally {
            Remove-Item Env:MSSQL_CONNECTION_STRING -ErrorAction SilentlyContinue
        }
    }

    Write-StepStatus "Creating Log Analytics workspace" "Started" "40s"
    $lawStartTime = Get-Date
    $lawCreateArgs = @('monitor', 'log-analytics', 'workspace', 'create', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--location', $Region, '--tags') + $commonTagValues
    $lawCreateResult = Invoke-AzCli -Arguments $lawCreateArgs
    OK $lawCreateResult "Failed to create Log Analytics workspace"
    
    $lawCustomerIdArgs = @('monitor', 'log-analytics', 'workspace', 'show', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--query', 'customerId', '--output', 'tsv')
    $lawCustomerIdResult = Invoke-AzCli -Arguments $lawCustomerIdArgs
    OK $lawCustomerIdResult "Failed to get Log Analytics customerId"
    $lawCustomerId = $lawCustomerIdResult.TrimmedText.Trim()
    
    if ($lawCustomerId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Log Analytics customerId is not a valid 36-character GUID. Got: '$lawCustomerId'"
    }
    
    $lawKeyArgs = @('monitor', 'log-analytics', 'workspace', 'get-shared-keys', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--query', 'primarySharedKey', '--output', 'tsv')
    $lawKeyResult = Invoke-AzCli -Arguments $lawKeyArgs
    OK $lawKeyResult "Failed to get Log Analytics workspace key"
    $lawPrimaryKey = $lawKeyResult.TrimmedText.Trim()
    
    if ([string]::IsNullOrWhiteSpace($lawPrimaryKey)) {
        throw "Log Analytics primarySharedKey came back empty"
    }
    
    $lawElapsed = [math]::Round(((Get-Date) - $lawStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$logAnalytics ($($lawElapsed)`s)"

    Write-StepStatus "Updating Log Analytics retention" "Started" "35s"
    $lawUpdateArgs = @('monitor', 'log-analytics', 'workspace', 'update', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--tags') + $commonTagValues + @('--retention-time', $Config.LogRetentionDays.ToString())
    $lawUpdateResult = Invoke-AzCli -Arguments $lawUpdateArgs
    OK $lawUpdateResult "Failed to update Log Analytics retention"
    Write-StepStatus "" "Success" "retention set to $($Config.LogRetentionDays) days"

    Write-StepStatus "Creating Container Apps environment" "Started" "120s"
    
    $acaStartTime = Get-Date
    $acaArgs = @('containerapp', 'env', 'create', '--name', $acaEnv, '--resource-group', $rg, '--location', $Region, '--logs-workspace-id', $lawCustomerId, '--logs-workspace-key', $lawPrimaryKey, '--tags') + $commonTagValues
    $acaCreateResult = Invoke-AzCli -Arguments $acaArgs
    OK $acaCreateResult "Failed to create Container Apps environment"
    $acaElapsed = [math]::Round(((Get-Date) - $acaStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$acaEnv ($($acaElapsed)`s)"

    Write-StepStatus "Creating Azure Container Registry" "Started" "25s"
    
    $acrStartTime = Get-Date
    $acrArgs = @('acr', 'create', '--resource-group', $rg, '--name', $acrName, '--sku', 'Basic', '--admin-enabled', 'false', '--tags') + $commonTagValues
    $acrResult = Invoke-AzCli -Arguments $acrArgs
    OK $acrResult "Failed to create Azure Container Registry"
    $acrElapsed = [math]::Round(((Get-Date) - $acrStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$acrName ($($acrElapsed)`s)"
    
    # ACR login server is always {name}.azurecr.io
    $acrLoginServer = "$acrName.azurecr.io"
    $imageTag = "$acrLoginServer/dab-baked:$runTimestamp"
    
    Write-StepStatus "Building custom DAB image with baked config" "Started" "40s"
    
    $buildStartTime = Get-Date
    $buildArgs = @(
        'acr', 'build',
        '--resource-group', $rg,
        '--registry', $acrName,
        '--image', $imageTag,
        '--file', 'Dockerfile',
        '--build-arg', "DAB_VERSION=$DockerDabVersion",
        '.'
    )
    
    $buildSuccess = Invoke-RetryOperation `
        -ScriptBlock {
            $buildResult = Invoke-AzCli -Arguments $buildArgs
            if ($buildResult.ExitCode -eq 0) {
                return $true
            }
            if ($buildResult.Text -match 'no such host|dial tcp.*lookup|network.*unavailable') {
                return $false
            }
            throw "Build failed with non-retryable error: $($buildResult.Text)"
        } `
        -MaxRetries 3 `
        -BaseDelaySeconds 30 `
        -UseExponentialBackoff `
        -MaxDelaySeconds 120 `
        -RetryMessage "ACR build (DNS propagation); attempt {attempt}/{max}, wait {delay}s" `
        -OperationName "ACR-Build"
    
    if (-not $buildSuccess) {
        throw "Failed to build custom DAB image after retries"
    }
    
    $buildElapsed = [math]::Round(((Get-Date) - $buildStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$imageTag ($($buildElapsed)`s)"

    Write-StepStatus "Creating Container App with ACR image" "Started" "60s"
    
    $connectionString = "Server=tcp:${sqlServerFqdn},1433;Database=${sqlDb};Authentication=Active Directory Managed Identity;"
    
    $createAppStartTime = Get-Date
    $createAppArgs = @(
        'containerapp', 'create',
        '--name', $container,
        '--resource-group', $rg,
        '--environment', $acaEnv,
        '--system-assigned',
        '--ingress', 'external',
        '--target-port', '5000',
        '--image', $imageTag,
        '--registry-server', $acrLoginServer,
        '--registry-identity', 'system',
        '--cpu', $Config.ContainerCpu,
        '--memory', $Config.ContainerMemory,
        '--env-vars',
        "MSSQL_CONNECTION_STRING=$connectionString",
        "Runtime__ConfigFile=/App/dab-config.json",
        '--tags'
    ) + $commonTagValues
    
    $createAppResult = Invoke-AzCli -Arguments $createAppArgs
    OK $createAppResult "Failed to create Container App"
    $createAppElapsed = [math]::Round(((Get-Date) - $createAppStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$container created with $imageTag ($($createAppElapsed)`s)"
    
    Write-StepStatus "Assigning AcrPull role to managed identity" "Started" "15s"
    
    $principalIdArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', 'identity.principalId', '--output', 'tsv')
    $principalIdResult = Invoke-AzCli -Arguments $principalIdArgs
    OK $principalIdResult "Failed to retrieve MI principal ID"
    $principalId = ($principalIdResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
    $principalId = $principalId -replace '\s+', ''
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "Managed identity principal ID is empty or null"
    }
    if ($principalId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Managed identity principal ID is not a valid GUID. Got: '$principalId'"
    }
    
    Add-Content -Path $script:CliLog -Value "[$(Get-Date -Format o)] [INFO] Principal ID: $principalId"

    $acrIdArgs = @('acr', 'show', '--name', $acrName, '--resource-group', $rg, '--query', 'id', '--output', 'tsv')
    $acrIdResult = Invoke-AzCli -Arguments $acrIdArgs
    OK $acrIdResult "Failed to retrieve ACR resource ID"
    $acrId = ($acrIdResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
    $acrId = $acrId.Trim()
    
    $roleAssignArgs = @('role', 'assignment', 'create', '--assignee', $principalId, '--role', 'AcrPull', '--scope', $acrId)
    $roleAssignResult = Invoke-AzCli -Arguments $roleAssignArgs
    OK $roleAssignResult "Failed to assign AcrPull role"
    Write-StepStatus "" "Success" "AcrPull role assigned to $container MI"


    Write-StepStatus "Retrieving managed identity display name" "Started" "5s"
    
    try {
        $spDisplayName = Get-MI-DisplayName -PrincipalId $principalId
        Write-StepStatus "" "Success" "Retrieved: $spDisplayName"
    } catch {
        throw "Failed to retrieve managed identity display name: $($_.Exception.Message)"
    }

    $sqlUserName = $spDisplayName
    
    $sqlStartTime = Get-Date
    $sqlResult = @{
        LastExit = 0
        LastOutput = $null
    }
    
    Write-StepStatus "Granting managed identity access to SQL Database" "Started" "10s"
    
    $success = Invoke-RetryOperation `
        -ScriptBlock {
            try {
                $escapedUserName = $sqlUserName.Replace("'", "''")
                $escapedBracketName = $sqlUserName.Replace("]", "]]")
                $sqlQuery = @"
BEGIN TRY
    IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$escapedUserName')
        CREATE USER [$escapedBracketName] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [$escapedBracketName];
    ALTER ROLE db_datawriter ADD MEMBER [$escapedBracketName];
    GRANT EXECUTE TO [$escapedBracketName];
    SELECT 'PERMISSION_GRANT_SUCCESS' AS Result;
END TRY
BEGIN CATCH
    DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
    PRINT 'ERROR: Failed to grant permissions: ' + @ErrorMessage;
    THROW;
END CATCH
"@
                $sqlcmdOutput = sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q $sqlQuery 2>&1 | Out-String
                $sqlExit = $LASTEXITCODE
                $sqlResult.LastExit = $sqlExit
                $sqlResult.LastOutput = $sqlcmdOutput
                
                if ($sqlExit -eq 0 -and $sqlcmdOutput -match 'PERMISSION_GRANT_SUCCESS') {
                    return $true
                }
                
                if ($sqlcmdOutput -match 'duplicate display name' -or 
                    $sqlcmdOutput -match 'Msg 33131') {
                    Write-StepStatus "" "Error" "Non-retryable error: Duplicate display name in Azure AD"
                    throw "DAB container managed identity has duplicate display name - cannot proceed"
                }
                
                if ($sqlcmdOutput) {
                    Write-StepStatus "" "Info" "SQL output: $sqlcmdOutput"
                }
                if ($sqlExit -ne 0) {
                    Write-StepStatus "" "Info" "SQL exit code: $sqlExit"
                }
                return $false
            } catch {
                if ($_.Exception.Message -match 'duplicate display name' -or 
                    $_.Exception.Message -match 'cannot proceed') {
                    throw
                }
                Write-StepStatus "" "Info" "SQL error: $($_.Exception.Message)"
                return $false
            }
        } `
        -MaxRetries 12 `
        -BaseDelaySeconds 20 `
        -UseExponentialBackoff `
        -UseJitter `
        -MaxDelaySeconds 240 `
        -RetryMessage "attempt {attempt}/{max}, waiting {delay}s" `
        -OperationName "SQL MI access grant"
    
    if (-not $success) {
        $sqlElapsed = [math]::Round(((Get-Date) - $sqlStartTime).TotalSeconds, 0)
        Write-StepStatus "" "Error" "Failed after 12 attempts ($($sqlElapsed)s, exit code: $($sqlResult.LastExit))"
        throw "Failed to grant SQL access after 12 attempts. MI may not be propagated to SQL Server's Entra cache (exit code: $($sqlResult.LastExit))" 
    }
    
    $sqlElapsed = [math]::Round(((Get-Date) - $sqlStartTime).TotalSeconds, 0)
    Write-StepStatus "" "Success" "$sqlUserName granted access to $sqlDb ($($sqlElapsed)`s)"
    
    Write-StepStatus "Verifying SQL permissions" "Started" "5s"
    $verifyStartTime = Get-Date
    
    try {
        $escapedUserName = $sqlUserName.Replace("'", "''")
        
        $verifyPermsQuery = @"
SELECT 
    dp.name AS PrincipalName,
    dp.type_desc AS PrincipalType,
    CASE 
        WHEN EXISTS (SELECT 1 FROM sys.database_role_members drm 
                     JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id 
                     WHERE drm.member_principal_id = dp.principal_id AND r.name = 'db_datareader') 
        THEN 'YES' ELSE 'NO' END AS HasDataReader,
    CASE 
        WHEN EXISTS (SELECT 1 FROM sys.database_role_members drm 
                     JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id 
                     WHERE drm.member_principal_id = dp.principal_id AND r.name = 'db_datawriter') 
        THEN 'YES' ELSE 'NO' END AS HasDataWriter,
    CASE 
        WHEN EXISTS (SELECT 1 FROM sys.database_permissions p 
                     WHERE p.grantee_principal_id = dp.principal_id 
                     AND p.permission_name = 'EXECUTE' 
                     AND p.state_desc = 'GRANT') 
        THEN 'YES' ELSE 'NO' END AS HasExecute
FROM sys.database_principals dp
WHERE dp.name = '$escapedUserName';
"@
        
        $verifyOutput = sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q $verifyPermsQuery -h -1 -W 2>&1 | Out-String
        $verifyExit = $LASTEXITCODE
        
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $script:CliLog -Value "[$timestamp] [INFO] Permission verification for $sqlUserName`n$verifyOutput`n"
        
        if ($verifyExit -eq 0) {
            $hasExecute = $verifyOutput -match 'YES\s+YES\s+YES'
            
            if ($hasExecute) {
                $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Success" "db_datareader + db_datawriter + EXECUTE verified for $sqlUserName ($($verifyElapsed)`s)"
            } else {
                $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Info" "Permissions granted but verification pattern incomplete ($($verifyElapsed)`s)"
            }
        } else {
            $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
            Write-StepStatus "" "Info" "Verification query failed, but grants succeeded ($($verifyElapsed)`s)"
        }
    } catch {
        Write-StepStatus "" "Info" "Permission verification skipped: $($_.Exception.Message)"
    }
    
    Write-StepStatus "Verifying container is running" "Started" "300s"
    $verifyStartTime = Get-Date
    
    $containerRunning = Invoke-RetryOperation `
        -ScriptBlock {
            $statusArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', '{provisioning:properties.provisioningState,running:properties.runningStatus}', '--output', 'json')
            $statusResult = Invoke-AzCli -Arguments $statusArgs
            
            if ($statusResult.ExitCode -eq 0) {
                $cleanedJson = ($statusResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join "`n"
                $cleanedJson = $cleanedJson.Trim()
                
                if (-not [string]::IsNullOrWhiteSpace($cleanedJson)) {
                    $status = $cleanedJson | ConvertFrom-Json
                
                    if ($status.provisioning -eq 'Succeeded' -and $status.running -eq 'Running') {
                        $replicaArgs = @('containerapp', 'replica', 'list', '--name', $container, '--resource-group', $rg, '--query', '[0].properties.containers[0].restartCount', '--output', 'tsv')
                        $replicaResult = Invoke-AzCli -Arguments $replicaArgs
                    
                        if ($replicaResult.ExitCode -eq 0) {
                            $restartCountRaw = $replicaResult.TrimmedText
                            $restartCount = ($restartCountRaw -split "`n" | Where-Object { $_ -match '^\d+$' }) | Select-Object -First 1
                            
                            if (-not $restartCount) { $restartCount = 0 }
                            [int]$restartCount = $restartCount
                        
                            if ($restartCount -lt 3) {
                                $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
                                Write-StepStatus "" "Success" "$container running with restart count $restartCount ($($verifyElapsed)`s)"
                                return $true
                            } else {
                                Write-StepStatus "" "Info" "Container in crash loop (restart count: $restartCount)"
                            }
                        }
                    }
                }
            }
            return $false
        } `
        -TimeoutSeconds 300 `
        -BaseDelaySeconds 10 `
        -RetryMessage "checking container status (attempt {attempt})" `
        -OperationName "container running verification"
    
    if (-not $containerRunning) {
        $logsArgs = @('containerapp', 'logs', 'show', '--name', $container, '--resource-group', $rg, '--tail', '50')
        $logsResult = Invoke-AzCli -Arguments $logsArgs
        $logOutput = if ($logsResult.TrimmedText) { $logsResult.TrimmedText } else { "No logs available" }
        throw "Container did not reach Running state within 5 minutes. Recent logs:`n$logOutput"
    }

    $containerShowArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv')
    $containerShowResult = Invoke-AzCli -Arguments $containerShowArgs
    if ($containerShowResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($containerShowResult.TrimmedText)) {
        $cleanFqdn = ($containerShowResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
        $cleanFqdn = $cleanFqdn.Trim()
        $containerUrl = "https://$cleanFqdn"
        
        Write-StepStatus "Checking DAB API health endpoint" "Started" "120s"
        $healthCheckStartTime = Get-Date
        
        Write-Host "  Waiting 15s for container to stabilize..." -ForegroundColor Gray
        Start-Sleep -Seconds 15
        
        $healthUrl = "$containerUrl/health"
        $healthResult = @{ 
            Passed = $false
            FinalAttempt = $false
        }
        
        $healthResult.Passed = Invoke-RetryOperation `
            -ScriptBlock {
                try {
                    $healthResponse = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10 -ErrorAction Stop
                    
                    if ($healthResponse.status -eq "Healthy") {
                        $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
                        Write-StepStatus "" "Success" "DAB API health: Healthy ($($healthElapsed)`s)"
                        return $true
                    } elseif ($healthResponse.status -eq "Unhealthy") {
                        $dbCheck = $healthResponse.checks | Where-Object { $_.tags -contains "data-source" } | Select-Object -First 1
                        if ($dbCheck -and $dbCheck.status -eq "Healthy") {
                            $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
                            Write-StepStatus "" "Success" "DAB API responding, database connection healthy ($($healthElapsed)`s)"
                            return $true
                        }
                    }
                    return $false
                } catch {
                    return $false
                }
            } `
            -MaxRetries 10 `
            -BaseDelaySeconds 15 `
            -RetryMessage "health check attempt {attempt}/{max}, waiting {delay}s" `
            -OperationName "DAB API health check"
        
        if (-not $healthResult.Passed) {
            $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
            Write-StepStatus "" "Info" "Unable to verify DAB API health after 10 attempts ($($healthElapsed)`s)"
            Write-Host "  Health endpoint: $healthUrl" -ForegroundColor DarkGray
            Write-Host "  Container may still be starting - check logs if needed" -ForegroundColor DarkGray
            Write-StepStatus "" "Info" "Health not yet Healthy; continuing"
        }
    } else {
        $containerUrl = "Not available (ingress not configured)"
        $ingressMessage = if ($containerShowResult.TrimmedText) { $containerShowResult.TrimmedText } else { "Container ingress not ready" }
        Write-StepStatus "" "Info" $ingressMessage
    }


    $sqlCommanderUrl = "Not deployed"
    if (-not $NoSqlCommander) {
        Write-StepStatus "Deploying SQL Commander" "Started" "30s"
        $sqlCmdStartTime = Get-Date
        
        $sqlConnectionString = "Server=$sqlServerFqdn;Database=$sqlDb;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;"
        
        $sqlCmdArgs = @(
            'containerapp', 'create',
            '--name', $sqlCommander,
            '--resource-group', $rg,
            '--environment', $acaEnv,
            '--system-assigned',
            '--image', 'jerrynixon/sql-commander:latest',
            '--ingress', 'external',
            '--target-port', '8080',
            '--cpu', '0.5',
            '--memory', '1.0Gi',
            '--env-vars', "ConnectionStrings__db=$sqlConnectionString"
        )
        
        $sqlCmdArgs += '--tags'
        $sqlCmdArgs += $commonTagValues
        
        $sqlCmdCreateResult = Invoke-AzCli -Arguments $sqlCmdArgs
        
        if ($sqlCmdCreateResult.ExitCode -eq 0) {
            $sqlCmdElapsed = [math]::Round(((Get-Date) - $sqlCmdStartTime).TotalSeconds, 1)
            Write-StepStatus "" "Success" "$sqlCommander created ($($sqlCmdElapsed)`s)"
            
            Write-StepStatus "Retrieving SQL Commander managed identity" "Started" "5s"
            $sqlCmdPrincipalIdArgs = @('containerapp', 'show', '--name', $sqlCommander, '--resource-group', $rg, '--query', 'identity.principalId', '--output', 'tsv')
            $sqlCmdPrincipalIdResult = Invoke-AzCli -Arguments $sqlCmdPrincipalIdArgs
            
            if ($sqlCmdPrincipalIdResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($sqlCmdPrincipalIdResult.TrimmedText)) {
                $sqlCmdPrincipalId = ($sqlCmdPrincipalIdResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
                $sqlCmdPrincipalId = $sqlCmdPrincipalId -replace '\s+', ''
                Write-StepStatus "" "Success" "Principal ID: $sqlCmdPrincipalId"
                
                Write-StepStatus "Retrieving SQL Commander MI display name" "Started" "5s"
                try {
                    $sqlCmdSpDisplayName = Get-MI-DisplayName -PrincipalId $sqlCmdPrincipalId
                    Write-StepStatus "" "Success" "Retrieved: $sqlCmdSpDisplayName"
                } catch {
                    throw "Failed to retrieve SQL Commander managed identity display name: $($_.Exception.Message)"
                }
                
                Write-StepStatus "Granting SQL Commander MI access to SQL Database" "Started" "10s"
                $sqlCmdSqlStartTime = Get-Date
                
                $sqlCmdSqlSuccess = Invoke-RetryOperation `
                    -ScriptBlock {
                        try {
                            $escapedUserName = $sqlCmdSpDisplayName.Replace("'", "''")
                            $escapedBracketName = $sqlCmdSpDisplayName.Replace("]", "]]")
                            $sqlQuery = @"
BEGIN TRY
    IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$escapedUserName')
        CREATE USER [$escapedBracketName] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [$escapedBracketName];
    ALTER ROLE db_datawriter ADD MEMBER [$escapedBracketName];
    GRANT EXECUTE TO [$escapedBracketName];
    SELECT 'PERMISSION_GRANT_SUCCESS' AS Result;
END TRY
BEGIN CATCH
    DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
    PRINT 'ERROR: Failed to grant permissions: ' + @ErrorMessage;
    THROW;
END CATCH
"@
                            $sqlcmdOutput = sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q $sqlQuery 2>&1 | Out-String
                            $sqlExit = $LASTEXITCODE
                            
                            if ($sqlExit -eq 0 -and $sqlcmdOutput -match 'PERMISSION_GRANT_SUCCESS') {
                                return $true
                            }
                            
                            if ($sqlcmdOutput -match 'duplicate display name' -or 
                                $sqlcmdOutput -match 'Msg 33131') {
                                Write-StepStatus "" "Error" "Non-retryable error: Duplicate display name in Azure AD"
                                throw "SQL Commander managed identity has duplicate display name - cannot proceed"
                            }
                            
                            if ($sqlcmdOutput) {
                                Write-StepStatus "" "Info" "SQL output: $sqlcmdOutput"
                            }
                            return $false
                        } catch {
                            if ($_.Exception.Message -match 'duplicate display name' -or 
                                $_.Exception.Message -match 'cannot proceed') {
                                throw  # Re-throw to stop retries
                            }
                            Write-StepStatus "" "Info" "SQL error: $($_.Exception.Message)"
                            return $false
                        }
                    } `
                    -MaxRetries 12 `
                    -BaseDelaySeconds 20 `
                    -UseExponentialBackoff `
                    -UseJitter `
                    -MaxDelaySeconds 240 `
                    -RetryMessage "attempt {attempt}/{max}, waiting {delay}s" `
                    -OperationName "SQL Commander MI access grant"
                
                if (-not $sqlCmdSqlSuccess) {
                    $sqlCmdSqlElapsed = [math]::Round(((Get-Date) - $sqlCmdSqlStartTime).TotalSeconds, 0)
                    Write-StepStatus "" "Warning" "Failed to grant SQL access after 12 attempts ($($sqlCmdSqlElapsed)s)"
                    Write-Host "  SQL Commander may not be able to connect to the database" -ForegroundColor Yellow
                } else {
                    $sqlCmdSqlElapsed = [math]::Round(((Get-Date) - $sqlCmdSqlStartTime).TotalSeconds, 0)
                    Write-StepStatus "" "Success" "$sqlCmdSpDisplayName granted access to $sqlDb ($($sqlCmdSqlElapsed)`s)"
                }
            } else {
                Write-StepStatus "" "Warning" "Could not retrieve SQL Commander managed identity"
                Write-Host "  SQL Commander may not be able to connect to the database" -ForegroundColor Yellow
            }
            
            $sqlCmdFqdnArgs = @('containerapp', 'show', '--name', $sqlCommander, '--resource-group', $rg, '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv')
            $sqlCmdFqdnResult = Invoke-AzCli -Arguments $sqlCmdFqdnArgs
            
            if ($sqlCmdFqdnResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($sqlCmdFqdnResult.TrimmedText)) {
                $sqlCommanderFqdn = ($sqlCmdFqdnResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
                $sqlCommanderFqdn = $sqlCommanderFqdn.Trim()
                $sqlCommanderUrl = "https://$sqlCommanderFqdn"
                Write-StepStatus "" "Info" "SQL Commander URL: $sqlCommanderUrl"
                Write-StepStatus "" "Info" "Connected to Azure SQL: $sqlServerFqdn/$sqlDb"
            } else {
                Write-StepStatus "" "Info" "SQL Commander deployed but URL not yet available"
            }
        } else {
            $sqlCmdError = $sqlCmdCreateResult.TrimmedText
            Write-StepStatus "" "Info" "SQL Commander deployment skipped (non-critical): $sqlCmdError"
            Write-Host "  Continuing without SQL Commander..." -ForegroundColor DarkGray
        }
    } else {
        Write-StepStatus "" "Info" "SQL Commander deployment skipped (disabled via -NoSqlCommander)"
    }

    $totalTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    $totalTimeFormatted = "${totalTime}m"

    Write-DeploymentSummary -ResourceGroup $rg -Region $Region -SqlServer $sqlServer -SqlDatabase $sqlDb `
        -Container $container -ContainerUrl $containerUrl -LogAnalytics $logAnalytics `
        -Environment $acaEnv -CurrentUser $currentUserName -DatabaseType $dbType -TotalTime $totalTimeFormatted `
        -ClientIp $clientIp -SqlServerFqdn $sqlServerFqdn `
        -FirewallRuleName $firewallRuleName -SqlCommander $sqlCommander -SqlCommanderUrl $sqlCommanderUrl


    $deploymentSummary = @{
        ResourceGroup = $rg
        SubscriptionName = $currentSub
        Region = $Region
        Timestamp = $runTimestamp
        Version = $ScriptVersion
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Resources = @{
            SqlServer = $sqlServer
            Database = $sqlDb
            ContainerApp = $container
            ContainerUrl = $containerUrl
            LogAnalytics = $logAnalytics
            Environment = $acaEnv
        }
        DeploymentTime = $totalTimeFormatted
        CurrentUser = $currentUserName
        Tags = @{
            author = 'dab-demo'
            version = $ScriptVersion
            owner = $ownerTagValue
        }
    }
    
    $summaryJson = $deploymentSummary | ConvertTo-Json -Depth 3
    Add-Content -Path $script:CliLog -Value "`n`n[DEPLOYMENT SUMMARY]"
    Add-Content -Path $script:CliLog -Value $summaryJson
    
    Write-Host "`nDeployment log saved to: $script:CliLog" -ForegroundColor Green

    exit 0

} catch {
    Write-Host "`n"
    Write-Host ("=" * 85) -ForegroundColor Red
    Write-Host "DEPLOYMENT FAILED - ROLLING BACK" -ForegroundColor Red -BackgroundColor Black
    Write-Host ("=" * 85) -ForegroundColor Red
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $script:CliLog -Value "[$timestamp] [ERR] DEPLOYMENT FAILED`n$($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
    
    if (-not $NoCleanup -and $rg) {
        Write-Host "`nCleaning up partial deployment..." -ForegroundColor Yellow
        
        $deleteArgs = @('group', 'delete', '--name', $rg, '--yes', '--no-wait')
        $deleteResult = Invoke-AzCli -Arguments $deleteArgs
        
        if ($deleteResult.ExitCode -eq 0) {
            Write-Host "Resource group deletion initiated (running in background): $rg" -ForegroundColor Green
        } else {
            Write-Host "WARNING: Failed to delete resource group automatically" -ForegroundColor Red
            Write-Host "Manual cleanup required: az group delete -n $rg -y" -ForegroundColor Yellow
            Write-Host "Error: $($deleteResult.Text)" -ForegroundColor DarkYellow
        }
    } elseif ($NoCleanup) {
        Write-Host "`nSkipping cleanup (-NoCleanup specified)" -ForegroundColor Yellow
        Write-Host "Resource group preserved for debugging: $rg" -ForegroundColor Cyan
    }
    
    Write-Host "`nDeployment log available at: $script:CliLog" -ForegroundColor Cyan
    Write-Host "`nScript completed at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
    
    exit 1
} finally {
    $ErrorActionPreference = 'Continue'
}

