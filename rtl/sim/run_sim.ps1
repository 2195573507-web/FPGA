$ErrorActionPreference='Stop'
$OCS='D:\FPGA\_tmp\ocs\oss-cad-suite'
$env:Path="$OCS\bin;$OCS\lib;"+$env:Path
$VEC='D:\FPGA\_tmp\rtlvec'
$SIM='D:\FPGA\rtl\sim'
& "$OCS\bin\iverilog.exe" -g2012 -o "$SIM\tb.vvp" "$SIM\tb_tile_decoder.v" 'D:\FPGA\rtl\tile_decoder.v'
if ($LASTEXITCODE -ne 0) { 'COMPILE FAILED'; exit 1 }
'compile ok'
Set-Location $VEC
$pass=0; $fail=0; $failed=@()
foreach ($line in Get-Content "$VEC\manifest.txt") {
  if (-not $line.Trim()) { continue }
  $f = -split $line
  $p=$f[0]; $nb=$f[1]; $ns=$f[2]; $k=$f[3]; $q=$f[4]; $m=$f[5]; $w=$f[6]; $r=$f[7]
  $out = & "$OCS\bin\vvp.exe" "$SIM\tb.vvp" "+PFX=$p" "+NB=$nb" "+NS=$ns" "+K=$k" "+Q=$q" "+M=$m" "+W=$w" "+R=$r" 2>&1
  $txt = $out -join "`n"
  $lines = $out | Select-String -Pattern 'PASS|FAIL|MISMATCH|ERROR' | ForEach-Object { $_.Line }
  $lines | ForEach-Object { $_ }
  if ($txt -match 'PASS') { $pass++ } else { $fail++; $failed += $p }
}
"==============================="
"TOTAL: $pass passed, $fail failed"
if ($fail -gt 0) { "FAILED: " + ($failed -join ', ') }
