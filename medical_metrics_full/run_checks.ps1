# Run the software golden model checks from this package.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = $env:PYTHON
if (-not $py) {
    $candidate = "C:\Users\13995\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    if (Test-Path -LiteralPath $candidate) { $py = $candidate } else { $py = "python" }
}

Push-Location (Join-Path $root "python")
try {
    & $py -m unittest -v test_golden_metrics.py test_rtl_model.py
    & $py golden_metrics.py `
        --patient-dir "C:\Users\13995\Desktop\fpga校赛\CAMUS_public\database_nifti\patient0001" `
        --registration-frames 6 `
        --out patient0001_metrics.json
}
finally {
    Pop-Location
}