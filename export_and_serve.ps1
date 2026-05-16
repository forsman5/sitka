# Adjust this path if needed.
$GODOT = "C:\Users\jrfor\OneDrive\Desktop\gamedev\Godot_v4.6.2-stable_win64_console.exe"

$EXPORT_DIR = "exports\web"
$PORT = 3000

# Ensure export directory exists
New-Item -ItemType Directory -Force -Path $EXPORT_DIR | Out-Null

# Export
Write-Host "Exporting project (release)..." -ForegroundColor Cyan
& $GODOT --headless --export-release "Web" "$EXPORT_DIR\index.html"
if (-not (Test-Path "$EXPORT_DIR\index.html")) {
    Write-Host "Export failed - index.html not found. Check the 'Web' export preset in Godot." -ForegroundColor Red
    exit 1
}
Write-Host "Export complete." -ForegroundColor Green

# Kill anything already on the port
$conn = netstat -ano | Select-String ":$PORT\s.*LISTENING"
if ($conn) {
    $existingPid = ($conn.ToString().Trim() -split '\s+')[-1]
    Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped existing server on port $PORT."
}

# Start server (blocking - Ctrl+C to stop)
Write-Host "Starting server..." -ForegroundColor Cyan
python serve.py
