<#
.SYNOPSIS
    Dispatches the next ordered GitHub deployment after a successful target.
.DESCRIPTION
    Reads deployment.branches from the selected BUILD artifact, then requests a
    workflow_dispatch for the next configured environment using the same source
    branch, commit and BUILD run ID. The caller must grant actions:write. Missing
    or inconsistent configuration and API failures throw; the final configured
    environment completes without another dispatch.
#>
$ErrorActionPreference = 'Stop'

$configPath = Join-Path (Get-Location) 'artifacts/alm-config.psd1'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Selected BUILD artifact is missing alm-config.psd1: $configPath"
}

$branchName = [string]$env:DEPLOY_BRANCH_NAME
$environmentName = [string]$env:DEPLOY_ENVIRONMENT_NAME
$buildRunId = [string]$env:DEPLOY_BUILD_RUN_ID
$sourceSha = [string]$env:DEPLOY_BUILD_SOURCE_SHA
if ([string]::IsNullOrWhiteSpace($branchName) -or
    [string]::IsNullOrWhiteSpace($environmentName) -or
    $buildRunId -notmatch '^\d+$' -or
    $sourceSha -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Resolved BUILD and deployment identity is incomplete; cannot continue the deployment chain.'
}

$config = Import-PowerShellDataFile -LiteralPath $configPath
if (-not $config.Contains('deployment') -or -not $config.deployment.Contains('branches')) {
    throw "No deployment.branches mapping is present in '$configPath'."
}
$branchMappings = $config.deployment.branches
if (-not $branchMappings.Contains($branchName)) {
    throw "No deployment environment mapping is configured for branch '$branchName'."
}

$environments = @($branchMappings[$branchName] | ForEach-Object { [string]$_ })
$targetIndex = -1
for ($index = 0; $index -lt $environments.Count; $index++) {
    if ($environments[$index] -ceq $environmentName) {
        $targetIndex = $index
        break
    }
}
if ($targetIndex -lt 0) {
    throw "Successfully deployed environment '$environmentName' is not configured for branch '$branchName'."
}

$nextIndex = $targetIndex + 1
if ($nextIndex -ge $environments.Count) {
    Write-Host "Deployment chain for '$branchName' is complete at '$environmentName'."
    return
}

$repo = [string]$env:GITHUB_REPOSITORY
if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -or [string]::IsNullOrWhiteSpace($repo)) {
    throw 'GitHub token or repository context is unavailable; cannot continue the deployment chain.'
}

$payload = @{
    ref = $branchName
    inputs = @{
        branch = $branchName
        'build-run-name' = $buildRunId
        'target-environment' = [string]$environments[$nextIndex]
        'source-sha' = $sourceSha
    }
} | ConvertTo-Json -Depth 5 -Compress
$dispatchUri = "https://api.github.com/repos/$repo/actions/workflows/DEPLOY.yml/dispatches"
Invoke-RestMethod -Uri $dispatchUri -Method Post -Headers @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
} -ContentType 'application/json' -Body $payload

Write-Host "Queued DEPLOY for '$($environments[$nextIndex])' after successful deployment to '$environmentName'."
