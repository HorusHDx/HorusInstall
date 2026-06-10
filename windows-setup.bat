@echo off
rem ============================================================================
rem windows-setup.bat
rem HorusInstall - Linux to Windows reinstall tool
rem Based on: github.com/bin456789/reinstall (GPL-3.0)
rem Modified by: HorusHDx
rem
rem Purpose: Runs inside the Windows PE (boot.wim) environment to:
rem   1. Load SCSI/storage drivers so the installer can see the disk
rem   2. Partition and format the target disk (EFI or BIOS layout)
rem   3. Patch windows.xml with the correct disk index
rem   4. Bypass Windows 11 hardware requirement checks (TPM, SecureBoot, RAM)
rem   5. Create a pagefile so installation succeeds on low-RAM machines (1 GB)
rem   6. Launch the official Windows setup.exe with the unattend answer file
rem
rem Drive letter map during installation:
rem   X:\ = WinPE RAM disk (boot.wim, scripts, drivers, windows.xml)
rem   Y:\ = Installer partition (sources\setup.exe, install.wim)
rem   Z:\ = Target OS partition (where Windows will be installed)
rem
rem Variables replaced by reinstall.sh before this script runs:
rem   %is4kn%  : "1" if the target disk uses 4Kn sector size, else "0"
rem ============================================================================

mode con cp select=437 >nul

rem ============================================================================
rem Restore setup.exe (it was renamed to .disabled to prevent auto-launch)
rem ============================================================================
rename X:\setup.exe.disabled setup.exe

rem ============================================================================
rem 10-second countdown before automatic installation begins.
rem Press Ctrl+C to abort.
rem ============================================================================
cls
for /l %%i in (10,-1,1) do (
    echo Press Ctrl+C within %%i seconds to cancel the automatic installation.
    call :sleep 1000
    cls
)

rem ============================================================================
rem Set High Performance power plan inside WinPE.
rem Reference:
rem   https://learn.microsoft.com/windows-hardware/manufacture/desktop/capture-and-apply-windows-using-a-single-wim
rem Note: WinPE on Windows 8 does not include powercfg — suppress the error.
rem ============================================================================
powercfg /s SCHEME_MIN 2>nul

rem ============================================================================
rem Load SCSI/storage drivers from the driver staging directories.
rem Only SCSI-class drivers are loaded at this stage; other drivers (NIC,
rem display, etc.) will be installed by offlineServicing pass in windows.xml.
rem
rem Note on win7 find command: find.exe has a bug under codepage 65001 (UTF-8)
rem on Windows 7 PE. We use find only for SCSI class detection (ASCII content),
rem which is safe. findstr works correctly but is not available in all PE builds.
rem ============================================================================
if exist X:\drivers\ (
    for /f "delims=" %%F in ('dir /s /b "X:\drivers\*.inf" 2^>nul') do (
        call :drvload_if_scsi "%%~F"
    )
)

rem Load user-supplied custom SCSI drivers (--add-driver flag)
if exist X:\custom_drivers\ (
    for /f "delims=" %%F in ('dir /s /b "X:\custom_drivers\*.inf" 2^>nul') do (
        call :drvload_if_scsi "%%~F"
    )
)

rem ============================================================================
rem Wait for the disk to be recognized after driver loading
rem ============================================================================
call :sleep 5000
echo rescan | diskpart

rem ============================================================================
rem Detect boot mode: EFI or BIOS/Legacy
rem
rem We check diskpart's volume list for an EFI system partition.
rem Alternative: https://learn.microsoft.com/windows-hardware/manufacture/desktop/boot-to-uefi-mode-or-legacy-bios-mode
rem Note: mountvol is not available in WinPE.
rem ============================================================================
echo list vol | diskpart | find "efi" && (
    set BootType=efi
) || (
    set BootType=bios
)

rem ============================================================================
rem Get the Windows build number from the offline registry in the installer.
rem This determines which setup.exe path and features are available.
rem ============================================================================
for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber') do (
    set "BuildNumber=%%a"
)

