@echo off
:: HorusInstall - windows-setup.bat
:: Post-install configuration for Windows Server Datacenter.
:: Called by SetupComplete.cmd (system-level) and FirstLogonCommands (user-level).
:: https://github.com/HorusHDx/HorusInstall

setlocal EnableDelayedExpansion

set LOGFILE=C:\horusinstall-setup.log
set SCRIPTS=C:\Windows\Setup\Scripts

:: Log OS version for diagnostics
for /f "tokens=*" %%V in ('ver') do set OS_VER=%%V
echo. >> %LOGFILE%
echo ======================================================== >> %LOGFILE%
echo [%date% %time%] HorusInstall post-setup started >> %LOGFILE%
echo   OS: %OS_VER% >> %LOGFILE%
echo ======================================================== >> %LOGFILE%

echo.
echo ========================================================
echo   HorusInstall - Post-Install Configuration
echo   %OS_VER%
echo ========================================================
echo.

:: ============================================================
:: ENABLE REMOTE DESKTOP (RDP)
:: ============================================================
echo [*] Enabling Remote Desktop...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f >nul 2>&1
:: Enable RDP service
sc config TermService start= auto >nul 2>&1
sc start  TermService >nul 2>&1
echo [OK] RDP enabled >> %LOGFILE%

:: ============================================================
:: CONFIGURE RDP PORT
:: __RDP_PORT__ replaced by trans.sh before file is placed on disk
:: ============================================================
set RDP_PORT=__RDP_PORT__
echo [*] Setting RDP port to %RDP_PORT%...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d %RDP_PORT% /f >nul 2>&1
echo [OK] RDP port = %RDP_PORT% >> %LOGFILE%

:: ============================================================
:: FIREWALL — re-enable and configure rules
:: (Firewall was disabled in specialize pass; we re-enable it here
::  with only the ports we actually need open)
:: ============================================================
echo [*] Configuring Windows Firewall...

:: Re-enable firewall on all profiles
netsh advfirewall set allprofiles state on >nul 2>&1

:: Default: block inbound, allow outbound
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound >nul 2>&1

:: RDP on configured port
netsh advfirewall firewall delete rule name="HorusInstall RDP" >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall RDP" protocol=TCP dir=in localport=%RDP_PORT% action=allow >nul 2>&1

:: ICMP ping inbound
netsh advfirewall firewall delete rule name="HorusInstall Ping" >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall Ping" protocol=icmpv4:8,any dir=in action=allow >nul 2>&1
netsh advfirewall firewall set rule name="File and Printer Sharing (Echo Request - ICMPv4-In)" new enable=yes >nul 2>&1

:: SSH (useful if OpenSSH Server is installed later)
netsh advfirewall firewall delete rule name="HorusInstall SSH" >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall SSH" protocol=TCP dir=in localport=22 action=allow >nul 2>&1

:: WinRM HTTP (port 5985)
netsh advfirewall firewall delete rule name="HorusInstall WinRM" >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall WinRM" protocol=TCP dir=in localport=5985 action=allow >nul 2>&1

echo [OK] Firewall configured >> %LOGFILE%

:: ============================================================
:: NETWORK SERVICES
:: ============================================================
echo [*] Ensuring network services are running...
sc config "Dhcp"      start= auto >nul 2>&1 & sc start "Dhcp"      >nul 2>&1
sc config "Dnscache"  start= auto >nul 2>&1 & sc start "Dnscache"  >nul 2>&1
sc config "LanmanServer" start= auto >nul 2>&1 & sc start "LanmanServer" >nul 2>&1
echo [OK] Network services configured >> %LOGFILE%

:: ============================================================
:: WinRM — HTTP only (configure HTTPS/5986 manually for production)
:: ============================================================
echo [*] Enabling WinRM...
winrm quickconfig -quiet >nul 2>&1
winrm set winrm/config/service/auth @{Basic="true"} >nul 2>&1
echo [OK] WinRM enabled >> %LOGFILE%

:: ============================================================
:: WINDOWS UPDATE — disable automatic restarts, notify-only mode
:: ============================================================
echo [*] Configuring Windows Update...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 2 /f >nul 2>&1
echo [OK] Windows Update configured >> %LOGFILE%

