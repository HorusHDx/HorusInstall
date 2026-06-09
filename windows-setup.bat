@echo off
setlocal EnableDelayedExpansion

set LOGFILE=C:\horusinstall-setup.log
echo [%date% %time%] HorusInstall post-setup started >> %LOGFILE%

:: Habilitar e imponer RDP puerto personalizado
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f >nul 2>&1

set RDP_PORT=__RDP_PORT__
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d %RDP_PORT% /f >nul 2>&1

:: Firewall
netsh advfirewall firewall set rule group="remote desktop" new enable=Yes >nul 2>&1
netsh advfirewall firewall add rule name="HorusInstall RDP" dir=in action=allow protocol=TCP localport=%RDP_PORT% >nul 2>&1

:: Redimensionar partición principal (Partición 2 en esquemas EFI modernos)
echo select disk 0 > %TEMP%\diskpart_resize.txt
echo select partition 2 >> %TEMP%\diskpart_resize.txt
echo extend >> %TEMP%\diskpart_resize.txt
echo exit >> %TEMP%\diskpart_resize.txt
diskpart /s %TEMP%\diskpart_resize.txt >nul 2>&1
del %TEMP%\diskpart_resize.txt >nul 2>&1

:: Remover credenciales en texto plano del registro por seguridad
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f >nul 2>&1

echo [%date% %time%] HorusInstall completed successfully >> %LOGFILE%

:: Autoeliminación retardada segura de scripts temporales
if exist "C:\Windows\Setup\Scripts" (
    schtasks /create /tn "HorusInstall-Cleanup" /sc once /st 00:00 /sd 01/01/2000 /tr "cmd /c timeout /t 15 && del /q C:\Windows\Setup\Scripts\*.*" /ru SYSTEM /f >nul 2>&1
    schtasks /run /tn "HorusInstall-Cleanup" >nul 2>&1
)