# Monitor de Hardware

*Leia em português: [README.md](README.md).*

A local hardware monitor for Windows. It is a live dashboard of every sensor in your PC (CPU, GPU, RAM, drives, fans, network, voltages), opened in its own window, plus a system tray icon that shows your hottest component's temperature. It also sends Windows notifications when something needs attention and keeps a 30-day history.

It is built on top of [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor), which reads the sensors. This project adds the dashboard, tray icon, alerts, per-program usage, disk health and long-term logging. It uses only PowerShell 5.1, a few lines of C# compiled on the fly, and plain HTML/JS, so there is nothing to build or install besides LibreHardwareMonitor.

> **Language:** the user interface, notifications and CSV headers are in **Brazilian Portuguese**. UI labels below appear as they do on screen, with an English translation where it helps.

## Features

- **Dashboard in its own window.** Edge app mode, with no tabs or address bar.
  - Summary strip at the top: CPU, GPU, RAM, VRAM, power, hottest drive and network.
  - Dual-ring gauges: outer ring is temperature, inner ring is load.
  - History charts with temperature and load, over 1, 5 or 15 minutes, with hover tooltips.
  - Per-core clocks and load (collapsible).
  - **All sensors** (collapsible section): a searchable, filterable list with a min–max range bar for every sensor.
  - **Compact mode** (*Compacto*): only the summary strip, in two columns. The window shrinks to fit it and returns to its previous size (maximized included) when you leave compact mode.
- **Multiple graphics cards.** With more than one GPU, the card gets a GPU selector; the summary strip, history, VRAM, alerts and log handle each card separately. Each card's total VRAM is read from Windows.
- **NVIDIA cards are also read from the driver.** LibreHardwareMonitor reports 0 MHz while the card idles; the dashboard then uses the clock reported by `nvidia-smi`. The card also shows the PCIe link (width and generation, highlighted when the card sits in a slot or riser narrower than it supports) and the power state (P0 to P8). A power reading that cannot be true for an idle, cool card is flagged with ⚠ and left out of the power indicator and the log.
- **Tray icon.** Shows the hotter of CPU and GPU (the hottest GPU if there are several), colored by temperature band. A thin stripe under the number tells you which one it is: blue for CPU, purple for GPU. You can switch it to CPU only, GPU only or alternating.
- **Per-program usage.** The programs using the most CPU (with RAM) and the most GPU (with engine type and VRAM). Same data sources as Task Manager.
- **Alerts** as Windows notifications, with cooldowns:

  | Alert | Trigger |
  |---|---|
  | CPU or GPU hot | above the "hot" limit for 10 s |
  | Drive hot | above the drive limit for 30 s (NVMe drives use the manufacturer's warning temperature) |
  | SSD wear | life below 70 % |
  | SSD spare exhausted | available spare at the manufacturer's threshold |
  | Old HDD | more than 40,000 power-on hours |
  | Memory | committed memory above 90 % of the limit |
  | Monitor stalled | LibreHardwareMonitor not responding for 1 min |

  Several alerts at once are merged into a single notification. Active alerts also appear as banners in the dashboard, and each can be dismissed until the next time you open it.
- **Disk health.** For each drive: its letter (C:, D:…), type (HDD, SSD or NVMe), remaining life, power-on time, and a highlighted note when action is needed.
- **Enable/disable external HDDs.** Puts a USB drive *offline* in Windows, or back online, with one click. That stops all access to it without unplugging. Before disabling, it warns about programs using the drive and **qBittorrent torrents** saved on it, then flushes pending writes. The Windows administrator prompt is required.
- **30-day log** (collapsible section, with a one-line period summary when closed). One line per minute (average and peak) in daily CSV files that open directly in Excel. The dashboard shows 24-hour, 7-day and 30-day charts, peak values with date and time, and the energy used by CPU and GPU.
- **Settings** (*Ajustes*): color themes, every interface color, temperature bands, the drive temperature limit, and alerts on or off.

## Requirements

- Windows 10 or 11, with Windows PowerShell 5.1 and Microsoft Edge (both included in Windows).
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor), tested with 0.9.6, **running as administrator**. Without admin rights, the CPU, motherboard and fan sensors are missing.

## Setup

1. **Install LibreHardwareMonitor:**
   ```powershell
   winget install LibreHardwareMonitor.LibreHardwareMonitor
   ```
2. **Run it as administrator** and accept the PawnIO driver install on first launch.
3. **In LibreHardwareMonitor › Options**, enable:
   - **Remote Web Server › Run** (default port 8085). If Windows Firewall asks, you can deny it: the dashboard reads from `localhost`.
   - **Run On Windows Startup**, **Start Minimized** and **Minimize To Tray** (recommended).
   - Then close it once with **File › Exit** so these settings are saved.
4. **Clone this repository** and double-click `Iniciar monitor.bat`. The tray icon appears and the dashboard opens.

### Desktop shortcut and start with Windows (optional)

For a shortcut without a console window, point it at:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<repo folder>\servidor.ps1"
```

and set `monitor.ico` as its icon.

To start the tray icon at logon without opening the window, place a shortcut in `shell:startup` with:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<repo folder>\servidor.ps1" -NaoAbrirNavegador -SemLHM
```

`-SemLHM` skips launching LibreHardwareMonitor, which already starts on its own. Without it, a UAC prompt could appear at logon.

### SMART through CrystalDiskInfo (optional)

On some laptops the NVMe SSD sits behind the Intel RST VMD controller, and LibreHardwareMonitor returns zeroed SMART data (0 °C, 0 power-on hours). The drive card then shows *SMART indisponível*. To get the real values:

