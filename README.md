# HorusInstall

Reinstalador **Linux → Windows** de un solo comando, derivado de
[bin456789/reinstall](https://github.com/bin456789/reinstall) (GPL-3.0).

Sube un VPS con Ubuntu/Debian/CentOS cualquiera y corre un comando: baja un
Alpine netboot, inyecta `trans.sh` y toda la configuración en el initrd,
arranca una vez en Alpine, particiona el disco, descarga el ISO oficial de
Windows y deja el servidor entrando al instalador desatendido. Ideal para
testear files (ej. Mu Online S6) sin pagar licencia de Windows.

## Uso

```bash
curl -O https://raw.githubusercontent.com/HorusHDx/HorusInstall/main/reinstall.sh
bash reinstall.sh windows \
  --image-name "Windows Server 2022 SERVERSTANDARD" \
  --lang en-us --allow-ping

# o Windows 10/11 LTSC
bash reinstall.sh windows --image-name "Windows 10 Enterprise LTSC 2021"

# ISO manual
bash reinstall.sh windows --image-name "Windows 11 Pro" --iso "https://.../win11.iso"

# cancelar antes del reboot
bash reinstall.sh reset

# debug: arrancar Alpine sin instalar
bash reinstall.sh windows --image-name "..." --hold 1
```

Monitoreo durante la instalación: `ssh root@IP -p 22` (`tail -f /reinstall.log`)
o `http://IP/` (visores web).

## Archivos

| Archivo | Rol |
|---|---|
| `reinstall.sh` | Orquestador. Descarga Alpine, construye el initrd, configura GRUB. |
| `trans.sh` | Corre dentro de Alpine. Particiona, baja el ISO, prepara WinPE. |
| `windows.xml` | Answer file (placeholders `%...%` reemplazados en runtime). |
| `windows-setup.bat` | Automatización dentro de WinPE. |
| `windows-set-netconf.bat` | IP estática IPv4/IPv6 en el primer boot de Windows. |
| `windows-driver-utils.sh` | Descarga drivers VirtIO/XEN/AWS/GCP/Azure/Intel. |
| `initrd-network.sh` | Detecta y genera la config de red para el initrd. |
| `get-xda.sh` | Detecta el disco destino y valida el tamaño. |
| `logviewer.html` | Visor web del log (lo sirve `websocketd`). |

## Fixes aplicados

1. **Contrato roto `reinstall.sh` ↔ `trans.sh`**: `trans.sh` lee de `/configs/*`
   y del ISO en `/iso-download/windows.iso`, pero el orquestador guardaba todo
   en `/reinstall-tmp` y nunca lo inyectaba. Ahora `write_initrd_configs()`
   escribe `windows.xml`, `windows-set-netconf.bat`, `windows-setup.bat`,
   `confhome`, `script_version`, `iso_url`, `main_disk`, `image_name`, `lang`,
   `password-plaintext` y `hold` dentro del initrd.
2. **`trans.sh` nunca se ejecutaba**: se parchea el `/init` de Alpine antes de
   `exec switch_root` para copiar `trans.sh` a
   `/etc/local.d/trans.start`, habilitar el servicio `local` y copiar `/configs`
   al sysroot. Antes el script quedaba tirado en la raíz del initrd.
3. **`exec > >(tee …)`**: sintaxis bash no soportada por `ash`. El log ahora va
   a `/reinstall.log` y se monitorea por SSH/web.
4. **`main_disk`**: `trans.sh` busca el disco por PTUUID (`sfdisk --disk-id`),
   pero se le pasaba `/dev/sda`. Ahora se calcula el UUID con `get_disk_id()`.
5. **Particiones EFI solapadas**: MSR empezaba en 16 MiB, dentro de la EFI
   (1–101 MiB). Ahora EFI → MSR → installer → Windows sin solapes, con ESP de
   260 MiB en discos 4Kn.
6. **`installto_partitionid`**: era siempre `3`, pero en MBR Windows va en la
   partición `2`. Ahora depende del modo de arranque.
7. **FAT32 >4 GiB**: `install.wim` modernos superan el límite de FAT32; si hay
   un archivo >4 GiB se usa NTFS automáticamente (y el chainload de syslinux
   se ajusta).
8. **EFI**: `efibootmgr` apuntaba a un `grub.cfg` (el firmware no puede
   arrancar un `.cfg`). Ahora registra el `grubx64.efi` existente y usa
   `BootNext` para un solo arranque.
9. **Flavour de Alpine consistente**: el kernel bajado podía ser `virt` mientras el
   cmdline pedía `modloop-lts`. Ahora se usa la misma variable y hay fallback
   a `lts` si el mirror no tiene `virt`.
10. **ISO duplicado**: antes se descargaba en el host y otra vez dentro de
    Alpine. Ahora solo se pasa la URL y Alpine la baja una vez.
11. **Red**: `net.ifnames=0` en el cmdline + normalización a `eth0` para que la
    config del initrd coincida con el nombre de interfaz dentro de Alpine.
12. **Herramientas**: `parted`, `dosfstools`, `util-linux`, `sfdisk`, `shadow`
    se instalan al inicio de `trans.sh` (antes faltaban).
13. **`windows-setup.bat` partía el disco otra vez**: en WinPE borraba las
    particiones 1–3, destruyendo `Y:` (donde está `install.wim`) y dejando
    Windows en la 3 mientras `windows.xml` apuntaba a la 4. Ahora respeta el
    layout de `trans.sh` y el instalador formatea el destino.
14. `logviewer.html` añadido al repo para que el visor web sea self-contained.

## Requisitos

root · curl/wget · bash 4+ (solo el orquestador) · x86_64/aarch64 ·
≥1 GB RAM · ≥25 GB disco · KVM/XEN/VMware/Hyper-V/bare metal
(**no** OpenVZ/LXC).

Licencia GPL-3.0 (heredada del proyecto original).