rem ============================================================================
rem Locate the installer volume (the partition labelled "installer")
rem and assign it drive letter Y:
rem ============================================================================
for /f "tokens=2" %%a in ('echo list vol ^| diskpart ^| find "installer"') do (
    set "VolIndex=%%a"
)
(echo select vol %VolIndex% & echo assign letter=Y) | diskpart

rem ============================================================================
rem Create pagefile(s) on the installer partition (Y:).
rem
rem The old setup.exe (pre-24H2) automatically creates a pagefile on C:.
rem The new setup.exe (24H2+) does NOT create one automatically.
rem On machines with only 1 GB RAM, the installer will crash or kill processes
rem without a pagefile. We fill the installer partition to maximize pagefile size.
rem ============================================================================
call :createPageFile

rem ============================================================================
rem Find the physical disk number that contains the installer partition.
rem Vista WinPE has no wmic, so we use diskpart output parsing instead.
rem ============================================================================
(echo select vol %VolIndex% & echo list disk) | diskpart | find "* Disk " > X:\disk.txt
for /f "tokens=3" %%a in (X:\disk.txt) do (
    set "DiskIndex=%%a"
)
del X:\disk.txt

rem ============================================================================
rem Determine EFI partition size.
rem 4Kn drives require a 260 MB EFI partition.
rem Standard drives use 100 MB.
rem %is4kn% is replaced by reinstall.sh (value: "0" or "1").
rem ============================================================================
set is4kn=0
if "%is4kn%"=="1" (
    set EFISize=260
) else (
    set EFISize=100
)

rem ============================================================================
rem Partition and format the target disk.
rem
rem EFI layout (GPT):
rem   Part 1 : EFI System Partition  (FAT32, 100 or 260 MB)
rem   Part 2 : Microsoft Reserved    (16 MB)
rem   Part 3 : Windows OS partition  (NTFS, remainder)
rem
rem BIOS layout (MBR):
rem   Part 1 : Windows OS partition  (NTFS, entire disk)
rem            Marked active for bootability
rem
rem We delete existing parts 1-3 on GPT before recreating them.
rem On MBR we only reformat part 1 (the OS partition already exists).
rem ============================================================================
(if "%BootType%"=="efi" (
    echo select disk %DiskIndex%
    echo select part 1
    echo delete part override
    echo select part 2
    echo delete part override
    echo select part 3
    echo delete part override
    echo create part efi size=%EFISize%
    echo format fs=fat32 quick
    echo create part msr size=16
    echo create part primary
    echo format fs=ntfs quick
) else (
    echo select disk %DiskIndex%
    echo select part 1
    echo format fs=ntfs quick
    echo active
)) > X:\diskpart.txt

rem Run diskpart from script file — errors stop execution cleanly
diskpart /s X:\diskpart.txt
del X:\diskpart.txt

rem ============================================================================
rem For new setup.exe (build >= 26040, i.e. 24H2+) on BIOS machines:
rem The new installer does not write a valid MBR for BIOS boot.
rem Fix it manually with bootrec before launching setup.
rem ============================================================================
if %BuildNumber% GEQ 26040 if "%BootType%"=="bios" (
    bootrec /fixmbr
)

rem ============================================================================
rem For new setup.exe (build >= 26040): disable WinRE recovery partition.
rem The new installer creates a WinRE partition before the installer partition,
rem which complicates the layout. Disabling it stores WinRE inside C: instead,
rem which is still functional.
rem ============================================================================
if %BuildNumber% GEQ 26040 (
    set ResizeRecoveryPartition=/ResizeRecoveryPartition Disable
)

rem ============================================================================
rem Bypass Windows 11 hardware requirement checks (TPM 2.0, Secure Boot, RAM).
rem This is necessary for VPS/cloud environments that don't expose these features.
rem Reference: https://github.com/pbatard/rufus/issues/1990
rem Note: CPU core count cannot be bypassed via registry.
rem ============================================================================
for %%a in (RAM TPM SecureBoot) do (
    reg add HKLM\SYSTEM\Setup\LabConfig /t REG_DWORD /v Bypass%%aCheck /d 1 /f
)

