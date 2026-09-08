<#
.SYNOPSIS
    Deterministic localization gate and validation checks for `.resw` and WTA locale files.

.DESCRIPTION
    `Gate` mode compares customer-facing localization semantics between the pull
    request base and target head. It ignores BOM, end-of-line, comment, order,
    and formatting-only churn.

    `Validate` mode performs deterministic checks against either immutable git
    revisions (`-HeadRevision`) or the current working tree (omit
    `-HeadRevision`). When repair validation must preserve the reviewed
    source-language authority, pass `-ReviewedHeadRevision` so en-US source
    files are compared against the immutable reviewed head instead of the
    mutable worktree. Validation only considers localization files changed in
    the comparison scope.

    The script writes JSONL records to stdout. The final line is always the
    summary record.
    Dot-source the script to reuse the summary-reading helpers without running
    `Gate` or `Validate`.

    Exit codes:
      0  PASS      (`action = NONE`)
      10 PASS      (`action = REVIEW`; Gate found semantic changes)
      20 FIXABLE   (`action = FIX`)
      30 BLOCKED   (`action = ESCALATE`)
      64 INVALID_INPUT

.PARAMETER Mode
    `Gate` or `Validate`.

.PARAMETER PullRequestNumber
    Optional positive decimal pull request number. When provided, validated
    before git object inspection.

.PARAMETER BaseRevision
    Immutable base commit SHA from workflow dispatch or manual invocation.

.PARAMETER HeadRevision
    Immutable head commit SHA for read-only git-object inspection. Omit in
    `Validate` mode to compare the working tree against the computed merge base.

.PARAMETER ReviewedHeadRevision
    Optional immutable reviewed pull request head for `Validate` mode source
    authority. Use this when validating repair edits in the current working tree
    so reviewed en-US source files must remain content-identical to the reviewed
    head, with source comments and BOM preserved.

.PARAMETER RepositoryRoot
    Repository root containing `.git`. Defaults to the current location.

.EXAMPLE
    pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Gate -PullRequestNumber 13 -BaseRevision <base-sha> -HeadRevision <head-sha>

.EXAMPLE
    pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Validate -BaseRevision <base-sha>

.EXAMPLE
    pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Validate -BaseRevision <base-sha> -ReviewedHeadRevision <reviewed-head-sha>
#>
[CmdletBinding()]
param(
    [string]$Mode,

    [string]$PullRequestNumber,

    [string]$BaseRevision,

    [string]$HeadRevision,

    [string]$ReviewedHeadRevision,

    [string]$RepositoryRoot = (Get-Location).Path
)

$script:LocalizationPathspecs = @(
    'src/cascadia/**/Resources/*.resw',
    'src/cascadia/**/Resources/**/*.resw',
    'tools/wta/locales/*.yml'
)
$script:ExitCodes = @{
    Pass = 0
    Review = 10
    Fixable = 20
    Blocked = 30
    InvalidInput = 64
}
$script:ResultRecords = [System.Collections.Generic.List[object]]::new()
$script:FileBytesCache = @{}
$script:ParsedReswCache = @{}
$script:ParsedWtaCache = @{}
$script:RepositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot)

function ConvertTo-RepoPath {
    param([Parameter(Mandatory)][string]$Path)

    $relative = [System.IO.Path]::GetRelativePath($script:RepositoryRootPath, $Path)
    return ($relative -replace '\\', '/')
}

function ConvertTo-PlatformPath {
    param([Parameter(Mandatory)][string]$Path)

    return ($Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

function Write-LocalizationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('check', 'summary')][string]$Kind,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Action,
        [bool]$ShouldRun,
        [string]$CheckId,
        [string]$File,
        [string]$Resource,
        $Observed,
        $Expected,
        [string]$Message,
        [string]$SuggestedAction,
        [string]$ComparisonBase,
        [int]$TotalCount = 0,
        [int]$PassCount = 0,
        [int]$FixableCount = 0,
        [int]$BlockedCount = 0
    )

    $record = [ordered]@{
        kind = $Kind
        mode = $Mode
        status = $Status
        action = $Action
        should_run = if ($Kind -eq 'summary') { $ShouldRun } else { $null }
        check_id = $CheckId
        file = $File
        resource = $Resource
        observed = $Observed
        expected = $Expected
        message = $Message
        suggested_action = $SuggestedAction
        comparison_base = $ComparisonBase
        total_count = if ($Kind -eq 'summary') { $TotalCount } else { $null }
        pass_count = if ($Kind -eq 'summary') { $PassCount } else { $null }
        fixable_count = if ($Kind -eq 'summary') { $FixableCount } else { $null }
        blocked_count = if ($Kind -eq 'summary') { $BlockedCount } else { $null }
    }

    if ($Kind -eq 'check') {
        $script:ResultRecords.Add([pscustomobject]$record)
    }

    [Console]::Out.WriteLine(($record | ConvertTo-Json -Compress -Depth 6))
    return [pscustomobject]$record
}

function Complete-LocalizationRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][bool]$ShouldRun,
        [Parameter(Mandatory)][string]$Message,
        [string]$ComparisonBase
    )

    $passCount = @($script:ResultRecords | Where-Object { $_.status -eq 'PASS' }).Count
    $fixableCount = @($script:ResultRecords | Where-Object { $_.status -eq 'FIXABLE' }).Count
    $blockedCount = @($script:ResultRecords | Where-Object { $_.status -eq 'BLOCKED' }).Count
    $totalCount = $script:ResultRecords.Count

    $summary = Write-LocalizationResult -Kind 'summary' -Status $Status -Action $Action -ShouldRun $ShouldRun `
        -CheckId $null -File $null -Resource $null -Observed $null -Expected $null `
        -Message $Message -SuggestedAction $null -ComparisonBase $ComparisonBase `
        -TotalCount $totalCount -PassCount $passCount -FixableCount $fixableCount -BlockedCount $blockedCount

    $exitCode = switch ($Status) {
        'BLOCKED' { $script:ExitCodes.Blocked; break }
        'FIXABLE' { $script:ExitCodes.Fixable; break }
        default {
            if ($Mode -eq 'Gate' -and $ShouldRun) {
                $script:ExitCodes.Review
            } else {
                $script:ExitCodes.Pass
            }
        }
    }

    return [pscustomobject]@{ Summary = $summary; ExitCode = $exitCode }
}

function Get-LocalizationValidatorSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath
    )

    if (-not (Test-Path -LiteralPath $JsonlPath)) {
        throw [System.IO.FileNotFoundException]::new("Localization validator output file '$JsonlPath' was not found.")
    }

    $summary = Get-Content -LiteralPath $JsonlPath | Select-Object -Last 1 | ConvertFrom-Json -AsHashtable
    if ($summary.kind -ne 'summary') {
        throw 'Localization validator did not emit a summary record.'
    }

    return $summary
}

function Resolve-LocalizationValidatorCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [Parameter(Mandatory)][int]$ExitCode,
        [int[]]$AllowedExitCodes = @(0, 10, 20, 30, 64)
    )

    if ($AllowedExitCodes -notcontains $ExitCode) {
        throw "Unexpected localization validator exit code: $ExitCode"
    }

    $summary = Get-LocalizationValidatorSummary -JsonlPath $JsonlPath
    if ($ExitCode -eq 64) {
        if ($summary.status -ne 'BLOCKED' -or $summary.action -ne 'ESCALATE') {
            throw 'Localization validator exit 64 must emit a BLOCKED/ESCALATE summary record.'
        }
    }

    $shouldRun = if ($summary.action -eq 'ESCALATE') {
        $false
    } elseif ($null -ne $summary.should_run) {
        [bool]$summary.should_run
    } else {
        $false
    }

    return [pscustomobject]@{
        Summary = $summary
        ShouldRun = $shouldRun
    }
}

function Test-LocalizationMode {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw [System.ArgumentException]::new("Mode is required; expected 'Gate' or 'Validate'.")
    }

    if ($Value -cnotin @('Gate', 'Validate')) {
        throw [System.ArgumentException]::new("Invalid Mode '$Value'; expected 'Gate' or 'Validate'.")
    }

    return $Value
}

function Test-PullRequestNumber {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    if ($Value -notmatch '^[1-9][0-9]*$') {
        throw [System.ArgumentException]::new("Invalid pull request number '$Value'; expected a positive decimal integer.")
    }

    return $Value
}

function Test-GitHubRepositoryName {
    param(
        [string]$Value,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw [System.ArgumentException]::new("$ParameterName is required; expected owner/repository.")
    }

    if ($Value -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw [System.ArgumentException]::new("Invalid $ParameterName '$Value'; expected owner/repository.")
    }

    return $Value
}

function Test-GitObjectId {
    param(
        [string]$Value,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw [System.ArgumentException]::new("$ParameterName is required; expected exactly 40 hexadecimal characters.")
    }

    if ($Value -notmatch '^[0-9a-fA-F]{40}$') {
        throw [System.ArgumentException]::new("Invalid $ParameterName '$Value'; expected exactly 40 hexadecimal characters.")
    }

    return $Value.ToLowerInvariant()
}

function Get-ValidatedWorkflowPrepareInputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PullRequestNumber,
        [Parameter(Mandatory)][string]$BaseRevision,
        [Parameter(Mandatory)][string]$HeadRevision,
        [string]$Repository,
        [string]$TrustedRepository
    )

    $inputs = [ordered]@{
        PullRequestNumber = Test-PullRequestNumber -Value $PullRequestNumber
        BaseRevision = Test-GitObjectId -Value $BaseRevision -ParameterName 'BaseRevision'
        HeadRevision = Test-GitObjectId -Value $HeadRevision -ParameterName 'HeadRevision'
    }

    if ($PSBoundParameters.ContainsKey('Repository')) {
        $inputs.Repository = if ($PSBoundParameters.ContainsKey('TrustedRepository') -and -not [string]::IsNullOrWhiteSpace($TrustedRepository)) {
            Resolve-TrustedGitHubRepository -Repository $Repository -TrustedRepository $TrustedRepository
        } else {
            Test-GitHubRepositoryName -Value $Repository -ParameterName 'Repository'
        }
    }

    return [pscustomobject]$inputs
}

function Invoke-GitText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [string]$CommandDisplay
    )

    if ([string]::IsNullOrWhiteSpace($CommandDisplay)) {
        $CommandDisplay = "git $($Arguments -join ' ')"
    }

    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = (@($output) -join "`n").TrimEnd("`r", "`n")

    if (-not $AllowFailure -and $exitCode -ne 0) {
        $messageSuffix = if ([string]::IsNullOrWhiteSpace($text)) { '' } else { " $text" }
        throw "$CommandDisplay failed with exit code $exitCode.$messageSuffix"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $text
    }
}

