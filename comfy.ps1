$ErrorActionPreference = 'Stop'

# ---------------------------- CONFIG ----------------------------
$ComfyRoot      = "C:\Users\rryo\ComfyUI"
$VenvPython     = Join-Path $ComfyRoot ".venv\Scripts\python.exe"
$MainPy         = "main.py"
$TorchIndex     = "https://download.pytorch.org/whl/cu130"   # hardcoded: never let requirements.txt pull CPU torch from PyPI
$Port           = 8188
$LaunchArgs     = @($MainPy, "--enable-manager", "--highvram")
$CtrlCExitCodes = @(3221225786, -1073741510, -1, 130, 1)  # STATUS_CONTROL_C_EXIT (unsigned/signed), -1, SIGINT, taskkill /F

# -------------------------- PRE-FLIGHT --------------------------
$Fatal = $null
if (-not (Test-Path $ComfyRoot))                                { $Fatal = "ComfyUI directory not found: $ComfyRoot" }
elseif (-not (Test-Path $VenvPython))                           { $Fatal = "venv python not found: $VenvPython" }
elseif (-not (Test-Path (Join-Path $ComfyRoot $MainPy)))        { $Fatal = "$MainPy not found in $ComfyRoot" }
elseif (-not (Get-Command git -ErrorAction SilentlyContinue))   { $Fatal = "git not found in PATH" }
elseif (-not (Get-Command uv -ErrorAction SilentlyContinue))    { $Fatal = "uv not found in PATH" }

if ($Fatal) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  [FATAL] $Fatal" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    pause
    exit 1
}

# Move into ComfyUI so git/uv/python all resolve the local context
# (uv pip targets the .venv found in the current directory)
Push-Location $ComfyRoot

$Global:ComfyProcess = $null
$TorchOK = $false

