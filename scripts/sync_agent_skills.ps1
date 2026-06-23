param(
  [ValidateSet('Check', 'Link', 'CopyFromAgents', 'CopyFromClaude')]
  [string] $Mode = 'Check',

  [switch] $Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$agentsSkillsDir = Join-Path $repoRoot '.agents\skills'
$claudeSkillsDir = Join-Path $repoRoot '.claude\skills'

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

# Collect all unique skill names from both directories
$skillNames = @()
if (Test-Path -LiteralPath $agentsSkillsDir -PathType Container) {
  $skillNames += Get-ChildItem -LiteralPath $agentsSkillsDir -Directory | Select-Object -ExpandProperty Name
}
if (Test-Path -LiteralPath $claudeSkillsDir -PathType Container) {
  $skillNames += Get-ChildItem -LiteralPath $claudeSkillsDir -Directory | Select-Object -ExpandProperty Name
}
$skillNames = $skillNames | Sort-Object -Unique

if ($skillNames.Count -eq 0) {
  Write-Host "No agent skills found to synchronize."
  return
}

foreach ($skill in $skillNames) {
  $agentsSkill = Join-Path $agentsSkillsDir "$skill\SKILL.md"
  $claudeSkill = Join-Path $claudeSkillsDir "$skill\SKILL.md"

  Write-Host "Processing skill: $skill"

  switch ($Mode) {
    'Check' {
      Assert-ExistingFile $agentsSkill
      Assert-ExistingFile $claudeSkill
      $agentsHash = Get-Sha256 $agentsSkill
      $claudeHash = Get-Sha256 $claudeSkill
      if ($agentsHash -ne $claudeHash) {
        throw "Skill '$skill' files differ. Run with -Mode CopyFromAgents, -Mode CopyFromClaude, or -Mode Link -Force."
      }
      Write-Host "  - Skill '$skill' files are synchronized."
    }

    'Link' {
      Assert-ExistingFile $agentsSkill
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claudeSkill) | Out-Null
      if (Test-Path -LiteralPath $claudeSkill -PathType Leaf) {
        if (-not $Force -and ((Get-Sha256 $agentsSkill) -ne (Get-Sha256 $claudeSkill))) {
          throw "Claude skill '$skill' differs. Re-run with -Force to replace it with a hard link to the Codex skill."
        }
        Remove-Item -LiteralPath $claudeSkill -Force
      }
      try {
        New-Item -ItemType HardLink -Path $claudeSkill -Target $agentsSkill | Out-Null
        Write-Host "  - Created hard link for '$skill'."
      } catch {
        Copy-Skill -From $agentsSkill -To $claudeSkill
        Write-Warning "  - Hard link failed for '$skill'; copied instead. Details: $($_.Exception.Message)"
      }
    }

    'CopyFromAgents' {
      if (Test-Path -LiteralPath $agentsSkill -PathType Leaf) {
        Copy-Skill -From $agentsSkill -To $claudeSkill
        Write-Host "  - Copied Codex skill '$skill' to Claude skill."
      } else {
        Write-Warning "  - Codex skill '$skill' does not exist; skipping copy."
      }
    }

    'CopyFromClaude' {
      if (Test-Path -LiteralPath $claudeSkill -PathType Leaf) {
        Copy-Skill -From $claudeSkill -To $agentsSkill
        Write-Host "  - Copied Claude skill '$skill' to Codex skill."
      } else {
        Write-Warning "  - Claude skill '$skill' does not exist; skipping copy."
      }
    }
  }
}

Write-Host "Synchronization complete for all skills in $Mode mode."
