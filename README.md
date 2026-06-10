# HorusInstall

Reinstall a Linux VPS to **Windows Server** with a single command. No VNC required, fully automatic.

Supports **Windows Server 2016 / 2019 / 2022 / 2025 Datacenter** (x86_64).

> Based on concepts from [bin456789/reinstall](https://github.com/bin456789/reinstall) — stripped down and focused exclusively on Linux → Windows Server Datacenter.

***

## Requirements

| Item | Minimum |
|------|---------|
| RAM | 1 GB |
| Disk | 25 GB |
| Architecture | x86_64 |
| Current OS | Any Linux with GRUB |
| Virtualization | KVM, VMware, XEN, Bare Metal |

> ❌ **Not compatible** with OpenVZ or LXC containers.

***

## Quick Start

```bash
# (Recommended) Run pre-flight checks first
bash <(curl -sSL https://raw.githubusercontent.com/HorusHDx/HorusInstall/main/healthcheck.sh) windows --version 2022

# Then install
bash <(curl -sSL https://raw.githubusercontent.com/HorusHDx/HorusInstall/main/reinstall.sh) windows --version 2022 --password "YourPassword123!"
```

Or chain them — `reinstall.sh` only runs if all critical checks pass:

```bash
bash <(curl -sSL .../healthcheck.sh) windows --version 2022 && \
bash <(curl -sSL .../reinstall.sh)   windows --version 2022 --password "YourPassword123!"
```

***

## All Options

```bash
bash reinstall.sh windows \
  --version   2022          \  # 2016 / 2019 / 2022 / 2025  (required)
  --password  "Pass123!"    \  # Administrator password      (default: HorusInstall123!)
  --username  Administrator \  # Administrator username      (default: Administrator)
  --port      3389          \  # RDP port                    (default: 3389)
  --lang      en-us         \  # ISO language code           (default: en-us)
  --iso       "https://..." \  # Custom ISO URL              (skips massgrave.dev lookup)
  --image     "Windows Server 2022 SERVERDATACENTEREVAL"   # WIM image name (auto-detected)
```

### Language examples

```bash
# Portuguese (Brazil)
bash reinstall.sh windows --version 2022 --lang pt-br --password "Senha123!"

# Spanish
bash reinstall.sh windows --version 2022 --lang es-es --password "Clave123!"
```

### Custom ISO

```bash
bash reinstall.sh windows \
  --version 2022 \
  --iso "https://example.com/server2022.iso" \
  --image "Windows Server 2022 SERVERDATACENTER" \
  --password "MyPass123!"
```

***

## How It Works

```
[Linux VPS]
    │
    ▼
reinstall.sh        → validates env, detects network, resolves ISO URL from massgrave.dev,
                      builds custom Alpine initrd, injects GRUB entry, reboots
    │
    ▼
[Alpine Linux — RAM]
    │
    ▼
trans.sh            → installs packages, downloads ISO + VirtIO drivers,
                      partitions disk (BIOS/MBR or EFI/GPT), applies WIM,
                      places autounattend.xml + post-install scripts, reboots
    │
    ▼
[Windows Setup — automated via autounattend.xml]
    │
    ▼
windows-setup.bat   → enables RDP on configured port, re-enables firewall
                      with correct rules, disables auto-logon, expands partition,
                      configures WinRM, disables Server Manager auto-launch
    │
    ▼  (only if static IP detected)
windows-set-netconf.bat → flushes DHCP lease, assigns static IP, verifies
                          gateway and DNS resolution
    │
    ▼
[Ready — connect via RDP]
```

**Total time: ~15–40 minutes** depending on server disk speed and ISO download speed.

***

## ISO Source

By default, HorusInstall queries **[massgrave.dev](https://massgrave.dev)** to resolve the correct official Microsoft ISO URL for the requested version, edition, and language. This ensures the link is always current even if Microsoft rotates their CDN URLs.

If massgrave.dev is unreachable, the script falls back to hardcoded evaluation ISO URLs automatically.

***

## Monitoring Progress

| Method | When |
|--------|------|
| **VPS panel VNC** | During Alpine phase and Windows Setup |
| **Serial console** | If your provider supports it |
| **SSH (port 22)** | While Alpine is running, before Windows Setup starts |

***

## After Installation

```
RDP Host : <your VPS IP>
RDP Port : <port you set, default 3389>
Username : Administrator  (or --username value)
Password : <password you set>
```

Log file on Windows: `C:\horusinstall-setup.log`

***

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `healthcheck.sh` | Linux (current OS) | Pre-flight validation — run before reinstall.sh |
| `reinstall.sh` | Linux (current OS) | Main script — prepares Alpine boot environment |
| `trans.sh` | Alpine (RAM) | Downloads ISO, partitions disk, applies WIM |
| `windows.xml` | Windows PE | Unattended answer file for Windows Setup |
| `windows-setup.bat` | Windows (first boot) | RDP, firewall, WinRM, partition resize |
| `windows-set-netconf.bat` | Windows (first boot) | Static IP configuration |

***

## Compatibility Notes

- **EFI and BIOS** layouts are both supported — detected automatically
- **VirtIO drivers** (NetKVM, viostor, vioscsi, vioserial, balloon) are injected automatically on KVM/QEMU
- **Static IP** is detected from the current Linux network config and applied on first Windows boot
- **Multiple disks** — the largest eligible disk (≥ 25 GB) is always selected

***

## License

GPL-3.0