:: ============================================================
:: POWER — never sleep or hibernate (server behavior)
:: ============================================================
echo [*] Disabling sleep and hibernate...
powercfg /change standby-timeout-ac 0 >nul 2>&1
powercfg /change hibernate-timeout-ac 0 >nul 2>&1
powercfg /hibernate off >nul 2>&1
echo [OK] Power settings configured >> %LOGFILE%

:: ============================================================
:: SERVER MANAGER — disable auto-launch on logon
:: ============================================================
echo [*] Disabling Server Manager auto-launch...
reg add "HKLM\SOFTWARE\Microsoft\ServerManager" /v DoNotOpenServerManagerAtLogon /t REG_DWORD /d 1 /f >nul 2>&1
echo [OK] Server Manager configured >> %LOGFILE%

:: ============================================================
:: UAC — reduce UAC prompt level for Administrators
:: (still active but no prompt for built-in admin tasks)
:: ============================================================
echo [*] Configuring UAC...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f >nul 2>&1
echo [OK] UAC configured >> %LOGFILE%

:: ============================================================
:: IE ENHANCED SECURITY — disable for Admins (already set in XML,
:: this ensures registry is correct even if XML pass was skipped)
:: ============================================================
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" /v IsInstalled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" /v IsInstalled /t REG_DWORD /d 0 /f >nul 2>&1

:: ============================================================
:: RESIZE SYSTEM PARTITION — expand C: to full disk.
:: Uses PowerShell to detect the correct partition number dynamically
:: (works on both BIOS=part1 and EFI=part2 layouts).
:: Falls back to diskpart if PowerShell is unavailable.
:: ============================================================
echo [*] Expanding system partition to full disk size...
powershell -NoProfile -NonInteractive -Command ^
    "try { $p = Get-Partition -DriveLetter C; $d = $p.DiskNumber; $n = $p.PartitionNumber; $max = (Get-PartitionSupportedSize -DiskNumber $d -PartitionNumber $n).SizeMax; Resize-Partition -DiskNumber $d -PartitionNumber $n -Size $max; Write-Host 'Partition expanded OK' } catch { Write-Host ('Resize error: ' + $_.Exception.Message) }" >> %LOGFILE% 2>&1

if %ERRORLEVEL% neq 0 (
    echo [WARN] PowerShell resize failed, trying diskpart fallback... >> %LOGFILE%
    (
        echo select disk 0
        echo select partition 1
        echo extend
        echo exit
    ) > "%TEMP%\dp_resize.txt"
    diskpart /s "%TEMP%\dp_resize.txt" >nul 2>&1
    del "%TEMP%\dp_resize.txt" >nul 2>&1
)
echo [OK] Partition resize done >> %LOGFILE%

:: ============================================================
:: DISABLE AUTO-LOGON before cleanup
:: ============================================================
echo [*] Disabling auto-logon...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d "0" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f >nul 2>&1
echo [OK] Auto-logon disabled >> %LOGFILE%

:: ============================================================
:: SUMMARY LOG
:: ============================================================
echo. >> %LOGFILE%
echo [%date% %time%] HorusInstall post-setup completed >> %LOGFILE%
echo   RDP Port : %RDP_PORT% >> %LOGFILE%
echo ======================================================== >> %LOGFILE%

echo.
echo ========================================================
echo   HorusInstall setup complete!
echo   RDP Port : %RDP_PORT%
echo   Log      : C:\horusinstall-setup.log
echo ========================================================
echo.

:: ============================================================
:: CLEANUP — delete scripts via delayed scheduled task
:: ============================================================
echo [*] Scheduling script cleanup...
schtasks /delete /tn "HorusInstall-Cleanup" /f >nul 2>&1
schtasks /create /tn "HorusInstall-Cleanup" ^
    /sc once /st 00:00 /du 0001:00 ^
    /tr "cmd /c timeout /t 15 ^&^& del /q /f \"%SCRIPTS%\*.*\" ^&^& schtasks /delete /tn HorusInstall-Cleanup /f" ^
    /ru SYSTEM /f >nul 2>&1
schtasks /run /tn "HorusInstall-Cleanup" >nul 2>&1
echo [OK] Cleanup scheduled >> %LOGFILE%

exit /b 0
