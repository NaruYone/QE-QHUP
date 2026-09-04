# LUCID PPSI Viewer

MATLAB viewer for real-time parallel phase-shifting interferometry (PPSI) with
a LUCID polarization camera. A small C# bridge acquires four polarization
components through ArenaNET and publishes the newest frame through Windows
shared memory. MATLAB displays the four-component hologram, amplitude, and
wrapped phase.

## Reconstruction

For the four intensity components `I0`, `I45`, `I90`, and `I135`, the complex
field is reconstructed as

```text
E = ((I90 - I0) + i (I135 - I45)) / 4
```

The viewer displays:

- captured component image: `[I0 I45; I90 I135]`
- amplitude: `abs(E)`
- wrapped phase: `angle(E)` in radians

The image payload is transferred through the Windows shared-memory object
`Local\RealtimePPSI_Frame`. Image data is not exchanged through disk files.

## Requirements

- Windows 10 or Windows 11
- MATLAB R2023b or a compatible release with .NET support
- LUCID polarization camera supporting
  `PolarizedAngles_0d_45d_90d_135d_Mono8`
- LUCID Arena SDK with ArenaNET for .NET Framework
- 32-bit Arena SDK runtime (`Win32Release`) for the supplied build settings
- Network settings that allow ArenaView to detect the camera

Arena SDK binaries are not included in this repository. Install the SDK from
LUCID Vision Labs and observe its license terms.

## Repository layout

```text
.
|-- lucid_ppsi_viewer.m
|-- src/
|   |-- ArenaLatestFrameWriter.cs
|   `-- PpsiSharedMemoryReader.cs
|-- scripts/
|   |-- Build.ps1
|   |-- Check-LucidPpsiViewer.ps1
|   `-- Start-LucidPpsiViewer.ps1
|-- README.md
|-- LICENSE
`-- .gitignore
```

## Deployment

### 1. Install and test Arena SDK

Install LUCID Arena SDK and its network driver. Connect the camera, open
ArenaView, and verify that live acquisition works. Close ArenaView before
starting this viewer because only one process can control the camera.

### 2. Obtain `ArenaNET_v140.dll`

Locate the ArenaNET assembly supplied with the matching Arena SDK/ArenaNET
installation. The assembly version and the native Arena runtime must match.

### 3. Build the bridge

Open Windows PowerShell in the repository root. If script execution is blocked,
enable it for the current PowerShell process only:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

Run the build script and provide the actual ArenaNET assembly path:

```powershell
.\scripts\Build.ps1 `
  -ArenaNetDll 'C:\path\to\ArenaNET_v140.dll'
```

The default native runtime location is:

```text
C:\Program Files\Lucid Vision Labs\Arena SDK\Win32Release
```

Specify another location when necessary:

```powershell
.\scripts\Build.ps1 `
  -ArenaNetDll 'C:\path\to\ArenaNET_v140.dll' `
  -ArenaRuntimeDir 'D:\Arena SDK\Win32Release'
```

The script creates `ArenaLatestFrameWriter.exe` and
`PpsiSharedMemoryReader.dll` in the repository root and copies the required
Arena runtime DLLs beside them. These generated/vendor files are ignored by
Git.

### 4. Check the environment

With ArenaView closed, run:

```powershell
.\scripts\Check-LucidPpsiViewer.ps1
```

The checker verifies MATLAB, the Arena installation, required runtime files,
and camera detection.

### 5. Start the viewer

The launcher defaults to MATLAB R2023b:

```powershell
.\scripts\Start-LucidPpsiViewer.ps1
```

To use another installed MATLAB release:

```powershell
.\scripts\Start-LucidPpsiViewer.ps1 -MatlabRelease R2024b
```

Alternatively, open MATLAB in the repository root and run:

```matlab
lucid_ppsi_viewer
```

Press **Start** after setting FPS, exposure, gain, and ROI. The displayed
hologram range, amplitude range, and phase range only change visualization;
they do not modify acquired data or the reconstruction.

## Runtime data flow

```text
LUCID camera
    -> ArenaNET bridge
    -> Windows shared memory
    -> MATLAB viewer
    -> hologram / amplitude / wrapped phase
```

Small files under `live_frame/` carry camera settings, stop requests, and
status messages. They do not carry image pixels and are created automatically.

## Troubleshooting

### `GC_ERR_ACCESS_DENIED` or unable to write port

Close ArenaView and any other application connected to the camera, then start
the viewer again. This error normally means another process owns camera control.

### No camera is detected

Verify camera power, Ethernet connection, host IP/subnet, firewall settings,
and detection in ArenaView. Run the environment checker after ArenaView has
been closed.

### The bridge or a DLL cannot be loaded

Confirm that `ArenaNET_v140.dll` and the native runtime came from compatible
Arena releases. The bridge is currently compiled for x86 and therefore uses
the SDK's `Win32Release` runtime.

## License

The source code in this repository is provided under the MIT License. MATLAB,
LUCID Arena SDK, ArenaNET, camera drivers, and their binaries are third-party
software governed by their respective licenses.
