@echo off
:: HorusInstall - Windows Server Post-Install Setup
:: Runs on first logon after Windows installation
:: https://github.com/HorusHDx/HorusInstall

setlocal EnableDelayedExpansion

echo.
echo ============================================================
echo   HorusInstall - Post-Install Configuration
echo ============================================================
echo.

:: Log file
set LOGFILE=C:\horusinstall-setup.log
echo [%date% %time%] HorusInstall post-setup started >> %LOGFILE%

:: ============================================================
:: ENABLE REMOTE DESKTOP (RDP)
:: ============================================================
echo [*] Enabling Remote Desktop...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f >nul 2>&1
echo [*] RDP enabled >> %LOGFILE%

:: ============================================================
:: CONFIGURE RDP PORT
:: ============================================================
set RDP_PORT=__RDP_PORT__
echo [*] Setting RDP port to %RDP_PORT%...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d %RDP_PORT% /f >nul 2>&1
echo [*] RDP port set to %RDP_PORT% >> %LOGFILE%

:: ============================================================
:: FIREWALL RULES
:: ============================================================
echo [*] Configuring Windows Firewall rules for RDP Port %RDP_PORT%...
netsh advfirewall firewall set rule group="remote desktop" new enable=Yes >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall RDP Port" dir=in action=allow protocol=TCP localport=%RDP_PORT% >nul 2>&1
echo [*] Firewall rules added >> %LOGFILE%

:: ============================================================
:: RESIZE PARTITION (expand C: to full disk)
:: ============================================================
echo [*] Expanding system partition to fill disk...
echo select disk 0 > %TEMP%\diskpart_resize.txt
echo select partition 2 >> %TEMP%\diskpart_resize.txt
echo extend >> %TEMP%\diskpart_resize.txt
echo exit >> %TEMP%\diskpart_resize.txt
diskpart /s %TEMP%\diskpart_resize.txt >nul 2>&1
del %TEMP%\diskpart_resize.txt >nul 2>&1
echo [*] Partition expanded >> %LOGFILE%

:: ============================================================
:: DISABLE AUTO LOGON (For Security)
:: ============================================================
echo [*] Disabling automatic logon...
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f >nul 2>&1

:: ============================================================
:: CLEANUP (Safe Delayed Self-Deletion)
:: ============================================================
echo [*] Cleaning up HorusInstall temporary scripts...
echo [%date% %time%] HorusInstall post-setup completed >> %LOGFILE%

if exist "C:\Windows\Setup\Scripts" (
    schtasks /create /tn "HorusInstall-Cleanup" /sc once /st 00:00 /sd 01/01/2000 ^
        /tr "cmd /c timeout /t 10 && del /q C:\Windows\Setup\Scripts\*.*" /ru SYSTEM /f >nul 2>&1
    schtasks /run /tn "HorusInstall-Cleanup" >nul 2>&1
)

echo ============================================================
echo   Setup complete! Your VPS will now accept connections.
echo   RDP Port : %RDP_PORT%
echo ============================================================