1. Install CrystalDiskInfo: `winget install CrystalDewWorld.CrystalDiskInfo`
2. Run `instalar-smart.ps1` (one UAC prompt). It creates the scheduled task **Monitor de Hardware - SMART**, which runs CrystalDiskInfo in the background every 5 minutes and rewrites its `DiskInfo.txt` report.

The dashboard uses that report only for NVMe drives with a zeroed reading, and tags the card with *via CDI*. A report older than 30 minutes is ignored. To undo: `instalar-smart.ps1 -Remover`.

## Usage

- **Left-click the tray icon** to open the dashboard. If the dashboard is already open, it is brought to the front.
- **Right-click the tray icon** for a CPU/GPU/RAM summary and these options:
  - *Notificações de alerta*: alerts on or off.
  - *Ícone mostra*: what the icon shows.
  - *Abrir LibreHardwareMonitor*: open LibreHardwareMonitor.
  - *Encerrar monitor*: quit.
- Closing the dashboard window keeps monitoring in the tray.

### Command-line options for `servidor.ps1`

| Option | Purpose |
|---|---|
| `-Porta 8100` | Serve the dashboard on another port (default `8099`) |
| `-Fonte <url or file>` | Read LibreHardwareMonitor from another URL, or from a JSON file for testing |
| `-NaoAbrirNavegador` | Start without opening the dashboard window |
| `-SemLHM` | Do not launch LibreHardwareMonitor |
| `-CaminhoLHM <path>` | Path to `LibreHardwareMonitor.exe`, if not installed via winget |
| `-RelatorioSmart <path>` | Path to CrystalDiskInfo's `DiskInfo.txt`, if it is not under `Program Files` |

## How it works

```text
LibreHardwareMonitor ──(localhost:8085/data.json)──► servidor.ps1 ──(localhost:8099)──► dashboard (Edge app window)
   (admin, sensors)                                   │  tray icon, alerts, history
                                                      ├─ Processos.cs  per-program CPU/GPU (PDH API)
                                                      └─ Registro.cs   per-minute CSV log, 30 days
```

| File | Role |
|---|---|
| `servidor.ps1` | Tray app and local HTTP server. Relays sensor data, evaluates alerts, keeps a 15-minute history buffer, queries drive letters and disk state in the background, and enables/disables external drives through an elevated `Set-Disk`. |
| `index.html` | The whole dashboard (HTML, CSS and JS in one file). |
| `Janela.cs` | Resizes the dashboard window for compact mode (Windows API). It only acts on the active window with the dashboard's exact title. |
| `Processos.cs` | Per-program CPU time and GPU engine/VRAM usage. It uses the native PDH API, because `Get-Counter` is far too slow with hundreds of GPU counter instances. |
| `Registro.cs` | Per-minute aggregation, daily CSV files, retention, and downsampled series for the charts. |
| `Iniciar monitor.bat` | Starts `servidor.ps1` hidden. |
| `instalar-smart.ps1` | Creates or removes the scheduled task that makes CrystalDiskInfo write the SMART report (optional). |

Files created at runtime, kept out of git by `.gitignore`:

| File | Contents |
|---|---|
| `config.json` | Colors, temperature bands, alert and icon settings |
| `alertas-estado.json` | When each alert was last shown, so alerts don't repeat at every boot |
| `letras-ultimas.json` | Last known letter of each drive, still shown while a drive is disabled |
| `registros/` | Daily CSV logs: `YYYY-MM-DD.csv` and `discos-YYYY-MM-DD.csv`. They use `;` as separator and a decimal comma (Brazilian Excel format), about 0.8 MB per day. |

### HTTP endpoints (localhost only)

| Endpoint | Description |
|---|---|
| `GET /` | Dashboard |
| `GET /dados` | Raw LibreHardwareMonitor JSON (relayed, with a short cache) |
| `GET /historico` | Last 15 minutes of CPU/GPU temperature and load |
| `GET /registro?dias=1\|7\|30` | Downsampled long-term series and period summary |
| `GET /processos` | Top programs by CPU and GPU |
| `GET /alertas` | Active alerts |
| `GET /memoria` | Configured RAM speed, as reported by Windows |
| `GET /smart` | SMART read by CrystalDiskInfo, per disk number |
| `GET /gpus` | Graphics cards and their real VRAM size |
| `GET /nvidia` | NVIDIA cards from the driver: clocks, power state, PCIe link and power limit |
| `GET /letras`, `GET /discos-estado` | Drive letters, disk state and the last enable/disable action |
| `GET /disco-uso?n=<disk>` | What is using a drive (processes, qBittorrent torrents) |
| `GET/POST /config` | Read or save settings |
| `POST /discos-estado` | Enable or disable an external drive |
| `POST /janela` | Shrink or restore the dashboard window (compact mode) |
| `POST /abrir-registros` | Open the CSV folder in Explorer |

## Security notes

- The server registers only `http://localhost:8099/` with Windows (HTTP.sys), and Windows Firewall blocks inbound connections to it by default. It is not meant to be reached from other devices.
- State-changing requests (`POST`) are accepted only from the dashboard's own origin and only with a JSON body. That blocks other websites from triggering them through your browser.
- Enabling and disabling drives is limited to USB drives. The server refuses system/boot disks and any disk holding a page file, and every action still requires the Windows administrator prompt.
- LibreHardwareMonitor's own web server accepts connections from the network, which is why Windows Firewall asks about it. Deny that prompt (or block port 8085) if you don't want other devices to read your sensors. The dashboard keeps working because it reads from `localhost`.

## License

[MIT](LICENSE). LibreHardwareMonitor is a separate project under its own license (MPL-2.0); it is not included in this repository.
