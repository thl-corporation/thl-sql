param(
    [string]$Branch = "",
    [switch]$ForceWithLease,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [string]$SshCommand = ""
    )

    $gitArgs = @()
    if ($SshCommand) {
        $gitArgs += @("-c", "core.sshCommand=$SshCommand")
    }
    $gitArgs += $Arguments

    & git @gitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Test-GitRemoteAccess {
    param(
        [string]$Url,
        [string]$SshCommand = ""
    )

    $gitArgs = @()
    if ($SshCommand) {
        $gitArgs += @("-c", "core.sshCommand=$SshCommand")
    }
    $gitArgs += @("ls-remote", "--heads", $Url)

    & git @gitArgs *> $null
    return $LASTEXITCODE -eq 0
}

$repoRoot = (& git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) {
    throw "Could not determine the git repository root."
}

Set-Location $repoRoot

if (-not $Branch) {
    $Branch = (& git branch --show-current).Trim()
}

if (-not $Branch) {
    throw "Could not determine the current branch. Pass -Branch explicitly."
}

$preferredSpaRepoUrl = if ($env:THL_SQL_SPA_REPO_URL) {
    $env:THL_SQL_SPA_REPO_URL
} else {
    "git@github.com:thl-corporation-spa/thl-sql.git"
}

$legacySpaRepoUrl = if ($env:THL_SQL_SPA_LEGACY_REPO_URL) {
    $env:THL_SQL_SPA_LEGACY_REPO_URL
} else {
    "git@github.com:thl-corporation-spa/vps-kamatera-SQL-01.git"
}

$corpRepoUrl = if ($env:THL_SQL_CORP_REPO_URL) {
    $env:THL_SQL_CORP_REPO_URL
} else {
    "git@github.com:thl-corporation/thl-sql.git"
}

$corpSshKey = if ($env:THL_SQL_CORP_SSH_KEY) {
    $env:THL_SQL_CORP_SSH_KEY
} else {
    "C:/Users/C11263-010/ssh_keys/thl_sql_deploy_ed25519"
}

if (-not (Test-Path $corpSshKey)) {
    throw "The corporation SSH key was not found at '$corpSshKey'. Set THL_SQL_CORP_SSH_KEY if needed."
}

$corpSshCommand = "C:/Windows/System32/OpenSSH/ssh.exe -i $corpSshKey -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
$spaRepoUrl = $preferredSpaRepoUrl
$usedLegacySpaRepo = $false

if (-not (Test-GitRemoteAccess -Url $preferredSpaRepoUrl)) {
    if (Test-GitRemoteAccess -Url $legacySpaRepoUrl) {
        $spaRepoUrl = $legacySpaRepoUrl
        $usedLegacySpaRepo = $true
    } else {
        throw "Neither the preferred SPA repo '$preferredSpaRepoUrl' nor the legacy repo '$legacySpaRepoUrl' is currently reachable."
    }
}

$refSpec = "HEAD:refs/heads/$Branch"
$pushArgs = @("push")
if ($ForceWithLease) {
    $pushArgs += "--force-with-lease"
}
if ($DryRun) {
    $pushArgs += "--dry-run"
}

Write-Host "Pushing to SPA repo: $spaRepoUrl"
Invoke-Git -Arguments ($pushArgs + @($spaRepoUrl, $refSpec))

Write-Host "Pushing to corporation repo: $corpRepoUrl"
Invoke-Git -Arguments ($pushArgs + @($corpRepoUrl, $refSpec)) -SshCommand $corpSshCommand

if ($usedLegacySpaRepo) {
    Write-Warning "The preferred SPA repo '$preferredSpaRepoUrl' is not available yet. Push used '$legacySpaRepoUrl' as a temporary fallback."
}

Write-Host "Dual push completed for branch '$Branch'."