function Get-GitRemoteUrl {
    [CmdletBinding()]
    param([string]$RemoteName = 'origin')

    $result = Invoke-GitText -Arguments @('remote', 'get-url', $RemoteName)
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        throw [System.ArgumentException]::new("Git remote '$RemoteName' does not have a fetch URL.")
    }

    return $result.Output.Trim()
}

function Get-GitHubScopedExtraHeaderConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemoteUrl,
        [string]$Token = $env:GH_TOKEN
    )

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        throw [System.ArgumentException]::new('RemoteUrl is required to scope the temporary GitHub authorization header.')
    }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw [System.ArgumentException]::new('GH_TOKEN is required to authenticate GitHub git fetch operations.')
    }

    try {
        $uri = [System.Uri]$RemoteUrl
    } catch {
        throw [System.ArgumentException]::new("RemoteUrl '$RemoteUrl' is not a valid absolute URI.")
    }

    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
        throw [System.ArgumentException]::new("RemoteUrl '$RemoteUrl' must be an https remote to scope the temporary GitHub authorization header.")
    }

    $authority = $uri.GetLeftPart([System.UriPartial]::Authority).TrimEnd('/')
    $credential = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
    return "http.$authority/.extraheader=AUTHORIZATION: basic $credential"
}

function Invoke-GitHubPullRequestHeadFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PullRequestNumber,
        [Parameter(Mandatory)][string]$RemoteRef,
        [string]$RemoteName = 'origin'
    )

    $validatedPullRequestNumber = Test-PullRequestNumber -Value $PullRequestNumber
    if ([string]::IsNullOrWhiteSpace($RemoteRef)) {
        throw [System.ArgumentException]::new('RemoteRef is required to store the fetched pull request head.')
    }

    $remoteUrl = Get-GitRemoteUrl -RemoteName $RemoteName
    $extraHeaderConfig = Get-GitHubScopedExtraHeaderConfig -RemoteUrl $remoteUrl
    $refSpec = "+refs/pull/$validatedPullRequestNumber/head:$RemoteRef"
    $commandDisplay = "git fetch --no-tags $RemoteName <pull-request-head-refspec>"

    return Invoke-GitText -Arguments @('-c', $extraHeaderConfig, 'fetch', '--no-tags', $RemoteName, $refSpec) -CommandDisplay $commandDisplay
}

function Test-LocalizationWorkflowCompletionCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Commit,
        [Parameter(Mandatory)][string]$ExpectedHeadSha
    )

    $authorLogin = if ($null -ne $Commit.author) { $Commit.author.login } else { $null }
    $committerLogin = if ($null -ne $Commit.committer) { $Commit.committer.login } else { $null }
    $verified = [bool]$Commit.commit.verification.verified
    $parentCount = @($Commit.parents).Count
    if ($authorLogin -ne 'github-actions[bot]' -or $committerLogin -ne 'web-flow' -or -not $verified -or $parentCount -ne 1) {
        return $false
    }

    return $Commit.parents[0].sha -eq $ExpectedHeadSha
}

function Invoke-ProcessBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutMilliseconds = 120000
    )

    if ($TimeoutMilliseconds -le 0) {
        throw [System.ArgumentException]::new("TimeoutMilliseconds '$TimeoutMilliseconds' must be a positive integer.")
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($script:RepositoryRootPath)) {
        $startInfo.WorkingDirectory = $script:RepositoryRootPath
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stdoutBuffer = [System.IO.MemoryStream]::new()
    $processStarted = $false

    try {
        $null = $process.Start()
        $processStarted = $true

        $stdoutCopyTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
        $stderrReadTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $ownedProcessId = $process.Id
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
            } catch [System.InvalidOperationException] {
            }

            [void]$process.WaitForExit(5000)
            throw [System.TimeoutException]::new("Process '$FilePath' timed out after $TimeoutMilliseconds ms (PID $ownedProcessId).")
        }

        $process.WaitForExit()
        [void]$stdoutCopyTask.GetAwaiter().GetResult()
        $stderr = $stderrReadTask.GetAwaiter().GetResult().TrimEnd("`r", "`n")

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Bytes = $stdoutBuffer.ToArray()
            Stderr = $stderr
        }
    } finally {
        if ($processStarted) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    [void]$process.WaitForExit(5000)
                }
            } catch [System.InvalidOperationException] {
            }
        }

        $stdoutBuffer.Dispose()
        $process.Dispose()
    }
}

function Invoke-GitHubApiJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Context)) {
        $Context = "gh api $Path"
    }

    $result = Invoke-ProcessBytes -FilePath 'gh' -Arguments @('api', $Path)
    $stdout = [System.Text.Encoding]::UTF8.GetString($result.Bytes).Trim()

    return (Resolve-GitHubApiJson -Context $Context -ExitCode $result.ExitCode -Stdout $stdout -Stderr $result.Stderr)
}

function Resolve-GitHubApiJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Stdout,
        [string]$Stderr
    )

    if ($ExitCode -ne 0) {
        $messageSuffix = if ([string]::IsNullOrWhiteSpace($Stderr)) { '' } else { " $Stderr" }
        throw "$Context failed with exit code $ExitCode.$messageSuffix"
    }

    if ([string]::IsNullOrWhiteSpace($Stdout)) {
        throw "$Context returned no JSON output."
    }

    try {
        return ($Stdout | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    } catch {
        throw "$Context returned invalid JSON output."
    }
}

function Resolve-TrustedGitHubRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$TrustedRepository
    )

    $validatedRepository = Test-GitHubRepositoryName -Value $Repository -ParameterName 'Repository'
    $validatedTrustedRepository = Test-GitHubRepositoryName -Value $TrustedRepository -ParameterName 'TrustedRepository'

    if (-not $validatedRepository.Equals($validatedTrustedRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [System.ArgumentException]::new("Repository '$validatedRepository' does not match trusted repository '$validatedTrustedRepository'.")
    }

    return $validatedTrustedRepository
}

function Assert-RepositoryRoot {
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if (-not (Test-Path -LiteralPath $root)) {
        throw [System.ArgumentException]::new("RepositoryRoot '$RepositoryRoot' does not exist.")
    }

    $script:RepositoryRootPath = $root
    Set-Location -LiteralPath $script:RepositoryRootPath

    $repoRoot = Invoke-GitText -Arguments @('rev-parse', '--show-toplevel')
    if ([string]::IsNullOrWhiteSpace($repoRoot.Output)) {
        throw [System.ArgumentException]::new("RepositoryRoot '$script:RepositoryRootPath' is not inside a git repository.")
    }

    $normalizedGitRoot = [System.IO.Path]::GetFullPath($repoRoot.Output)
    if ($normalizedGitRoot -ne $script:RepositoryRootPath) {
        throw [System.ArgumentException]::new("RepositoryRoot '$script:RepositoryRootPath' does not match git root '$normalizedGitRoot'.")
    }
}

function Assert-GitCommitExists {
    param([Parameter(Mandatory)][string]$Revision)

    $result = Invoke-GitText -Arguments @('cat-file', '-e', "$Revision^{commit}") -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw [System.ArgumentException]::new("Git commit '$Revision' is not available in this repository.")
    }
}

function Resolve-ComparisonBase {
    param(
        [Parameter(Mandatory)][string]$BaseRevision,
        [Parameter(Mandatory)][string]$TargetRevision
    )

    $result = Invoke-GitText -Arguments @('merge-base', $BaseRevision, $TargetRevision) -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        throw [System.InvalidOperationException]::new("Unable to resolve merge base between $BaseRevision and $TargetRevision.")
    }

    return $result.Output.Trim()
}