try {
    # ---------------- UPDATE PHASE ----------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Checking for Updates" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # 1) git pull (non-fatal: proceed with local files on failure)
    Write-Host "-> Pulling latest changes from GitHub..." -ForegroundColor Gray
    git pull
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARNING] git pull failed (exit $LASTEXITCODE). Proceeding with local files..." -ForegroundColor Yellow
    }

    # 2) torch FIRST, CUDA index hardcoded -- so the unpinned 'torch' line in
    #    requirements.txt resolves against installed CUDA torch, not PyPI's CPU build.
    #    (Never 'uv sync' here: pyproject.toml has no dependencies section, sync empties the venv.)
    Write-Host "-> Installing torch stack from $TorchIndex ..." -ForegroundColor Gray
    uv pip install torch torchvision torchaudio --index-url $TorchIndex
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "[ERROR] torch/torchvision/torchaudio install FAILED (exit $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "[ERROR] Skipping requirements.txt so PyPI cannot pull a CPU torch build on top." -ForegroundColor Red
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        $TorchOK = $false
    } else {
        $TorchOK = $true
    }

    # 3) remaining dependencies
    if ($TorchOK) {
        if (Test-Path "requirements.txt") {
            Write-Host "-> Updating dependencies (requirements.txt)..." -ForegroundColor Gray
            uv pip install -r requirements.txt
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[WARNING] requirements.txt install failed (exit $LASTEXITCODE). Continuing..." -ForegroundColor Yellow
            }

            if (Test-Path "manager_requirements.txt") {
                Write-Host "-> Updating manager dependencies (manager_requirements.txt)..." -ForegroundColor Gray
                uv pip install -r manager_requirements.txt
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[WARNING] manager_requirements install failed (exit $LASTEXITCODE). Continuing..." -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "[WARNING] requirements.txt not found. Skipping dependency update." -ForegroundColor Yellow
        }
    }

    # 4) sanity check: CUDA build actually present and visible?
    Write-Host ""
    Write-Host "-> Sanity check: torch build / CUDA availability..." -ForegroundColor Gray
    $SanityCode = 'import torch; print(torch.__version__, torch.cuda.is_available())'
    $PrevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # PS5.1: stderr captured via 2>&1 would otherwise become a terminating error
    try {
        $SanityOutput = (& $VenvPython -c $SanityCode 2>&1 | Out-String).Trim()
        $SanityExit   = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PrevEAP
    }

    if ($SanityExit -eq 0 -and $SanityOutput -match '\+cu' -and $SanityOutput -match 'True') {
        Write-Host "[OK] torch $SanityOutput" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "########################################################" -ForegroundColor Red
        Write-Host "#  [WARNING] TORCH SANITY CHECK FAILED" -ForegroundColor Red
        Write-Host "#  Expected : version ending in '+cuXXX' and 'cuda=True'" -ForegroundColor Red
        Write-Host "#  Got      : $SanityOutput" -ForegroundColor Red
        Write-Host "#  (exit code: $SanityExit)" -ForegroundColor Red
        Write-Host "#  Launching anyway -- expect CPU-only mode or import errors." -ForegroundColor Red
        Write-Host "########################################################" -ForegroundColor Red
    }

    # 5) prune stale versions out of the uv cache (old torch builds pile up fast)
    Write-Host "-> Pruning uv cache (removes no-longer-used package versions)..." -ForegroundColor Gray
    uv cache prune
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARNING] uv cache prune failed (exit $LASTEXITCODE). Cache may keep growing." -ForegroundColor Yellow
    }

    # ---------------- LAUNCH PHASE ----------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  ComfyUI Launcher" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Directory : $ComfyRoot"
    Write-Host "  Arguments :" -NoNewline
    Write-Host " $($LaunchArgs[1..($LaunchArgs.Length-1)] -join ' ')" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # free the port: kill whatever occupies it (skip PID 0 / system idle entries)
    $ConflictPIDs = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        Where-Object { $_ -gt 0 }

    if ($ConflictPIDs) {
        foreach ($ConflictPID in $ConflictPIDs) {
            $ProcName = (Get-Process -Id $ConflictPID -ErrorAction SilentlyContinue).Name
            Write-Host "[Cleanup] Port $Port is in use by $ProcName (PID $ConflictPID). Terminating..." -ForegroundColor Yellow
            Stop-Process -Id $ConflictPID -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 800   # give the OS a moment to release the port
    } else {
        Write-Host "[Cleanup] Port $Port is clear. Ready for takeoff." -ForegroundColor Gray
    }
    Write-Host ""

    # launch detached from PowerShell's pipeline so Ctrl+C handling stays ours
    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName         = $VenvPython
    $ProcessInfo.Arguments        = ($LaunchArgs -join ' ')
    $ProcessInfo.WorkingDirectory = $ComfyRoot   # backend resolves custom_nodes/models relative to here
    $ProcessInfo.UseShellExecute  = $false

    $Global:ComfyProcess = [System.Diagnostics.Process]::Start($ProcessInfo)
    Write-Host "[Launched] ComfyUI is running (PID $($Global:ComfyProcess.Id)). Press Ctrl+C here to stop it." -ForegroundColor Green

    # Poll instead of WaitForExit(): Start-Sleep IS interruptible by Ctrl+C
    # (the old blocking WaitForExit() call was not -> finally/kill never ran).
    while (-not $Global:ComfyProcess.HasExited) {
        Start-Sleep -Milliseconds 250
    }
}
catch {
    Write-Host ""
    Write-Host "[ERROR] Launcher hit an unexpected error:" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    # Ctrl+C path: KILL FIRST, print after. ComfyUI ignores the console
    # SIGINT on Windows (ProactorEventLoop), so TerminateProcess is the
    # only reliable stop -- do not wait for a graceful exit.
    if ($Global:ComfyProcess -and -not $Global:ComfyProcess.HasExited) {
        try { $Global:ComfyProcess.Kill() } catch { }
        try { Stop-Process -Id $Global:ComfyProcess.Id -Force -ErrorAction SilentlyContinue } catch { }
        # tree-kill fallback in case a child survived the two kills above
        try { taskkill /PID $Global:ComfyProcess.Id /T /F 2>$null | Out-Null } catch { }
        try { $Global:ComfyProcess.WaitForExit(5000) | Out-Null } catch { }
        try {
            Write-Host ""
            Write-Host "[Shutdown] Stop signal received. ComfyUI (PID $($Global:ComfyProcess.Id)) terminated." -ForegroundColor Yellow
            Write-Host "[ComfyUI stopped by user]" -ForegroundColor Green
        } catch { }
    }
    elseif ($Global:ComfyProcess) {
        # process exited on its own -> classify using ITS exit code
        # (Process.Start/WaitForExit never set $LASTEXITCODE, so that variable is useless here)
        $FinalExitCode = $Global:ComfyProcess.ExitCode
        if ($FinalExitCode -eq 0 -or $FinalExitCode -in $CtrlCExitCodes) {
            Write-Host ""
            Write-Host "[ComfyUI exited cleanly (exit code $FinalExitCode)]" -ForegroundColor Green
        }
        else {
            Write-Host ""
            Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
            Write-Host "[CRASH] ComfyUI exited with code $FinalExitCode" -ForegroundColor Red
            Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
            pause
        }
    }
    else {
        # launch never happened (update phase or process start failed)
        Write-Host ""
        Write-Host "[ABORTED] ComfyUI was not launched (see errors above)." -ForegroundColor Red
        pause
    }

    # always restore original directory context
    Pop-Location
}
