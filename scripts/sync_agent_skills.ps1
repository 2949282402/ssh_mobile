param(
  [ValidateSet('Check', 'SyncFromAgents')]
  [string] $Mode = 'Check'
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

function Get-SkillNames {
  param([string] $Directory)
  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    return @()
  }
  @(
    Get-ChildItem -LiteralPath $Directory -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf } |
      Select-Object -ExpandProperty Name |
      Sort-Object
  )
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

$agentsNames = @(Get-SkillNames $agentsSkillsDir)
$claudeNames = @(Get-SkillNames $claudeSkillsDir)

if ($agentsNames.Count -eq 0) {
  throw 'No canonical skills found under .agents/skills.'
}

if ($Mode -eq 'Check') {
  $nameDiff = @(Compare-Object -ReferenceObject $agentsNames -DifferenceObject $claudeNames)
  if ($nameDiff.Count -ne 0) {
    $details = ($nameDiff | ForEach-Object { "$($_.InputObject) $($_.SideIndicator)" }) -join ', '
    throw "Canonical and Claude skill sets differ: $details. Run -Mode SyncFromAgents after resolving any Claude-only orphan."
  }

  foreach ($skill in $agentsNames) {
    $agentsSkill = Join-Path $agentsSkillsDir "$skill\SKILL.md"
    $claudeSkill = Join-Path $claudeSkillsDir "$skill\SKILL.md"
    Assert-ExistingFile $agentsSkill
    Assert-ExistingFile $claudeSkill
    if ((Get-Sha256 $agentsSkill) -ne (Get-Sha256 $claudeSkill)) {
      throw "Skill '$skill' mirror differs. Run -Mode SyncFromAgents."
    }
    Write-Host "Skill '$skill' mirror is synchronized."
  }

  Write-Host 'All generated Claude skill mirrors are synchronized.'
  return
}

$claudeOnly = @($claudeNames | Where-Object { $_ -notin $agentsNames })
if ($claudeOnly.Count -ne 0) {
  throw "Refusing to overwrite Claude-only skill(s): $($claudeOnly -join ', '). Remove or migrate them explicitly first."
}

foreach ($skill in $agentsNames) {
  $agentsSkill = Join-Path $agentsSkillsDir "$skill\SKILL.md"
  $claudeSkill = Join-Path $claudeSkillsDir "$skill\SKILL.md"
  Copy-Skill -From $agentsSkill -To $claudeSkill
  Write-Host "Generated Claude mirror for '$skill'."
}

Write-Host 'Generated all Claude skill mirrors from canonical .agents sources.'