rem ============================================================================
rem Patch windows.xml: replace the %%disk_id%% placeholder with the actual
rem physical disk index detected above.
rem ============================================================================
set "file=X:\windows.xml"
set "tempFile=X:\tmp.xml"
set "search=%%disk_id%%"
set "replace=%DiskIndex%"

(for /f "delims=" %%i in (%file%) do (
    set "line=%%i"
    setlocal EnableDelayedExpansion
    echo !line:%search%=%replace%!
    endlocal
)) > %tempFile%
move /y %tempFile% %file%

rem ============================================================================
rem Determine which setup.exe to use.
rem
rem setup.exe on Y:\ (root) = new installer (Windows 10 1507+)
rem setup.exe on Y:\sources\ = old installer (Vista, 7, 8.x)
rem
rem The new installer defaults to Compact OS and does not create BIOS MBR boot.
rem For BIOS machines on build >= 26040 we already fixed MBR above.
rem
rem Running setup.exe from the ramdisk (X:\) causes issues:
rem   - Vista: cannot find installation source
rem   - Server 23H2: fails to launch
rem ============================================================================
set ForceOldSetup=0
set EnableUnattended=1
set EnableEMS=0

if "%ForceOldSetup%"=="1" (
    set setup=Y:\sources\setup.exe
) else (
    set setup=Y:\setup.exe
)

if "%EnableUnattended%"=="1" (
    set Unattended=/unattend:X:\windows.xml
)

rem ============================================================================
rem Enable Emergency Management Services (EMS / SAC) for Windows Server.
rem %EnableEMS% is replaced with "1" by reinstall.sh when the ISO contains
rem the SAC component. Regular Windows editions do not include SAC.
rem ============================================================================
if "%EnableEMS%"=="1" (
    set EMS=/EMSPort:COM1 /EMSBaudRate:115200
)

rem ============================================================================
rem Launch the Windows installer
rem ============================================================================
echo on
%setup% %ResizeRecoveryPartition% %EMS% %Unattended%
exit /b

rem ============================================================================
rem Subroutine: sleep
rem Args: milliseconds to wait
rem
rem Cannot use ping (NIC drivers not loaded yet).
rem Cannot use timeout (not available in WinPE).
rem Uses a temporary VBScript file instead.
rem ============================================================================
:sleep
echo wscript.sleep(%~1) > X:\sleep.vbs
cscript //nologo X:\sleep.vbs
del X:\sleep.vbs
exit /b

rem ============================================================================
rem Subroutine: createPageFile
rem Creates up to 100 pagefile entries on Y:\ (installer partition).
rem wpeutil CreatePageFile defaults to 64 MB per file.
rem Stops when the partition is full (command returns error).
rem ============================================================================
:createPageFile
for /l %%i in (1,1,100) do (
    wpeutil CreatePageFile /path=Y:\pagefile%%i.sys >nul 2>nul && echo Created pagefile%%i.sys || exit /b
)
exit /b

rem ============================================================================
rem Subroutine: createPageFileOnZ
rem Creates a single 512 MB pagefile on the target OS partition (Z:\).
rem Used as a fallback for new installer builds if needed.
rem ============================================================================
:createPageFileOnZ
wpeutil CreatePageFile /path=Z:\pagefile.sys /size=512
exit /b

rem ============================================================================
rem Subroutine: drvload_if_scsi
rem Args: full path to an .inf file
rem
rem Loads the driver only if it is a SCSI/storage class driver.
rem We search for "SCSIAdapter" in the .inf content (case-insensitive).
rem We do NOT match on "Class=SCSIAdapter" specifically because some INF
rem files have spaces around the equals sign.
rem
rem Note: GPU drivers (e.g. viogpudo) are intentionally skipped here.
rem Display drivers loaded during WinPE do not persist into the installed OS
rem and cause no visible output improvement during installation anyway.
rem ============================================================================
:drvload_if_scsi
find /i "SCSIAdapter" "%~1" >nul
if not errorlevel 1 (
    drvload "%~1"
)
exit /b