function Get-ValidationChangedLocalizationPaths {
    param(
        [Parameter(Mandatory)][string]$ComparisonBase,
        [string]$TargetViewRevision,
        [string]$ReviewedHeadRevision
    )

    $paths = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in @(Get-ChangedLocalizationPath -ComparisonBase $ComparisonBase -HeadRevision $TargetViewRevision)) {
        $null = $paths.Add($path)
    }
    if (-not [string]::IsNullOrWhiteSpace($ReviewedHeadRevision)) {
        foreach ($path in @(Get-ChangedLocalizationPath -ComparisonBase $ComparisonBase -HeadRevision $ReviewedHeadRevision)) {
            $null = $paths.Add($path)
        }
    }
    return @($paths)
}

function Get-LocalizationFileKind {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ($Path -match '^src/cascadia/.+/Resources(?:/[^/]+)*/[^/]+\.resw$') {
        return 'resw'
    }

    if ($Path -match '^tools/wta/locales/[^/]+\.yml$') {
        return 'wta'
    }

    return $null
}

function Test-SourceLocalePreserved {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('resw', 'wta')]
        [string]$Kind,

        [Parameter(Mandatory)][string]$Path,

        [Parameter(Mandatory)][string]$ReviewedRevision,

        [string]$TargetRevision,

        [Parameter(Mandatory)][string]$ComparisonBase
    )

    $reviewedBytes = Get-FileBytesFromView -Path $Path -Revision $ReviewedRevision
    $targetBytes = Get-FileBytesFromView -Path $Path -Revision $TargetRevision
    $sourceLabel = if ($Kind -eq 'resw') { 'source-language .resw file' } else { 'source-language WTA locale file' }

    if ($null -eq $reviewedBytes) {
        if ($null -ne $targetBytes) {
            Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.source-locale-preserved' `
                -File $Path -Resource $null -Observed 'present' -Expected 'removed' `
                -Message "The reviewed $sourceLabel was removed in the reviewed head and must stay removed during localization repair." `
                -SuggestedAction 'Restore the exact reviewed source state before validating translations.' `
                -ComparisonBase $ComparisonBase | Out-Null
        }
        return
    }

    if ($null -eq $targetBytes) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.source-locale-preserved' `
            -File $Path -Resource $null -Observed 'missing' -Expected 'present' `
            -Message "The reviewed $sourceLabel is missing from the validation target." `
            -SuggestedAction 'Restore the exact reviewed source file before validating translations.' `
            -ComparisonBase $ComparisonBase | Out-Null
        return
    }

    $reviewedHasBom = Test-HasUtf8Bom -Bytes $reviewedBytes
    $targetHasBom = Test-HasUtf8Bom -Bytes $targetBytes
    if ($reviewedHasBom -ne $targetHasBom) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.source-locale-preserved' `
            -File $Path -Resource $null -Observed $(if ($targetHasBom) { 'utf-8-bom' } else { 'utf-8-no-bom' }) `
            -Expected $(if ($reviewedHasBom) { 'utf-8-bom' } else { 'utf-8-no-bom' }) `
            -Message "The reviewed $sourceLabel changed after review. Localization repair must preserve the reviewed source encoding." `
            -SuggestedAction 'Restore the exact reviewed source file before validating translations.' `
            -ComparisonBase $ComparisonBase | Out-Null
        return
    }

    try {
        $reviewedText = (Get-Utf8Text -Bytes $reviewedBytes -Path $Path -Kind $sourceLabel) -replace "`r`n|`r", "`n"
        $targetText = (Get-Utf8Text -Bytes $targetBytes -Path $Path -Kind $sourceLabel) -replace "`r`n|`r", "`n"
    } catch {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.source-locale-preserved' `
            -File $Path -Resource $null -Observed 'invalid source text' -Expected 'reviewed source text' `
            -Message "The reviewed $sourceLabel became unreadable after review. Localization repair must restore the reviewed source content before validating translations." `
            -SuggestedAction 'Restore the exact reviewed source file before validating translations.' `
            -ComparisonBase $ComparisonBase | Out-Null
        return
    }

    if ($reviewedText -cne $targetText) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.source-locale-preserved' `
            -File $Path -Resource $null -Observed 'changed after reviewed head' -Expected 'reviewed source content' `
            -Message "The reviewed $sourceLabel changed after review. Localization repair must preserve reviewed source keys, values, comments, and ordering." `
            -SuggestedAction 'Restore the exact reviewed source file before validating translations.' `
            -ComparisonBase $ComparisonBase | Out-Null
    }
}

function Test-HasUtf8Bom {
    param([byte[]]$Bytes)

    return $null -ne $Bytes -and $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
}

function Get-Utf8Text {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind
    )

    if ($Bytes -contains 0) {
        throw [System.InvalidOperationException]::new("$Path is not valid UTF-8 text for $Kind.")
    }

    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $offset = if (Test-HasUtf8Bom -Bytes $Bytes) { 3 } else { 0 }
    try {
        return $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    } catch [System.Text.DecoderFallbackException] {
        throw [System.InvalidOperationException]::new("$Path is not valid UTF-8 text for $Kind.")
    }
}

function Get-FileBytesFromView {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Revision
    )

    $key = if ($Revision) { "rev:$Revision::$Path" } else { "worktree::$Path" }
    if ($script:FileBytesCache.ContainsKey($key)) {
        return $script:FileBytesCache[$key]
    }

    $bytes = $null
    if ($Revision) {
        $spec = "${Revision}:$Path"
        $exists = Invoke-GitText -Arguments @('cat-file', '-e', $spec) -AllowFailure
        if ($exists.ExitCode -eq 0) {
            $blob = Invoke-ProcessBytes -FilePath 'git' -Arguments @('cat-file', 'blob', $spec)
            if ($blob.ExitCode -ne 0) {
                throw "git cat-file blob $spec failed with exit code $($blob.ExitCode). $($blob.Stderr)"
            }
            $bytes = $blob.Bytes
        }
    } else {
        $fullPath = Join-Path $script:RepositoryRootPath (ConvertTo-PlatformPath -Path $Path)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        }
    }

    $script:FileBytesCache[$key] = $bytes
    return $bytes
}

function Get-PathsInView {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$Revision
    )

    if ($Revision) {
        $result = Invoke-GitText -Arguments @('ls-tree', '-r', '--name-only', $Revision, '--', $Prefix)
        if ([string]::IsNullOrWhiteSpace($result.Output)) {
            return @()
        }
        return @($result.Output -split "`r?`n" | Where-Object { $_ })
    }

    $fullPrefix = Join-Path $script:RepositoryRootPath (ConvertTo-PlatformPath -Path $Prefix)
    if (-not (Test-Path -LiteralPath $fullPrefix)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $fullPrefix -File -Recurse |
            ForEach-Object { ConvertTo-RepoPath -Path $_.FullName }
    )
}

function Get-ChangedLocalizationPath {
    param(
        [Parameter(Mandatory)][string]$ComparisonBase,
        [string]$HeadRevision
    )

    $arguments = @('diff', '--name-only', $ComparisonBase)
    if ($HeadRevision) {
        $arguments += $HeadRevision
    }
    $arguments += '--'
    $arguments += $script:LocalizationPathspecs

    $changed = Invoke-GitText -Arguments $arguments
    $paths = @()
    if (-not [string]::IsNullOrWhiteSpace($changed.Output)) {
        $paths += @($changed.Output -split "`r?`n" | Where-Object { $_ })
    }

    if (-not $HeadRevision) {
        $untracked = Invoke-GitText -Arguments @('ls-files', '--others', '--exclude-standard', '--', $script:LocalizationPathspecs)
        if (-not [string]::IsNullOrWhiteSpace($untracked.Output)) {
            $paths += @($untracked.Output -split "`r?`n" | Where-Object { $_ })
        }
    }

    return @($paths | Sort-Object -Unique)
}

function Normalize-CommentText {
    param([string]$Text)

    return ([regex]::Replace($Text.Trim(), '\s+', ' '))
}

function Test-WtaSectionHeaderComment {
    param([string]$Line)

    return [regex]::IsMatch($Line, '^\s*#\s*──\s+.+?\s+─{2,}\s*$')
}

function Parse-QuotedTokenList {
    param([string]$Text)

    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, '"((?:[^"\\]|\\.)*)"')) {
        $literal = '"' + $match.Groups[1].Value + '"'
        $tokens.Add((ConvertFrom-Json -InputObject $literal -ErrorAction Stop))
    }
    return @($tokens.ToArray())
}

function Get-LockedRules {
    param(
        [string[]]$Comments,
        [string]$Locale
    )

    $tokenSet = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $fullLock = $false

    foreach ($comment in @($Comments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        foreach ($match in [regex]::Matches($comment, '\{Locked(?<body>[^}]*)\}')) {
            $body = $match.Groups['body'].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($body)) {
                $fullLock = $true
                continue
            }

            if (-not $body.StartsWith('=')) {
                continue
            }

            $payload = $body.Substring(1).Trim()
            if ($payload.StartsWith('"')) {
                foreach ($token in Parse-QuotedTokenList -Text $payload) {
                    $null = $tokenSet.Add($token)
                }
                continue
            }

            if ([string]::IsNullOrWhiteSpace($Locale)) {
                continue
            }

            $scopedLocales = @($payload -split '\s*,\s*' | Where-Object { $_ })
            if ($scopedLocales -notcontains $Locale) {
                continue
            }

            $suffix = $comment.Substring($match.Index + $match.Length)
            $quotedToken = [regex]::Match($suffix, '"((?:[^"\\]|\\.)*)"')
            if ($quotedToken.Success) {
                $literal = '"' + $quotedToken.Groups[1].Value + '"'
                $null = $tokenSet.Add((ConvertFrom-Json -InputObject $literal -ErrorAction Stop))
            }
        }
    }

    return [pscustomobject]@{
        FullLock = $fullLock
        Tokens = @($tokenSet)
    }
}

function Get-PlaceholderTokens {
    param([string]$Value)

    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    if ($null -eq $Value) {
        return @()
    }

    foreach ($match in [regex]::Matches($Value, '%\{[^}]+\}|\{\d+\}')) {
        $null = $set.Add($match.Value)
    }

    return @($set)
}

function Format-TokenSet {
    param([string[]]$Tokens)

    if (-not $Tokens -or $Tokens.Count -eq 0) {
        return ''
    }

    return ($Tokens -join ', ')
}

function Read-ReswResources {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Path
    )

    $null = Get-Utf8Text -Bytes $Bytes -Path $Path -Kind '.resw'

    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null

    $stream = [System.IO.MemoryStream]::new($Bytes, $false)
    try {
        $reader = [System.Xml.XmlReader]::Create($stream, $settings)
        try {
            $document = [System.Xml.XmlDocument]::new()
            $document.PreserveWhitespace = $true
            $document.Load($reader)
        } finally {
            $reader.Dispose()
        }
    } catch {
        throw [System.InvalidOperationException]::new("$Path is not well-formed XML. $($_.Exception.Message)")
    } finally {
        $stream.Dispose()
    }

    $resources = @{}
    foreach ($node in @($document.SelectNodes('/root/data'))) {
        $name = [string]$node.GetAttribute('name')
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        if ($resources.ContainsKey($name)) {
            throw [System.InvalidOperationException]::new("$Path contains duplicate resource '$name'.")
        }

        $valueNode = $node.SelectSingleNode('value')
        $commentNode = $node.SelectSingleNode('comment')
        $resources[$name] = [pscustomobject]@{
            Name = $name
            Value = if ($null -ne $valueNode) { $valueNode.InnerText } else { '' }
            Comment = if ($null -ne $commentNode) { $commentNode.InnerText } else { '' }
        }
    }

    return [pscustomobject]@{
        HasBom = Test-HasUtf8Bom -Bytes $Bytes
        Resources = $resources
    }
}

function Split-WtaScalarAndComment {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$LineNumber
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw [System.InvalidOperationException]::new("${Path}:$LineNumber uses an unsupported YAML structure.")
    }

    if ($Value.StartsWith('"')) {
        $escaped = $false
        for ($index = 1; $index -lt $Value.Length; $index++) {
            $character = $Value[$index]
            if ($escaped) {
                $escaped = $false
                continue
            }
            if ($character -eq '\') {
                $escaped = $true
                continue
            }
            if ($character -eq '"') {
                $scalar = $Value.Substring(0, $index + 1)
                $remainder = $Value.Substring($index + 1).TrimStart()
                if ($remainder -and -not $remainder.StartsWith('#')) {
                    throw [System.InvalidOperationException]::new("${Path}:$LineNumber uses an unsupported YAML structure.")
                }
                return [pscustomobject]@{
                    Scalar = $scalar
                    InlineComment = if ($remainder) { Normalize-CommentText -Text $remainder } else { $null }
                }
            }
        }
        throw [System.InvalidOperationException]::new("${Path}:$LineNumber contains an unterminated YAML string.")
    }

    if ($Value.StartsWith("'")) {
        $index = 1
        while ($index -lt $Value.Length) {
            if ($Value[$index] -eq "'") {
                if ($index + 1 -lt $Value.Length -and $Value[$index + 1] -eq "'") {
                    $index += 2
                    continue
                }
                $scalar = $Value.Substring(0, $index + 1)
                $remainder = $Value.Substring($index + 1).TrimStart()
                if ($remainder -and -not $remainder.StartsWith('#')) {
                    throw [System.InvalidOperationException]::new("${Path}:$LineNumber uses an unsupported YAML structure.")
                }
                return [pscustomobject]@{
                    Scalar = $scalar
                    InlineComment = if ($remainder) { Normalize-CommentText -Text $remainder } else { $null }
                }
            }
            $index++
        }
        throw [System.InvalidOperationException]::new("${Path}:$LineNumber contains an unterminated YAML string.")
    }

    $commentIndex = $Value.IndexOf(' #')
    if ($commentIndex -ge 0) {
        return [pscustomobject]@{
            Scalar = $Value.Substring(0, $commentIndex).TrimEnd()
            InlineComment = Normalize-CommentText -Text $Value.Substring($commentIndex + 1)
        }
    }

    return [pscustomobject]@{
        Scalar = $Value.TrimEnd()
        InlineComment = $null
    }
}

function ConvertFrom-YamlScalar {
    param(
        [Parameter(Mandatory)][string]$Scalar,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$LineNumber
    )

    if ($Scalar.StartsWith('"')) {
        try {
            return (ConvertFrom-Json -InputObject $Scalar -ErrorAction Stop)
        } catch {
            throw [System.InvalidOperationException]::new("${Path}:$LineNumber contains an unsupported YAML string literal.")
        }
    }

    if ($Scalar.StartsWith("'") -and $Scalar.EndsWith("'")) {
        return $Scalar.Substring(1, $Scalar.Length - 2).Replace("''", "'")
    }

    if ([string]::IsNullOrWhiteSpace($Scalar)) {
        throw [System.InvalidOperationException]::new("${Path}:$LineNumber uses an unsupported YAML structure.")
    }

    if ($Scalar -match '^[\[\{]|[\]\{\}]|^[>|&*!]') {
        throw [System.InvalidOperationException]::new("${Path}:$LineNumber uses an unsupported YAML structure.")
    }

    return $Scalar
}

function Parse-WtaEntryLine {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$LineNumber
    )

    $match = [regex]::Match($Line, '^\s*([A-Za-z0-9_.-]+)\s*:\s*(.*)$')
    if (-not $match.Success) {
        throw [System.InvalidOperationException]::new("${Path}:$LineNumber uses an unsupported YAML structure.")
    }

    $split = Split-WtaScalarAndComment -Value $match.Groups[2].Value -Path $Path -LineNumber $LineNumber
    return [pscustomobject]@{
        Key = $match.Groups[1].Value
        Value = ConvertFrom-YamlScalar -Scalar $split.Scalar -Path $Path -LineNumber $LineNumber
        InlineComment = $split.InlineComment
    }
}

function Read-WtaLocaleEntries {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Path
    )

    $text = Get-Utf8Text -Bytes $Bytes -Path $Path -Kind 'WTA locale file'
    $lines = @($text -split "`r`n|`n|`r", 0)
    $entries = @{}
    $fileComments = @()
    $pendingComments = [System.Collections.Generic.List[string]]::new()
    $sectionComments = @()
    $collectingSectionComments = $false
    $seenEntry = $false

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineNumber = $index + 1
        $line = $lines[$index]
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            if (-not $seenEntry -and $pendingComments.Count -gt 0 -and $fileComments.Count -eq 0) {
                $fileComments = @($pendingComments)
            }
            $pendingComments.Clear()
            $sectionComments = @()
            $collectingSectionComments = $false
            continue
        }

        if ($trimmed.StartsWith('#')) {
            if ($seenEntry -or $fileComments.Count -gt 0) {
                if (Test-WtaSectionHeaderComment -Line $trimmed) {
                    $sectionComments = @()
                    $pendingComments.Clear()
                    $collectingSectionComments = $true
                }
            }
            $pendingComments.Add((Normalize-CommentText -Text $trimmed))
            continue
        }

        if (-not $seenEntry -and $fileComments.Count -eq 0 -and $pendingComments.Count -gt 0) {
            $fileComments = @($pendingComments)
        }
        $seenEntry = $true

        $leadingComments = @($pendingComments)
        if ($collectingSectionComments) {
            $sectionComments = @($pendingComments)
            $leadingComments = @()
            $collectingSectionComments = $false
        }

        $entry = Parse-WtaEntryLine -Line $line -Path $Path -LineNumber $lineNumber
        if ($entries.ContainsKey($entry.Key)) {
            throw [System.InvalidOperationException]::new("$Path contains duplicate key '$($entry.Key)'.")
        }

        $entries[$entry.Key] = [pscustomobject]@{
            Key = $entry.Key
            Value = $entry.Value
            FileComments = @($fileComments)
            SectionComments = @($sectionComments)
            LeadingComments = @($leadingComments)
            InlineComment = $entry.InlineComment
            LineNumber = $lineNumber
        }
        $pendingComments.Clear()
    }

    return [pscustomobject]@{
        Entries = $entries
    }
}

function Get-ParsedReswFromView {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Revision
    )

    $key = if ($Revision) { "rev:$Revision::$Path" } else { "worktree::$Path" }
    if ($script:ParsedReswCache.ContainsKey($key)) {
        return $script:ParsedReswCache[$key]
    }

    $bytes = Get-FileBytesFromView -Path $Path -Revision $Revision
    if ($null -eq $bytes) {
        return $null
    }

    $parsed = Read-ReswResources -Bytes $bytes -Path $Path
    $script:ParsedReswCache[$key] = $parsed
    return $parsed
}

function Get-ParsedWtaFromView {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Revision
    )

    $key = if ($Revision) { "rev:$Revision::$Path" } else { "worktree::$Path" }
    if ($script:ParsedWtaCache.ContainsKey($key)) {
        return $script:ParsedWtaCache[$key]
    }

    $bytes = Get-FileBytesFromView -Path $Path -Revision $Revision
    if ($null -eq $bytes) {
        return $null
    }

    $parsed = Read-WtaLocaleEntries -Bytes $bytes -Path $Path
    $script:ParsedWtaCache[$key] = $parsed
    return $parsed
}

function Get-SortedUnion {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($value in @($Left + $Right)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $null = $set.Add($value)
        }
    }
    return @($set)
}

function Get-ChangedReswResources {
    param($Before, $After)

    $names = Get-SortedUnion -Left $(if ($Before) { $Before.Resources.Keys } else { @() }) -Right $(if ($After) { $After.Resources.Keys } else { @() })
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $beforeValue = if ($Before -and $Before.Resources.ContainsKey($name)) { [string]$Before.Resources[$name].Value } else { $null }
        $afterValue = if ($After -and $After.Resources.ContainsKey($name)) { [string]$After.Resources[$name].Value } else { $null }
        if ($beforeValue -cne $afterValue) {
            $changed.Add($name)
        }
    }
    return @($changed.ToArray())
}

function Get-ChangedWtaKeys {
    param($Before, $After)

    $names = Get-SortedUnion -Left $(if ($Before) { $Before.Entries.Keys } else { @() }) -Right $(if ($After) { $After.Entries.Keys } else { @() })
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $beforeValue = if ($Before -and $Before.Entries.ContainsKey($name)) { [string]$Before.Entries[$name].Value } else { $null }
        $afterValue = if ($After -and $After.Entries.ContainsKey($name)) { [string]$After.Entries[$name].Value } else { $null }
        if ($beforeValue -cne $afterValue) {
            $changed.Add($name)
        }
    }
    return @($changed.ToArray())
}

function Test-ReswSemanticChange {
    param($Before, $After)

    return (@(Get-ChangedReswResources -Before $Before -After $After)).Count -gt 0
}

function Test-WtaSemanticChange {
    param($Before, $After)

    return (@(Get-ChangedWtaKeys -Before $Before -After $After)).Count -gt 0
}

function Get-ReswSourcePath {
    param([Parameter(Mandatory)][string]$Path)

    $localeMatch = [regex]::Match($Path, '^(?<prefix>.+/Resources)/(?<locale>[^/]+)/(?<fileName>[^/]+\.resw)$')
    if ($localeMatch.Success) {
        return "$($localeMatch.Groups['prefix'].Value)/en-US/$($localeMatch.Groups['fileName'].Value)"
    }

    $rootMatch = [regex]::Match($Path, '^(?<prefix>.+/Resources)/(?<fileName>[^/]+\.resw)$')
    if ($rootMatch.Success) {
        return $Path
    }

    throw [System.InvalidOperationException]::new("Unrecognized .resw path '$Path'.")
}

function Get-ReswLocaleCode {
    param([Parameter(Mandatory)][string]$Path)

    $match = [regex]::Match($Path, '^(?<prefix>.+/Resources)/(?<locale>[^/]+)/(?<fileName>[^/]+\.resw)$')
    if ($match.Success) {
        return $match.Groups['locale'].Value
    }

    return ''
}

function Get-ReswLocalePaths {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$Revision
    )

    $localeMatch = [regex]::Match($SourcePath, '^(?<prefix>.+/Resources)/en-US/(?<fileName>[^/]+\.resw)$')
    if ($localeMatch.Success) {
        $prefix = $localeMatch.Groups['prefix'].Value
        $fileName = $localeMatch.Groups['fileName'].Value
        $pattern = '^{0}/[^/]+/{1}$' -f [regex]::Escape($prefix), [regex]::Escape($fileName)
        return @(
            Get-PathsInView -Prefix $prefix -Revision $Revision |
                Where-Object { $_ -match $pattern } |
                Sort-Object -Unique
        )
    }

    $rootMatch = [regex]::Match($SourcePath, '^(?<prefix>.+/Resources)/(?<fileName>[^/]+\.resw)$')
    if ($rootMatch.Success) {
        $prefix = $rootMatch.Groups['prefix'].Value
        $fileName = $rootMatch.Groups['fileName'].Value
        $pattern = '^{0}/[^/]+/{1}$' -f [regex]::Escape($prefix), [regex]::Escape($fileName)
        return @(
            Get-PathsInView -Prefix $prefix -Revision $Revision |
                Where-Object { $_ -match $pattern } |
                Sort-Object -Unique
        )
    }

    return @()
}

function Get-WtaLocalePaths {
    param([string]$Revision)

    return @(
        Get-PathsInView -Prefix 'tools/wta/locales' -Revision $Revision |
            Where-Object { $_ -match '^tools/wta/locales/[^/]+\.yml$' } |
            Sort-Object -Unique
    )
}

function Get-WtaLocaleCode {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-TerminalAppLocaleCodes {
    param([string]$Revision)

    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in Get-PathsInView -Prefix 'src/cascadia/TerminalApp/Resources' -Revision $Revision) {
        $match = [regex]::Match($path, '^src/cascadia/TerminalApp/Resources/(?<locale>[^/]+)/Resources\.resw$')
        if ($match.Success) {
            $null = $set.Add($match.Groups['locale'].Value)
        }
    }
    return @($set)
}

function Get-WtaEntryComments {
    param($Entry)

    $comments = [System.Collections.Generic.List[string]]::new()
    foreach ($comment in @($Entry.FileComments + $Entry.SectionComments + $Entry.LeadingComments)) {
        if (-not [string]::IsNullOrWhiteSpace($comment)) {
            $comments.Add($comment)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Entry.InlineComment)) {
        $comments.Add($Entry.InlineComment)
    }
    return @($comments)
}

function Test-ReswBomPreserved {
    param(
        [Parameter(Mandatory)][string]$Path,
        [byte[]]$BaseBytes,
        [Parameter(Mandatory)][byte[]]$TargetBytes,
        [Parameter(Mandatory)][string]$ComparisonBase
    )

    $expectedBom = if ($null -eq $BaseBytes) { $true } else { Test-HasUtf8Bom -Bytes $BaseBytes }
    $actualBom = Test-HasUtf8Bom -Bytes $TargetBytes
    if ($expectedBom -ne $actualBom) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.resw.bom-preserved' `
            -File $Path -Resource $null -Observed $(if ($actualBom) { 'utf-8-bom' } else { 'utf-8-no-bom' }) `
            -Expected $(if ($expectedBom) { 'utf-8-bom' } else { 'utf-8-no-bom' }) `
            -Message 'The .resw BOM changed unexpectedly.' -SuggestedAction 'Restore the expected UTF-8 BOM encoding.' `
            -ComparisonBase $ComparisonBase | Out-Null
    }
}

function Test-PlaceholderParity {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][string]$SourceValue,
        [Parameter(Mandatory)][string]$TargetValue,
        [Parameter(Mandatory)][string]$ComparisonBase
    )

    $sourceTokens = Get-PlaceholderTokens -Value $SourceValue
    $targetTokens = Get-PlaceholderTokens -Value $TargetValue
    $sourceJoined = Format-TokenSet -Tokens $sourceTokens
    $targetJoined = Format-TokenSet -Tokens $targetTokens

    if ($sourceJoined -cne $targetJoined) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId $CheckId `
            -File $File -Resource $Resource -Observed $targetJoined -Expected $sourceJoined `
            -Message 'Placeholder tokens do not match the source string.' `
            -SuggestedAction 'Preserve the exact source placeholder set in this localized value.' `
            -ComparisonBase $ComparisonBase | Out-Null
    }
}

function Test-LockedToken {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][string]$Locale,
        [Parameter(Mandatory)][string]$SourceValue,
        [Parameter(Mandatory)][string]$TargetValue,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][string]$ComparisonBase
    )

    if ($Rules.FullLock -and $SourceValue -cne $TargetValue) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId $CheckId `
            -File $File -Resource $Resource -Observed $TargetValue -Expected $SourceValue `
            -Message 'This value is fully locked and must remain identical to the source.' `
            -SuggestedAction 'Restore the exact source value for this locale.' `
            -ComparisonBase $ComparisonBase | Out-Null
        return
    }

    foreach ($token in @($Rules.Tokens)) {
        if (-not $SourceValue.Contains($token, [System.StringComparison]::Ordinal)) {
            continue
        }

        if (-not $TargetValue.Contains($token, [System.StringComparison]::Ordinal)) {
            Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId $CheckId `
                -File $File -Resource $Resource -Observed $TargetValue -Expected $token `
                -Message "Locked token '$token' is missing from the localized value for locale '$Locale'." `
                -SuggestedAction 'Reinsert the locked token verbatim.' `
                -ComparisonBase $ComparisonBase | Out-Null
        }
    }
}

function Test-WtaPseudoLocale {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][string]$Locale,
        [Parameter(Mandatory)][string]$SourceValue,
        [Parameter(Mandatory)][string]$TargetValue,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][string]$ComparisonBase
    )

    if ($Rules.FullLock -or [string]::IsNullOrEmpty($SourceValue)) {
        return
    }

    if ($TargetValue -ceq $SourceValue) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.wta.pseudo-locale' `
            -File $File -Resource $Resource -Observed $TargetValue -Expected 'pseudo-localized variant' `
            -Message "Pseudo-locale '$Locale' must not keep an unchanged translatable source value." `
            -SuggestedAction 'Apply the established pseudo-locale transformation for this locale.' `
            -ComparisonBase $ComparisonBase | Out-Null
        return
    }

    $validShape = switch ($Locale) {
        'qps-ploc' { $TargetValue.StartsWith('[') -and $TargetValue.EndsWith(']') }
        'qps-ploca' { $TargetValue.StartsWith('[!!_') -and $TargetValue.EndsWith('_!!]') }
        'qps-plocm' { $TargetValue.StartsWith('[!! ') -and $TargetValue.EndsWith(' !!]') }
        default { $true }
    }

    if (-not $validShape) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.wta.pseudo-locale' `
            -File $File -Resource $Resource -Observed $TargetValue -Expected $Locale `
            -Message "Pseudo-locale '$Locale' does not match its expected wrapper style." `
            -SuggestedAction 'Regenerate the pseudo-locale value using the established style for this locale.' `
            -ComparisonBase $ComparisonBase | Out-Null
    }
}

function Test-WtaLocaleSetParity {
    param(
        [Parameter(Mandatory)][string]$ComparisonBase,
        [string]$Revision
    )

    $terminalLocales = @(Get-TerminalAppLocaleCodes -Revision $Revision)
    $wtaLocales = @(
        Get-WtaLocalePaths -Revision $Revision |
            ForEach-Object { Get-WtaLocaleCode -Path $_ }
    )

    foreach ($locale in @($terminalLocales | Where-Object { $wtaLocales -notcontains $_ })) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.wta.locale-set-parity' `
            -File ("tools/wta/locales/{0}.yml" -f $locale) -Resource $locale -Observed 'missing' -Expected 'present' `
            -Message 'WTA locale coverage is missing a locale shipped by TerminalApp Resources.' `
            -SuggestedAction 'Add the matching WTA locale file or remove the unmatched TerminalApp locale addition.' `
            -ComparisonBase $ComparisonBase | Out-Null
    }

    foreach ($locale in @($wtaLocales | Where-Object { $terminalLocales -notcontains $_ })) {
        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.wta.locale-set-parity' `
            -File ("tools/wta/locales/{0}.yml" -f $locale) -Resource $locale -Observed 'present' -Expected 'removed' `
            -Message 'WTA locale coverage includes a locale missing from TerminalApp Resources.' `
            -SuggestedAction 'Remove the extra WTA locale file or add the matching TerminalApp locale resources.' `
            -ComparisonBase $ComparisonBase | Out-Null
    }
}

function Report-BlockedCheck {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [string]$File,
        [string]$Resource,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$SuggestedAction,
        [string]$ComparisonBase
    )

    Write-LocalizationResult -Kind 'check' -Status 'BLOCKED' -Action 'ESCALATE' -CheckId $CheckId `
        -File $File -Resource $Resource -Observed $null -Expected $null -Message $Message `
        -SuggestedAction $SuggestedAction -ComparisonBase $ComparisonBase | Out-Null
}

function Invoke-Gate {
    Test-PullRequestNumber -Value $PullRequestNumber | Out-Null
    $baseRevision = Test-GitObjectId -Value $BaseRevision -ParameterName 'BaseRevision'
    $headRevision = Test-GitObjectId -Value $HeadRevision -ParameterName 'HeadRevision'
    Assert-GitCommitExists -Revision $baseRevision
    Assert-GitCommitExists -Revision $headRevision

    $comparisonBase = $null
    try {
        $comparisonBase = Resolve-ComparisonBase -BaseRevision $baseRevision -TargetRevision $headRevision
    } catch {
        Report-BlockedCheck -CheckId 'gate.git.merge-base' -File $null -Resource $null `
            -Message $_.Exception.Message -SuggestedAction 'Review the pull request manually; merge-base resolution failed.' `
            -ComparisonBase $null
        return Complete-LocalizationRun -Status 'BLOCKED' -Action 'ESCALATE' -ShouldRun $true `
            -Message 'Gate could not resolve the comparison base safely.' -ComparisonBase $null
    }

    $changedPaths = @(Get-ChangedLocalizationPath -ComparisonBase $comparisonBase -HeadRevision $headRevision)
    if ($changedPaths.Count -eq 0) {
        return Complete-LocalizationRun -Status 'PASS' -Action 'NONE' -ShouldRun $false `
            -Message 'No localization files changed in scope.' -ComparisonBase $comparisonBase
    }

    $reviewRequired = $false
    foreach ($path in $changedPaths) {
        try {
            if ($path.EndsWith('.resw', [System.StringComparison]::OrdinalIgnoreCase)) {
                $before = Get-ParsedReswFromView -Path $path -Revision $comparisonBase
                $after = Get-ParsedReswFromView -Path $path -Revision $headRevision
                if (Test-ReswSemanticChange -Before $before -After $after) {
                    foreach ($resource in Get-ChangedReswResources -Before $before -After $after) {
                        $reviewRequired = $true
                        $beforeValue = if ($before -and $before.Resources.ContainsKey($resource)) { $before.Resources[$resource].Value } else { $null }
                        $afterValue = if ($after -and $after.Resources.ContainsKey($resource)) { $after.Resources[$resource].Value } else { $null }
                        Write-LocalizationResult -Kind 'check' -Status 'PASS' -Action 'REVIEW' -CheckId 'gate.resw.semantic-change' `
                            -File $path -Resource $resource -Observed $afterValue -Expected $beforeValue `
                            -Message 'Customer-facing .resw value changed.' `
                            -SuggestedAction 'Review locale coverage and translation quality for this resource.' `
                            -ComparisonBase $comparisonBase | Out-Null
                    }
                }
            } else {
                $before = Get-ParsedWtaFromView -Path $path -Revision $comparisonBase
                $after = Get-ParsedWtaFromView -Path $path -Revision $headRevision
                if (Test-WtaSemanticChange -Before $before -After $after) {
                    foreach ($resource in Get-ChangedWtaKeys -Before $before -After $after) {
                        $reviewRequired = $true
                        $beforeValue = if ($before -and $before.Entries.ContainsKey($resource)) { $before.Entries[$resource].Value } else { $null }
                        $afterValue = if ($after -and $after.Entries.ContainsKey($resource)) { $after.Entries[$resource].Value } else { $null }
                        Write-LocalizationResult -Kind 'check' -Status 'PASS' -Action 'REVIEW' -CheckId 'gate.wta.semantic-change' `
                            -File $path -Resource $resource -Observed $afterValue -Expected $beforeValue `
                            -Message 'Customer-facing WTA locale value changed.' `
                            -SuggestedAction 'Review locale coverage and translation quality for this key.' `
                            -ComparisonBase $comparisonBase | Out-Null
                    }
                }
            }
        } catch {
            Report-BlockedCheck -CheckId 'gate.parse' -File $path -Resource $null -Message $_.Exception.Message `
                -SuggestedAction 'Review this file manually; Gate failed open.' -ComparisonBase $comparisonBase
        }
    }

    if (@($script:ResultRecords | Where-Object { $_.status -eq 'BLOCKED' }).Count -gt 0) {
        return Complete-LocalizationRun -Status 'BLOCKED' -Action 'ESCALATE' -ShouldRun $true `
            -Message 'Gate could not classify every localization file safely.' -ComparisonBase $comparisonBase
    }

    if ($reviewRequired) {
        return Complete-LocalizationRun -Status 'PASS' -Action 'REVIEW' -ShouldRun $true `
            -Message 'Semantic localization changes require review.' -ComparisonBase $comparisonBase
    }

    return Complete-LocalizationRun -Status 'PASS' -Action 'NONE' -ShouldRun $false `
        -Message 'Only formatting or comment-only localization changes were detected.' -ComparisonBase $comparisonBase
}

function Invoke-Validation {
    Test-PullRequestNumber -Value $script:PullRequestNumber | Out-Null
    $baseRevision = Test-GitObjectId -Value $script:BaseRevision -ParameterName 'BaseRevision'
    Assert-GitCommitExists -Revision $baseRevision

    $targetRevision = $null
    $targetViewRevision = $null
    if ($script:HeadRevision) {
        $targetRevision = Test-GitObjectId -Value $script:HeadRevision -ParameterName 'HeadRevision'
        Assert-GitCommitExists -Revision $targetRevision
        $targetViewRevision = $targetRevision
    } else {
        $targetRevision = (Invoke-GitText -Arguments @('rev-parse', 'HEAD')).Output.Trim()
    }

    $reviewedHeadRevision = $null
    if ($script:ReviewedHeadRevision) {
        $reviewedHeadRevision = Test-GitObjectId -Value $script:ReviewedHeadRevision -ParameterName 'ReviewedHeadRevision'
        Assert-GitCommitExists -Revision $reviewedHeadRevision
    }

    $comparisonTargetRevision = if ($reviewedHeadRevision) { $reviewedHeadRevision } else { $targetRevision }
    $sourceAuthorityRevision = if ($reviewedHeadRevision) { $reviewedHeadRevision } elseif ($targetViewRevision) { $targetViewRevision } else { $null }

    $comparisonBase = $null
    try {
        $comparisonBase = Resolve-ComparisonBase -BaseRevision $baseRevision -TargetRevision $comparisonTargetRevision
    } catch {
        Report-BlockedCheck -CheckId 'validate.git.merge-base' -File $null -Resource $null `
            -Message $_.Exception.Message -SuggestedAction 'Review the pull request manually; merge-base resolution failed.' `
            -ComparisonBase $null
        return Complete-LocalizationRun -Status 'BLOCKED' -Action 'ESCALATE' -ShouldRun $true `
            -Message 'Validation could not resolve the comparison base safely.' -ComparisonBase $null
    }

    $changedPaths = @(Get-ValidationChangedLocalizationPaths -ComparisonBase $comparisonBase -TargetViewRevision $targetViewRevision -ReviewedHeadRevision $reviewedHeadRevision)
    if ($changedPaths.Count -eq 0) {
        return Complete-LocalizationRun -Status 'PASS' -Action 'NONE' -ShouldRun $false `
            -Message 'No localization changes detected in scope.' -ComparisonBase $comparisonBase
    }

    $reswChanged = @($changedPaths | Where-Object { $_.EndsWith('.resw', [System.StringComparison]::OrdinalIgnoreCase) })
    $wtaChanged = @($changedPaths | Where-Object { $_.EndsWith('.yml', [System.StringComparison]::OrdinalIgnoreCase) })
    $terminalAppLocaleChanged = @(
        $changedPaths | Where-Object { $_ -match '^src/cascadia/TerminalApp/Resources/[^/]+/[^/]+\.resw$' }
    ).Count -gt 0

    if ($wtaChanged.Count -gt 0 -or $terminalAppLocaleChanged) {
        Test-WtaLocaleSetParity -ComparisonBase $comparisonBase -Revision $targetViewRevision
    }

    $reswGroups = @{}
    foreach ($path in $reswChanged) {
        $baseBytes = Get-FileBytesFromView -Path $path -Revision $comparisonBase
        $targetBytes = Get-FileBytesFromView -Path $path -Revision $targetViewRevision
        if ($null -eq $targetBytes) {
            Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.file.exists' `
                -File $path -Resource $null -Observed 'missing from target view' -Expected 'file present' `
                -Message 'Changed localization file is missing from the target view.' `
                -SuggestedAction 'Restore the file or adjust the change set intentionally.' `
                -ComparisonBase $comparisonBase | Out-Null
            continue
        }

        $before = $null
        if ($null -ne $baseBytes) {
            try {
                $before = Get-ParsedReswFromView -Path $path -Revision $comparisonBase
            } catch {
                Report-BlockedCheck -CheckId 'validate.resw.xml-well-formed' -File $path -Resource $null `
                    -Message $_.Exception.Message -SuggestedAction 'Fix the base/reference XML before relying on deterministic validation.' `
                    -ComparisonBase $comparisonBase
                continue
            }
        }

        $after = $null
        try {
            $after = Get-ParsedReswFromView -Path $path -Revision $targetViewRevision
        } catch {
            Report-BlockedCheck -CheckId 'validate.resw.xml-well-formed' -File $path -Resource $null `
                -Message $_.Exception.Message -SuggestedAction 'Fix the XML and rerun validation.' `
                -ComparisonBase $comparisonBase
            continue
        }

        Test-ReswBomPreserved -Path $path -BaseBytes $baseBytes -TargetBytes $targetBytes -ComparisonBase $comparisonBase

        $reviewed = $after
        if ($reviewedHeadRevision) {
            try {
                $reviewed = Get-ParsedReswFromView -Path $path -Revision $reviewedHeadRevision
            } catch {
                Report-BlockedCheck -CheckId 'validate.resw.xml-well-formed' -File $path -Resource $null `
                    -Message $_.Exception.Message -SuggestedAction 'Fix the reviewed source XML before validating parity.' `
                    -ComparisonBase $comparisonBase
                continue
            }
        }

        $sourcePath = Get-ReswSourcePath -Path $path
        if (-not $reswGroups.ContainsKey($sourcePath)) {
            $reswGroups[$sourcePath] = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        }
        $changedResources = Get-SortedUnion -Left @(Get-ChangedReswResources -Before $before -After $after) -Right @(Get-ChangedReswResources -Before $before -After $reviewed)
        foreach ($resource in $changedResources) {
            $null = $reswGroups[$sourcePath].Add($resource)
        }
    }

    foreach ($sourcePath in @($reswGroups.Keys | Sort-Object)) {
        if ($reviewedHeadRevision) {
            Test-SourceLocalePreserved -Kind 'resw' -Path $sourcePath -ReviewedRevision $reviewedHeadRevision `
                -TargetRevision $targetViewRevision -ComparisonBase $comparisonBase
        }

        $source = $null
        try {
            $source = Get-ParsedReswFromView -Path $sourcePath -Revision $sourceAuthorityRevision
            if ($null -eq $source -and -not $reviewedHeadRevision) {
                Report-BlockedCheck -CheckId 'validate.resw.source-file' -File $sourcePath -Resource $null `
                    -Message 'The source-language .resw file is not present in the target view.' `
                    -SuggestedAction 'Restore the source-language file before validating locale parity.' `
                    -ComparisonBase $comparisonBase
                continue
            }
        } catch {
            Report-BlockedCheck -CheckId 'validate.resw.xml-well-formed' -File $sourcePath -Resource $null `
                -Message $_.Exception.Message -SuggestedAction 'Fix the source-language XML before validating locale parity.' `
                -ComparisonBase $comparisonBase
            continue
        }

        $localePaths = Get-ReswLocalePaths -SourcePath $sourcePath -Revision $targetViewRevision
        foreach ($localePath in $localePaths) {
            if ($localePath -eq $sourcePath) {
                continue
            }

            $localeCode = Get-ReswLocaleCode -Path $localePath
            $locale = $null
            try {
                    $locale = Get-ParsedReswFromView -Path $localePath -Revision $targetViewRevision
            } catch {
                Report-BlockedCheck -CheckId 'validate.resw.xml-well-formed' -File $localePath -Resource $null `
                    -Message $_.Exception.Message -SuggestedAction 'Fix the locale XML before validating parity.' `
                    -ComparisonBase $comparisonBase
                continue
            }

            foreach ($resource in @($reswGroups[$sourcePath])) {
                $sourceEntry = if ($source -and $source.Resources.ContainsKey($resource)) { $source.Resources[$resource] } else { $null }
                $localeEntry = if ($locale -and $locale.Resources.ContainsKey($resource)) { $locale.Resources[$resource] } else { $null }

                if ($null -eq $sourceEntry) {
                    if ($null -ne $localeEntry) {
                        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.resw.key-parity' `
                            -File $localePath -Resource $resource -Observed 'present' -Expected 'removed' `
                            -Message 'The localized .resw file still contains a resource removed from the source file.' `
                            -SuggestedAction 'Remove the stale localized resource.' `
                            -ComparisonBase $comparisonBase | Out-Null
                    }
                    continue
                }

                if ($null -eq $localeEntry) {
                    Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.resw.key-parity' `
                        -File $localePath -Resource $resource -Observed 'missing' -Expected 'present' `
                        -Message 'The localized .resw file is missing a resource present in the source file.' `
                        -SuggestedAction 'Add the missing localized resource entry.' `
                        -ComparisonBase $comparisonBase | Out-Null
                    continue
                }

                Test-PlaceholderParity -CheckId 'validate.resw.placeholder-parity' -File $localePath -Resource $resource `
                    -SourceValue $sourceEntry.Value -TargetValue $localeEntry.Value -ComparisonBase $comparisonBase

                $rules = Get-LockedRules -Comments @($sourceEntry.Comment) -Locale $localeCode
                Test-LockedToken -CheckId 'validate.resw.locked-token' -File $localePath -Resource $resource `
                    -Locale $localeCode -SourceValue $sourceEntry.Value -TargetValue $localeEntry.Value -Rules $rules `
                    -ComparisonBase $comparisonBase
            }
        }
    }

    if ($wtaChanged.Count -gt 0) {
        $affectedWtaKeys = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($path in $wtaChanged) {
            $baseBytes = Get-FileBytesFromView -Path $path -Revision $comparisonBase
            $targetBytes = Get-FileBytesFromView -Path $path -Revision $targetViewRevision
            if ($null -eq $targetBytes) {
                Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.file.exists' `
                    -File $path -Resource $null -Observed 'missing from target view' -Expected 'file present' `
                    -Message 'Changed WTA locale file is missing from the target view.' `
                    -SuggestedAction 'Restore the file or adjust the change set intentionally.' `
                    -ComparisonBase $comparisonBase | Out-Null
                continue
            }

            $before = $null
            if ($null -ne $baseBytes) {
                try {
                    $before = Get-ParsedWtaFromView -Path $path -Revision $comparisonBase
                } catch {
                    Report-BlockedCheck -CheckId 'validate.wta.parse' -File $path -Resource $null `
                        -Message $_.Exception.Message -SuggestedAction 'Fix the base/reference YAML before relying on deterministic validation.' `
                        -ComparisonBase $comparisonBase
                    continue
                }
            }

            $after = $null
            try {
                $after = Get-ParsedWtaFromView -Path $path -Revision $targetViewRevision
            } catch {
                Report-BlockedCheck -CheckId 'validate.wta.parse' -File $path -Resource $null `
                    -Message $_.Exception.Message -SuggestedAction 'Fix the YAML and rerun validation.' `
                    -ComparisonBase $comparisonBase
                continue
            }

            $reviewed = $after
            if ($reviewedHeadRevision) {
                try {
                    $reviewed = Get-ParsedWtaFromView -Path $path -Revision $reviewedHeadRevision
                } catch {
                    Report-BlockedCheck -CheckId 'validate.wta.parse' -File $path -Resource $null `
                        -Message $_.Exception.Message -SuggestedAction 'Fix the reviewed source YAML before validating parity.' `
                        -ComparisonBase $comparisonBase
                    continue
                }
            }

            $changedKeys = Get-SortedUnion -Left @(Get-ChangedWtaKeys -Before $before -After $after) -Right @(Get-ChangedWtaKeys -Before $before -After $reviewed)
            foreach ($resource in $changedKeys) {
                $null = $affectedWtaKeys.Add($resource)
            }
        }

        $sourceLocale = $null
        if ($reviewedHeadRevision) {
            Test-SourceLocalePreserved -Kind 'wta' -Path 'tools/wta/locales/en-US.yml' -ReviewedRevision $reviewedHeadRevision `
                -TargetRevision $targetViewRevision -ComparisonBase $comparisonBase
        }
        try {
            $sourceLocale = Get-ParsedWtaFromView -Path 'tools/wta/locales/en-US.yml' -Revision $sourceAuthorityRevision
        } catch {
            Report-BlockedCheck -CheckId 'validate.wta.parse' -File 'tools/wta/locales/en-US.yml' -Resource $null `
                -Message $_.Exception.Message -SuggestedAction 'Fix en-US.yml before validating other locales.' `
                -ComparisonBase $comparisonBase
            $sourceLocale = $null
        }

        if ($null -ne $sourceLocale) {
            foreach ($localePath in Get-WtaLocalePaths -Revision $targetViewRevision) {
                $localeCode = Get-WtaLocaleCode -Path $localePath
                if ($localeCode -eq 'en-US') {
                    continue
                }

                $locale = $null
                try {
                    $locale = Get-ParsedWtaFromView -Path $localePath -Revision $targetViewRevision
                } catch {
                    Report-BlockedCheck -CheckId 'validate.wta.parse' -File $localePath -Resource $null `
                        -Message $_.Exception.Message -SuggestedAction 'Fix this locale file before validating parity.' `
                        -ComparisonBase $comparisonBase
                    continue
                }

                foreach ($resource in @($affectedWtaKeys)) {
                    $sourceEntry = if ($sourceLocale.Entries.ContainsKey($resource)) { $sourceLocale.Entries[$resource] } else { $null }
                    $localeEntry = if ($locale.Entries.ContainsKey($resource)) { $locale.Entries[$resource] } else { $null }

                    if ($null -eq $sourceEntry) {
                        if ($null -ne $localeEntry) {
                            Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.wta.key-parity' `
                                -File $localePath -Resource $resource -Observed 'present' -Expected 'removed' `
                                -Message 'The locale file still contains a key removed from en-US.yml.' `
                                -SuggestedAction 'Remove the stale localized key.' `
                                -ComparisonBase $comparisonBase | Out-Null
                        }
                        continue
                    }

                    if ($null -eq $localeEntry) {
                        Write-LocalizationResult -Kind 'check' -Status 'FIXABLE' -Action 'FIX' -CheckId 'validate.wta.key-parity' `
                            -File $localePath -Resource $resource -Observed 'missing' -Expected 'present' `
                            -Message 'The locale file is missing a key present in en-US.yml.' `
                            -SuggestedAction 'Add the missing localized key.' `
                            -ComparisonBase $comparisonBase | Out-Null
                        continue
                    }

                    Test-PlaceholderParity -CheckId 'validate.wta.placeholder-parity' -File $localePath -Resource $resource `
                        -SourceValue $sourceEntry.Value -TargetValue $localeEntry.Value -ComparisonBase $comparisonBase

                    $rules = Get-LockedRules -Comments (Get-WtaEntryComments -Entry $sourceEntry) -Locale $localeCode
                    Test-LockedToken -CheckId 'validate.wta.locked-token' -File $localePath -Resource $resource `
                        -Locale $localeCode -SourceValue $sourceEntry.Value -TargetValue $localeEntry.Value -Rules $rules `
                        -ComparisonBase $comparisonBase

                    if ($localeCode -in @('qps-ploc', 'qps-ploca', 'qps-plocm')) {
                        Test-WtaPseudoLocale -File $localePath -Resource $resource -Locale $localeCode `
                            -SourceValue $sourceEntry.Value -TargetValue $localeEntry.Value -Rules $rules `
                            -ComparisonBase $comparisonBase
                    }
                }
            }
        }
    }

    if (@($script:ResultRecords | Where-Object { $_.status -eq 'BLOCKED' }).Count -gt 0) {
        return Complete-LocalizationRun -Status 'BLOCKED' -Action 'ESCALATE' -ShouldRun $true `
            -Message 'Deterministic validation was blocked by parse or repository uncertainty.' -ComparisonBase $comparisonBase
    }

    if (@($script:ResultRecords | Where-Object { $_.status -eq 'FIXABLE' }).Count -gt 0) {
        return Complete-LocalizationRun -Status 'FIXABLE' -Action 'FIX' -ShouldRun $true `
            -Message 'Deterministic localization issues were found.' -ComparisonBase $comparisonBase
    }

    return Complete-LocalizationRun -Status 'PASS' -Action 'NONE' -ShouldRun $false `
        -Message 'Deterministic localization validation passed.' -ComparisonBase $comparisonBase
}

function Initialize-LocalizationInvocation {
    $script:Mode = Test-LocalizationMode -Value $Mode
    $script:PullRequestNumber = Test-PullRequestNumber -Value $PullRequestNumber
    $script:BaseRevision = Test-GitObjectId -Value $BaseRevision -ParameterName 'BaseRevision'

    if ($script:Mode -eq 'Gate') {
        $script:HeadRevision = Test-GitObjectId -Value $HeadRevision -ParameterName 'HeadRevision'
        if (-not [string]::IsNullOrWhiteSpace($ReviewedHeadRevision)) {
            throw [System.ArgumentException]::new('ReviewedHeadRevision is only supported in Validate mode.')
        }
        $script:ReviewedHeadRevision = $null
    } elseif ([string]::IsNullOrWhiteSpace($HeadRevision)) {
        $script:HeadRevision = $null
    } else {
        $script:HeadRevision = Test-GitObjectId -Value $HeadRevision -ParameterName 'HeadRevision'
    }

    if ($script:Mode -eq 'Validate') {
        if ([string]::IsNullOrWhiteSpace($ReviewedHeadRevision)) {
            $script:ReviewedHeadRevision = $null
        } else {
            $script:ReviewedHeadRevision = Test-GitObjectId -Value $ReviewedHeadRevision -ParameterName 'ReviewedHeadRevision'
        }
    }
}

function Invoke-LocalizationMain {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        Initialize-LocalizationInvocation
        Assert-RepositoryRoot
        $result = if ($Mode -eq 'Gate') { Invoke-Gate } else { Invoke-Validation }
        exit $result.ExitCode
    } catch [System.ArgumentException] {
        Write-LocalizationResult -Kind 'summary' -Status 'BLOCKED' -Action 'ESCALATE' -ShouldRun $true `
            -CheckId 'input.validation' -File $null -Resource $null -Observed $null -Expected $null `
            -Message $_.Exception.Message -SuggestedAction 'Fix the invocation arguments and rerun the workflow.' `
            -ComparisonBase $null -TotalCount 0 -PassCount 0 -FixableCount 0 -BlockedCount 1 | Out-Null
        exit $script:ExitCodes.InvalidInput
    } catch {
        Write-LocalizationResult -Kind 'summary' -Status 'BLOCKED' -Action 'ESCALATE' -ShouldRun $true `
            -CheckId 'runtime.failure' -File $null -Resource $null -Observed $null -Expected $null `
            -Message $_.Exception.Message -SuggestedAction 'Escalate for manual review; deterministic validation failed unexpectedly.' `
            -ComparisonBase $null -TotalCount $script:ResultRecords.Count `
            -PassCount @($script:ResultRecords | Where-Object { $_.status -eq 'PASS' }).Count `
            -FixableCount @($script:ResultRecords | Where-Object { $_.status -eq 'FIXABLE' }).Count `
            -BlockedCount (@($script:ResultRecords | Where-Object { $_.status -eq 'BLOCKED' }).Count + 1) | Out-Null
        exit $script:ExitCodes.Blocked
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Invoke-LocalizationMain
