# Shared command and process helpers. Dot-sourced by full_test.ps1.

function Need([string[]]$Names){foreach($name in $Names){if(-not(Get-Command $name -ErrorAction SilentlyContinue)){Write-Host "ENVIRONMENT GAP: required command unavailable: $name";return$false}};$true}
function Cmd([string]$Command,[string[]]$Arguments,[string]$Directory=$root,[hashtable]$Environment=@{}){Invoke-CommandChecked $Command $Arguments $Directory $Environment}
function Script([string]$Path,[hashtable]$Parameters=@{}){
  $global:LASTEXITCODE=0
  & $Path @Parameters
  $status=$LASTEXITCODE
  if($status-eq$gap){exit$gap}
  if($status-ne0){throw "$Path exited with code $status."}
}
function Melos([string]$Command,[string[]]$Scopes){$arguments=@('run','melos','exec','--concurrency',"$MelosConcurrency",'--fail-fast');foreach($scope in $Scopes){$arguments+="--scope=$scope"};$arguments+=@('--',$Command);Cmd dart $arguments}
