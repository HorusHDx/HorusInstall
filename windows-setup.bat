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
echo [*] Configuring firewall rules...

:: Allow RDP on configured port
netsh advfirewall firewall delete rule name="HorusInstall RDP" >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall RDP" protocol=TCP dir=in localport=%RDP_PORT% action=allow >nul 2>&1

:: Allow ICMP (ping)
netsh advfirewall firewall delete rule name="HorusInstall Ping" >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall Ping" protocol=icmpv4:8,any dir=in action=allow >nul 2>&1

:: Allow SSH (port 22) — useful for monitoring
netsh advfirewall firewall delete rule name="HorusInstall SSH" >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall SSH" protocol=TCP dir=in localport=22 action=allow >nul 2>&1

echo [*] Firewall rules configured >> %LOGFILE%

:: ============================================================
:: ENABLE PING RESPONSE
:: ============================================================
echo [*] Enabling ping response...
netsh advfirewall firewall set rule name="File and Printer Sharing (Echo Request - ICMPv4-In)" new enable=yes >nul 2>&1

:: ============================================================
:: NETWORK SERVICES
:: ============================================================
echo [*] Ensuring network services are running...
sc config "Dhcp" start= auto >nul 2>&1
sc start "Dhcp" >nul 2>&1
sc config "Dnscache" start= auto >nul 2>&1
sc start "Dnscache" >nul 2>&1

:: ============================================================
:: ENABLE WinRM (Windows Remote Management) - useful for automation
:: ============================================================
echo [*] Enabling WinRM...
winrm quickconfig -quiet >nul 2>&1
winrm set winrm/config/service @{AllowUnencrypted="true"} >nul 2>&1
winrm set winrm/config/service/auth @{Basic="true"} >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall WinRM" protocol=TCP dir=in localport=5985 action=allow >nul 2>&1
echo [*] WinRM enabled >> %LOGFILE%

:: ============================================================
:: WINDOWS UPDATE - DISABLE AUTO RESTART
:: ============================================================
echo [*] Configuring Windows Update (disable auto restart)...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 2 /f >nul 2>&1

:: ============================================================
:: POWER SETTINGS - NEVER SLEEP/HIBERNATE
:: ============================================================
echo [*] Disabling sleep and hibernate...
powercfg /change standby-timeout-ac 0 >nul 2>&1
powercfg /change hibernate-timeout-ac 0 >nul 2>&1
powercfg /hibernate off >nul 2>&1

:: ============================================================
:: SERVER MANAGER - DISABLE AUTO-LAUNCH
:: ============================================================
echo [*] Disabling Server Manager auto-launch...
reg add "HKLM\SOFTWARE\Microsoft\ServerManager" /v DoNotOpenServerManagerAtLogon /t REG_DWORD /d 1 /f >nul 2>&1

:: ============================================================
:: RUN NETWORK CONFIG SCRIPT IF EXISTS
:: ============================================================
if exist "C:\Windows\Setup\Scripts\SetupComplete.cmd" (
    echo [*] Running network configuration...
    call "C:\Windows\Setup\Scripts\SetupComplete.cmd"
    echo [*] Network configuration done >> %LOGFILE%
)

:: ============================================================
:: RESIZE PARTITION (expand C: to full disk if needed)
:: ============================================================
echo [*] Expanding system partition...
echo select disk 0 > %TEMP%\diskpart_resize.txt
echo select partition 1 >> %TEMP%\diskpart_resize.txt
echo extend >> %TEMP%\diskpart_resize.txt
echo exit >> %TEMP%\diskpart_resize.txt
diskpart /s %TEMP%\diskpart_resize.txt >nul 2>&1
del %TEMP%\diskpart_resize.txt >nul 2>&1

:: ============================================================
:: CLEANUP
:: ============================================================
echo [*] Cleaning up HorusInstall temp files...
if exist "C:\Windows\Setup\Scripts\windows-setup.bat" (
    :: Self-delete after a short delay using scheduled task
    schtasks /create /tn "HorusInstall-Cleanup" /sc once /st 00:00 /sd 01/01/2000 ^
        /tr "cmd /c del /q \"C:\Windows\Setup\Scripts\*.*\" && schtasks /delete /tn HorusInstall-Cleanup /f" ^
        /ru SYSTEM /f >nul 2>&1
    schtasks /run /tn "HorusInstall-Cleanup" >nul 2>&1
)

echo.
echo [%date% %time%] HorusInstall post-setup completed >> %LOGFILE%

echo ============================================================
echo   Setup complete!
echo.
echo   RDP Port : %RDP_PORT%
echo   Check    : C:\horusinstall-setup.log
echo ============================================================
echo.

:: Disable auto-logon after first run
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d "0" /f >nul 2>&1

exit /b 0
