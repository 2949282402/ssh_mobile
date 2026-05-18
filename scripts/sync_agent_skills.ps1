param(
  [ValidateSet('Check', 'Link', 'CopyFromAgents', 'CopyFromClaude')]
  [string] $Mode = 'Check',

  [switch] $Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$agentsSkill = Join-Path $repoRoot '.agents\skills\ssh-mobile-maintenance\SKILL.md'
$claudeSkill = Join-Path $repoRoot '.claude\skills\ssh-mobile-maintenance\SKILL.md'

function Assert-InRepo {
  param([string] $Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetFullPath($repoRoot)
  if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to operate outside repository: $fullPath"
  }
}

function Assert-ExistingFile {
  param([string] $Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing file: $Path"
  }
}

function Get-Sha256 {
  param([string] $Path)
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Copy-Skill {
  param(
    [string] $From,
    [string] $To
  )
  Assert-InRepo $From
  Assert-InRepo $To
  Assert-ExistingFile $From
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To) | Out-Null
  Copy-Item -LiteralPath $From -Destination $To -Force
}

Assert-InRepo $agentsSkill
Assert-InRepo $claudeSkill

switch ($Mode) {
  'Check' {
    Assert-ExistingFile $agentsSkill
    Assert-ExistingFile $claudeSkill
    $agentsHash = Get-Sha256 $agentsSkill
    $claudeHash = Get-Sha256 $claudeSkill
    if ($agentsHash -ne $claudeHash) {
      throw "Skill files differ. Run with -Mode CopyFromAgents, -Mode CopyFromClaude, or -Mode Link -Force."
    }
    Write-Host 'Codex and Claude skill files are synchronized.'
  }

  'Link' {
    Assert-ExistingFile $agentsSkill
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claudeSkill) | Out-Null
    if (Test-Path -LiteralPath $claudeSkill -PathType Leaf) {
      if (-not $Force -and ((Get-Sha256 $agentsSkill) -ne (Get-Sha256 $claudeSkill))) {
        throw "Claude skill differs. Re-run with -Force to replace it with a hard link to the Codex skill."
      }
      Remove-Item -LiteralPath $claudeSkill -Force
    }
    try {
      New-Item -ItemType HardLink -Path $claudeSkill -Target $agentsSkill | Out-Null
      Write-Host 'Created hard link from Claude skill to Codex skill.'
    } catch {
      Copy-Skill -From $agentsSkill -To $claudeSkill
      Write-Warning "Hard link failed; copied the skill instead. Details: $($_.Exception.Message)"
    }
  }

  'CopyFromAgents' {
    Copy-Skill -From $agentsSkill -To $claudeSkill
    Write-Host 'Copied Codex skill to Claude skill.'
  }

  'CopyFromClaude' {
    Copy-Skill -From $claudeSkill -To $agentsSkill
    Write-Host 'Copied Claude skill to Codex skill.'
  }
}
