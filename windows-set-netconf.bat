@echo off
:: HorusInstall - Static Network Configuration
:: Called from SetupComplete.cmd on first boot if static IP was detected
:: Values are replaced by trans.sh before being placed on disk
:: https://github.com/HorusHDx/HorusInstall

setlocal EnableDelayedExpansion

set NET_IPV4=__NET_IPV4__
set NET_PREFIX=__NET_PREFIX__
set NET_GATEWAY=__NET_GATEWAY__
set NET_DNS=__NET_DNS__

echo [*] Configuring static IP: %NET_IPV4%/%NET_PREFIX% via %NET_GATEWAY%

:: Convert CIDR prefix to subnet mask
call :cidr_to_mask %NET_PREFIX% NET_MASK

echo [*] Subnet mask: %NET_MASK%

:: Find the first active Ethernet adapter
for /f "tokens=1 delims=:" %%A in ('netsh interface show interface ^| findstr /i "connected"') do (
    set IFACE=%%A
    goto :set_ip
)

:set_ip
set IFACE=%IFACE: =%

if "%IFACE%"=="" (
    echo [!] Could not detect network interface, trying 'Ethernet'
    set IFACE=Ethernet
)

echo [*] Setting IP on interface: %IFACE%

:: Set static IP
netsh interface ip set address name="%IFACE%" static %NET_IPV4% %NET_MASK% %NET_GATEWAY% 1 >nul 2>&1

:: Set DNS
netsh interface ip set dns name="%IFACE%" static %NET_DNS% >nul 2>&1
netsh interface ip add dns name="%IFACE%" 8.8.8.8 index=2 >nul 2>&1

echo [*] Network configured:
echo     IP      : %NET_IPV4%
echo     Mask    : %NET_MASK%
echo     Gateway : %NET_GATEWAY%
echo     DNS     : %NET_DNS%

goto :eof

:: ============================================================
:: CIDR to subnet mask conversion
:: ============================================================
:cidr_to_mask
set /a cidr=%1
set mask=0

set /a bits=32
set /a i=0

:mask_loop
if %i% GEQ %cidr% goto :mask_calc_done
set /a mask=(mask>>1)+2147483648
set /a i+=1
goto :mask_loop

:mask_calc_done
:: Extract each octet from the 32-bit mask
set /a o1=(mask>>24)^&255
set /a o2=(mask>>16)^&255
set /a o3=(mask>>8)^&255
set /a o4=mask^&255

:: Handle common cases directly for reliability
if "%cidr%"=="8"  set %2=255.0.0.0&   goto :eof
if "%cidr%"=="16" set %2=255.255.0.0&  goto :eof
if "%cidr%"=="24" set %2=255.255.255.0& goto :eof
if "%cidr%"=="25" set %2=255.255.255.128& goto :eof
if "%cidr%"=="26" set %2=255.255.255.192& goto :eof
if "%cidr%"=="27" set %2=255.255.255.224& goto :eof
if "%cidr%"=="28" set %2=255.255.255.240& goto :eof
if "%cidr%"=="29" set %2=255.255.255.248& goto :eof
if "%cidr%"=="30" set %2=255.255.255.252& goto :eof
if "%cidr%"=="32" set %2=255.255.255.255& goto :eof

:: Fallback for other prefixes
set %2=%o1%.%o2%.%o3%.%o4%
goto :eof