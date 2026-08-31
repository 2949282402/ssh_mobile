# Full-test option helpers. Dot-sourced by full_test.ps1.

function Env([string]$Name,[string]$Default){$value=[Environment]::GetEnvironmentVariable($Name);if($value){$value}else{$Default}}
