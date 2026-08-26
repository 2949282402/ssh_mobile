$t = 'gYw'
$foregrounds = @('    m','   1m','  30m','1;30m','  31m','1;31m','  32m','1;32m','  33m','1;33m','  34m','1;34m','  35m','1;35m','  36m','1;36m','  37m','1;37m')
$backgrounds = @('40m','41m','42m','43m','44m','45m','46m','47m','100m','101m','102m','103m','104m','105m','106m','107m')
Write-Host "`n                 $($backgrounds -join '     ')"
foreach ($foreground in $foregrounds) {
  $row = " $foreground "
  foreach ($background in $backgrounds) {
    $row += "`e[$foreground`e[$background  $t  `e[0m"
  }
  Write-Host $row
}
Write-Host
