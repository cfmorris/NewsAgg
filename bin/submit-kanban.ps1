[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
    [Parameter(Mandatory)][string]$TaskFile,
    [ValidateSet('implement', 'review', 'debug')][string]$Mode = 'implement',
    [string]$Ref = 'origin/main'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$spec = Get-Content -LiteralPath $TaskFile -Raw
if ([string]::IsNullOrWhiteSpace($spec)) { throw 'The task file must describe the expected behavior.' }

$commit = git -C $repo rev-parse --verify --end-of-options "$Ref^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Cannot resolve Git ref $Ref." }
$taskKey = [guid]::NewGuid().ToString('N')
$branch = "codex/newsagg-$taskKey"
$profile = 'newsagg'
$instructions = switch ($Mode) {
    'implement' { 'Implement the scoped change. For bugs, first run a failing regression test, then run it again after the fix. Prefer integration coverage. Commit the result locally and report the commit and test results.' }
    'review' { 'Review read-only. Report actionable findings with file and line references, or say no findings. The task brief must identify the diff or base to review.' }
    'debug' {
        $profile = 'newsaggdebug'
        'Investigate the failure and report the cause and evidence. For any fix, first run a failing regression test, then verify it passes. Commit the fix locally and report the commit and test results.'
    }
}

$body = [IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $body -Encoding utf8 -Value @"
$instructions
Keep tests focused on behavior. Do not test configuration or fixture data.
Do not push or merge. Report a blocker if the task cannot be completed.

Task brief:
$spec
"@
    git -C $repo branch $branch $commit
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the task branch.' }
    hermes kanban --board newsagg create --assignee $profile --body-file $body `
        --workspace "worktree:$repo" --branch $branch --max-retries 1 --max-runtime 20m `
        --completion-contract local-only --json -- $Title
    if ($LASTEXITCODE -ne 0) { throw "Card creation failed. The prepared branch is $branch." }
} finally {
    Remove-Item -LiteralPath $body
}

# Token usage is recorded locally only: tmp/usage/ledger.jsonl plus a comment on the
# card in the board's own SQLite. Nothing is posted to GitHub. Best effort — a missing
# Python or an unreadable card must never fail the submission.
try {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        & $python.Source (Join-Path $PSScriptRoot 'kanban-usage.py') --sweep --board newsagg `
            --ledger (Join-Path $repo 'tmp/usage/ledger.jsonl') --kanban-comment | Out-Host
    } else {
        Write-Warning 'python not found; skipping local usage recording.'
    }
} catch {
    Write-Warning "Usage recording skipped: $($_.Exception.Message)"
}
