# comfy.ps1 — ComfyUI one-click launcher (Windows / PowerShell)

A single-script launcher for the local ComfyUI install at `C:\Users\rryo\ComfyUI`.
Each run performs the full cycle: **update dependencies → verify GPU torch → free the port → launch the server**, with reliable Ctrl+C shutdown.

Designed for **Windows PowerShell 5.1** (the built-in `powershell.exe` — `pwsh` is not required, but the script works there too).

---

## Requirements

| Component | Detail |
|---|---|
| ComfyUI | git checkout at `C:\Users\rryo\ComfyUI` with a uv-managed venv in `.venv` |
| uv | package manager, on PATH (used instead of pip) |
| git | on PATH |
| GPU | NVIDIA (Blackwell-era), wheels from the **CUDA 13.0** index |
| Port | `8188` (default ComfyUI port) |

## Usage

```powershell
PS C:\Users\rryo> .\comfy.ps1
```

The server starts at `http://127.0.0.1:8188`. Press **Ctrl+C** in the launcher window to stop it.

## What one run does

1. **Pre-flight** — verifies `ComfyRoot`, venv `python.exe`, `main.py`, `git`, `uv` exist. Anything missing → red `[FATAL]` + `pause`, exit 1.
2. **`git pull`** — updates ComfyUI. Non-fatal: on failure it warns and continues with local files.
3. **Torch first, from the hardcoded CUDA index** —
   `uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130`
   The order is deliberate: `requirements.txt` lists `torch` unpinned, so if requirements were installed first, PyPI would pull the **CPU build** on top. If this step fails, requirements installs are **skipped** entirely (same guard) and the script still launches, warning loudly.
4. **Remaining dependencies** — `uv pip install -r requirements.txt`, then `-r manager_requirements.txt` (built-in manager, `--enable-manager`).
5. **Sanity check** — runs `import torch; print(version, cuda.is_available())` in the venv and requires a version containing `+cu` **and** `True`. Failure prints a red banner but launches anyway (so you see the error in ComfyUI itself).
6. **`uv cache prune`** — runs *after* installs so a matching cached wheel is reused before prune sweeps unlinked versions. Keeps the uv cache from ballooning with old torch builds.
7. **Port cleanup** — anything holding port 8188 (typically a leftover ComfyUI python) is force-terminated before launch.
8. **Launch** — starts `.venv\Scripts\python.exe main.py --enable-manager --highvram` with the working directory set to the ComfyUI root (custom_nodes/models resolve relative to it), then waits in an interruptible poll loop.

## Stopping: why Ctrl+C now works

Two Windows-specific problems previously made Ctrl+C leave a zombie python holding port 8188:

- **ComfyUI ignores the console Ctrl+C on Windows.** Its main thread parks in the asyncio Proactor event loop; when idle, that IOCP wait never returns, so the SIGINT flag is set but `KeyboardInterrupt` is never raised. The process only dies to a hard `TerminateProcess`.
- **The old `$proc.WaitForExit()` was uninterruptible.** PowerShell 5.1 returns the prompt on Ctrl+C but cannot run the script's `finally` block (with the kill) until that .NET call returns — which it never did.

The script therefore:

- polls with `while (-not $proc.HasExited) { Start-Sleep -Milliseconds 250 }` — `Start-Sleep` *is* interruptible, so the stop is processed within ~250 ms;
- in `finally`, kills **first, prints after**: `.Kill()` → `Stop-Process -Force` → `taskkill /PID n /T /F` (tree fallback), each in its own `try/catch`.

Expected output on Ctrl+C:

```
[Shutdown] Stop signal received. ComfyUI (PID 12345) terminated.
[ComfyUI stopped by user]
```

Afterwards `Get-NetTCPConnection -LocalPort 8188` should return nothing.

## Exit codes

When ComfyUI exits on its own (not via Ctrl+C), the script classifies `$ComfyProcess.ExitCode`
(`$LASTEXITCODE` is useless here — `Process.Start` never sets it):

| Exit code | Meaning | Script behavior |
|---|---|---|
| `0` | clean exit | green notice |
| `3221225786` / `-1073741510` | STATUS_CONTROL_C_EXIT (Ctrl+C, unsigned/signed) | green notice |
| `-1` | terminated via `Process.Kill()` | green notice |
| `130` | SIGINT (128+2, POSIX convention) | green notice |
| `1` | terminated via `taskkill /F` | green notice |
| anything else | crash | red `[CRASH]` banner + `pause` so the window doesn't close |

## Configuration

Everything tweakable sits in the `CONFIG` block at the top of the script:

```powershell
$ComfyRoot      = "C:\Users\rryo\ComfyUI"
$VenvPython     = Join-Path $ComfyRoot ".venv\Scripts\python.exe"
$TorchIndex     = "https://download.pytorch.org/whl/cu130"
$Port           = 8188
$LaunchArgs     = @("main.py", "--enable-manager", "--highvram")
```

## Hard rules (do not break these)

- **Never use `uv sync`** — ComfyUI's `pyproject.toml` has no dependencies section; a sync once wiped the venv empty. Only `uv pip install` is safe.
- **Never drop the hardcoded `--index-url`** for torch, and never `--torch-backend=auto` — either lets PyPI resolve a CPU torch build.
- **Keep prune after installs** — running `uv cache prune` before/without installing can discard still-reusable cached wheels.
- **Don't replace the poll loop with `WaitForExit()`** — that regression is exactly the Ctrl+C zombie bug described above.

## Known harmless noise

- The torch sanity check may print a red `FutureWarning` block about `pynvml` being deprecated — it's stderr noise from `import torch`, not an error; the check itself still passes (`2.14.0+cu130 True`).
