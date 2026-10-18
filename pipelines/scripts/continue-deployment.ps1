<#
.SYNOPSIS
    Queues the next configured Azure DevOps deployment run.
.DESCRIPTION
    Reads the selected BUILD artifact's alm-config.psd1 and queues the same DEPLOY
    definition with its exact BUILD resource version and the next ordered environment.
    With QueueInitial, an empty target selects the first environment. A branch without
    targets is a successful no-op. Queue failures, missing configuration and invalid
    targets throw; the script does not deploy or modify the application configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactsPath,
    [Parameter()][AllowEmptyString()][string]$TargetEnvironment = '',
    [Parameter()][switch]$QueueInitial,
    [Parameter()][AllowEmptyString()][string]$PreviousEnvironmentName = ''
)

$ErrorActionPreference = 'Stop'

$configPath = Join-Path $ArtifactsPath 'alm-config.psd1'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Selected BUILD artifact is missing alm-config.psd1: $configPath"
}

$buildBranch = [string]$env:DEPLOY_BUILD_SOURCE_BRANCH
$buildBranch = $buildBranch -replace '^refs/heads/', ''
if ([string]::IsNullOrWhiteSpace($buildBranch)) {
    throw 'Could not resolve the selected BUILD resource source branch.'
}

$config = Import-PowerShellDataFile -LiteralPath $configPath
$branchMappings = if ($config.Contains('deployment') -and $config.deployment.Contains('branches')) {
    $config.deployment.branches
}
else {
    $null
}
if ($null -eq $branchMappings -or -not $branchMappings.Contains($buildBranch)) {
    if ($QueueInitial) {
        Write-Host "No deployment environments are configured for branch '$buildBranch'; no deployment run will be queued."
        return
    }
    throw "No deployment environments are configured for branch '$buildBranch'."
}

$environments = @($branchMappings[$buildBranch] | ForEach-Object { [string]$_ })
if ($environments.Count -eq 0) {
    if ($QueueInitial) {
        Write-Host "No deployment environments are configured for branch '$buildBranch'; no deployment run will be queued."
        return
    }
    throw "No deployment environments are configured for branch '$buildBranch'."
}
if (@($environments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw "Deployment environment mapping for branch '$buildBranch' contains a blank name."
}

$isInitialQueue = $QueueInitial -and [string]::IsNullOrWhiteSpace($TargetEnvironment)
if ($isInitialQueue) {
    if (-not [string]::IsNullOrWhiteSpace($PreviousEnvironmentName)) {
        throw 'An initial deployment queue cannot specify a previous environment.'
    }
    $targetIndex = -1
}
else {
    $targetIndex = -1
    for ($index = 0; $index -lt $environments.Count; $index++) {
        if ($environments[$index] -ceq $TargetEnvironment) {
            $targetIndex = $index
            break
        }
    }
    if ($targetIndex -lt 0) {
        throw "Target environment '$TargetEnvironment' is not configured for branch '$buildBranch'."
    }
}

$expectedPreviousEnvironment = if ($targetIndex -gt 0) { [string]$environments[$targetIndex - 1] } else { '' }
if (-not $isInitialQueue -and $PreviousEnvironmentName -cne $expectedPreviousEnvironment) {
    throw "Previous environment '$PreviousEnvironmentName' does not match configured predecessor '$expectedPreviousEnvironment' for '$($environments[$targetIndex])'."
}

$nextIndex = $targetIndex + 1
if ($nextIndex -ge $environments.Count) {
    Write-Host "Deployment chain for '$buildBranch' is complete at '$($environments[$targetIndex])'."
    return
}

$accessToken = [string]$env:SYSTEM_ACCESSTOKEN
if ([string]::IsNullOrWhiteSpace($accessToken)) {
    throw 'System.AccessToken is unavailable; enable OAuth token access and pipeline queue permission for the build identity.'
}
$buildRunName = [string]$env:DEPLOY_BUILD_RUN_NAME
if ([string]::IsNullOrWhiteSpace($buildRunName)) {
    throw 'Could not resolve the selected BUILD resource run name.'
}
$definitionId = [string]$env:SYSTEM_DEFINITIONID
$projectName = [string]$env:SYSTEM_TEAMPROJECT
$collectionUri = [string]$env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI
if ([string]::IsNullOrWhiteSpace($definitionId) -or
    [string]::IsNullOrWhiteSpace($projectName) -or
    [string]::IsNullOrWhiteSpace($collectionUri)) {
    throw 'Azure DevOps pipeline identity variables are unavailable; cannot queue the next deployment.'
}

$encodedProject = [System.Uri]::EscapeDataString($projectName)
$requestUri = '{0}{1}/_apis/pipelines/{2}/runs?api-version=7.1' -f $collectionUri.TrimEnd('/'), "/$encodedProject", $definitionId
$body = @{
    resources = @{
        pipelines = @{
            build = @{
                version = $buildRunName
                branch = "refs/heads/$buildBranch"
            }
        }
    }
    templateParameters = @{
        targetEnvironment = [string]$environments[$nextIndex]
        previousEnvironment = if ($isInitialQueue) { '' } else { [string]$environments[$targetIndex] }
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Uri $requestUri -Method Post -Headers @{
    Authorization = "Bearer $accessToken"
    Accept = 'application/json'
} -ContentType 'application/json' -Body $body
if ($null -eq $response -or $null -eq $response.id) {
    throw "Azure DevOps did not return a run ID while queuing deployment to '$($environments[$nextIndex])'."
}

$queueReason = if ($isInitialQueue) { "selected BUILD '$buildRunName'" } else { "successful deployment to '$($environments[$targetIndex])'" }
Write-Host "Queued DEPLOY run $($response.id) for '$($environments[$nextIndex])' after $queueReason."
