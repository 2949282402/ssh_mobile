# Full-test scheduling and reporting helpers. Dot-sourced by full_test.ps1.

function Dispatch([string]$Name){switch -Regex ($Name){'^bootstrap$'{JobBootstrap};'^front-quality$'{JobFront};'^admin-api-contract$'{JobAdmin};'^telemetry-contract$'{JobTelemetry};'^native-network-quality$'{JobNative};'^sdk-dart-quality$'{JobSdk};'^lan-network-v2-targeted$'{JobLanNetworkV2};'^relay-quality$'{JobRelay};'^protocol-v2-contract$'{JobProtocol};'^architecture-check$'{JobArchitecture};'^app-static-quality$'{JobAppStatic};'^workspace-core-quality$'{JobCore};'^workspace-features-quality$'{JobFeatures};'^app-unit-shard-([0-3])$'{JobApp ([int]$Matches[1])};'^app-coverage$'{JobCoverage};'^android-build$'{JobAndroid};'^windows-build$'{JobWindows};'^terminal-smoke-build$'{JobTerminal};'^client-backend-smoke$'{JobE2E};default{throw"Unknown job $Name"}}}

$requested=[string[]]@()
if($Only){$requested=[string[]]@($Only.Split(',')|Where-Object{$_})}
function Wanted([string]$Name){$requested.Count-eq0-or$Name-in$requested}
$results=@{};$durations=@{};$selected=[Collections.Generic.List[string]]::new();$start=Get-Date
function StartJob([string]$Name){
  $processInfo=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$processInfo.UseShellExecute=$false
  foreach($argument in @('-NoProfile','-File',$FullTestScriptPath,'-InternalJob',$Name,'-RunId',$RunId,'-LogDir',$LogDir,'-Jobs',"$Jobs",'-FlutterConcurrency',"$FlutterConcurrency",'-MelosConcurrency',"$MelosConcurrency",'-MelosTestConcurrency',"$MelosTestConcurrency",'-AppTimeout',$AppTimeout,'-AppShards',"$AppShards",'-WorkspaceTestTimeout',$WorkspaceTestTimeout,'-TempRoot',$temp)){$processInfo.ArgumentList.Add($argument)}
  if($coverage){$processInfo.ArgumentList.Add('-WithCoverage')}else{$processInfo.ArgumentList.Add('-NoCoverage')};if($WithFeatureLoopback){$processInfo.ArgumentList.Add('-WithFeatureLoopback')};if($NoDocker){$processInfo.ArgumentList.Add('-NoDocker')}
  $processInfo.RedirectStandardOutput=$true;$processInfo.RedirectStandardError=$true;$process=[Diagnostics.Process]::new();$process.StartInfo=$processInfo;$process.Start()|Out-Null;$selected.Add($Name);Write-Host "[RUN ] $Name"
  @{Name=$Name;Process=$process;Started=Get-Date;Out=$process.StandardOutput.ReadToEndAsync();Err=$process.StandardError.ReadToEndAsync()}
}
function Complete($Job){$Job.Process.WaitForExit();$output=$Job.Out.Result+$Job.Err.Result;$status=$Job.Process.ExitCode;$duration=[int]((Get-Date)-$Job.Started).TotalSeconds;$results[$Job.Name]=$status;$durations[$Job.Name]=$duration;$output|Set-Content (Join-Path $LogDir "$($Job.Name).log") -Encoding utf8NoBOM;if($status-eq0){Write-Host "[PASS] $($Job.Name) (${duration}s)"}elseif($status-eq$gap){Write-Host "[GAP ] $($Job.Name)";$output|Write-Host}else{Write-Host "[FAIL] $($Job.Name)";$output|Write-Host};$Job.Process.Dispose()}
function Batch([string[]]$Names,[int]$Limit=$Jobs){$queue=[Collections.Generic.Queue[string]]::new();foreach($name in $Names){if(Wanted $name){$queue.Enqueue($name)}};$active=[Collections.Generic.List[object]]::new();while($queue.Count-or$active.Count){while($queue.Count-and$active.Count-lt$Limit){$active.Add((StartJob $queue.Dequeue()))};$done=$active|Where-Object{$_.Process.HasExited}|Select-Object -First 1;if($null-eq$done){Start-Sleep -Milliseconds 200}else{Complete $done;$active.Remove($done)}}}

function Invoke-FullTest {
  Write-Host "SSH Mobile native Windows CI`nroot: $root`nlogs: $LogDir"
  if(-not$NoBootstrap){Batch @('bootstrap') 1}
  Batch @('front-quality','admin-api-contract','telemetry-contract','native-network-quality','sdk-dart-quality','lan-network-v2-targeted','relay-quality','protocol-v2-contract','architecture-check','app-static-quality')
  if($WithClientBackendSmoke){Batch @('client-backend-smoke') 1}
  Batch @('workspace-core-quality') 1;Batch @('workspace-features-quality') 1
  $appJobs=@(0..($AppShards-1)|ForEach-Object{"app-unit-shard-$_"});Batch $appJobs $(if($parallelShards){$Jobs}else{1})
  Batch @('android-build') 1;Batch @('windows-build') 1;Batch @('terminal-smoke-build') 1
  if($coverage-and@($appJobs|Where-Object{$results[$_]-ne0}).Count-eq0){Batch @('app-coverage') 1}
  Write-Host "`nFinal summary:"
  foreach($name in $selected){Write-Host("  {0} {1} ({2}s)"-f$(if($results[$name]-eq0){'PASS'}elseif($results[$name]-eq$gap){'GAP '}else{'FAIL'}),$name,$durations[$name])}
  Write-Host "Total: $([int]((Get-Date)-$start).TotalSeconds)s"
  if(@($results.Values|Where-Object{$_-ne0-and$_-ne$gap}).Count){exit 1}
  if(@($results.Values|Where-Object{$_-eq$gap}).Count){exit 2}
}
