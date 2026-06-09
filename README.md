# HorusInstall

Reinstall a Linux VPS to **Windows Server** with a single command. No VNC required, fully automatic.

Supports **Windows Server 2016 / 2019 / 2022 Datacenter** (64-bit).

> Based on concepts from [bin456789/reinstall](https://github.com/bin456789/reinstall) — stripped down and focused exclusively on Linux → Windows Server.

---

## Requirements

| Item | Minimum |
|------|---------|
| RAM | 1 GB |
| Disk | 25 GB |
| Architecture | x86_64 |
| Current OS | Any Linux with GRUB |
| Virtualization | KVM, VMware, XEN, Bare Metal |

> ❌ **Not compatible** with OpenVZ or LXC containers.

---

## Usage

```bash
# Download the script
curl -O https://raw.githubusercontent.com/HorusHDx/HorusInstall/main/reinstall.sh

# Run it
bash reinstall.sh windows --version 2022 --password "YourPassword123!"
```

### All options

```bash
bash reinstall.sh windows \
  --version    2022            \  # 2016 / 2019 / 2022  (required)
  --password   "Pass123!"      \  # Admin password       (required)
  --username   administrator   \  # Admin username       (default: administrator)
  --rdp-port   3389            \  # RDP port             (default: 3389)
  --ssh-port   22              \  # SSH log port         (default: 22)
  --iso        "https://..."   \  # Custom ISO URL       (optional)
  --image-name "Windows Server 2022 SERVERDATACENTER"  # (optional)
```

### Custom ISO example

```bash
bash reinstall.sh windows \
  --version 2022 \
  --iso "https://example.com/server2022.iso" \
  --image-name "Windows Server 2022 SERVERDATACENTER" \
  --password "MyPass123!"
```

---

## What happens

1. **`reinstall.sh`** runs on your current Linux — validates requirements, detects network config, sets up GRUB to boot into Alpine Linux
2. System reboots into **Alpine Linux in RAM** (automatic, no interaction needed)
3. **`trans.sh`** runs inside Alpine — downloads the Windows ISO, injects VirtIO drivers if needed, prepares disk partitions, places the unattend.xml
4. System reboots into the **Windows installer** (fully automated via unattend.xml)
5. Windows installs and reboots
6. On first boot, **`windows-setup.bat`** runs — enables RDP, configures firewall, sets static IP if needed

**Total time: ~15–40 minutes** depending on your server's disk speed and ISO download speed.

---

## Monitoring progress

You can watch the installation from:
- **VPS panel VNC** — recommended for the first reboot
- **Serial console** — if your provider supports it
- **SSH** — connect on port 22 while Alpine is running (before Windows installer starts)

---

## After installation

- Connect via **RDP** on the port you specified (default `3389`)
- Username: `administrator` (or what you set with `--username`)
- Password: what you set with `--password`

---

## Files

| File | Purpose |
|------|---------|
| `reinstall.sh` | Main script — runs on current Linux |
| `trans.sh` | Intermediate script — runs in Alpine RAM environment |
| `windows.xml` | Unattended answer file for Windows installer |
| `windows-setup.bat` | Post-install config (RDP, firewall, WinRM) |
| `windows-set-netconf.bat` | Static IP configuration on first boot |

---

## License

GPL-3.0
