@echo off
:: HorusInstall - windows-set-netconf.bat
:: Configures a static IP address on first boot.
:: Called from SetupComplete.cmd only when NET_MODE=static was detected.
:: All __PLACEHOLDER__ values are replaced by trans.sh before the file
:: is written to disk.
:: https://github.com/HorusHDx/HorusInstall

setlocal EnableDelayedExpansion

set LOGFILE=C:\horusinstall-setup.log
set NET_IPV4=__NET_IPV4__
set NET_PREFIX=__NET_PREFIX__
set NET_GATEWAY=__NET_GATEWAY__
set NET_DNS=__NET_DNS__

echo. >> %LOGFILE%
echo [%date% %time%] Applying static network config >> %LOGFILE%
echo   IP/Prefix : %NET_IPV4%/%NET_PREFIX% >> %LOGFILE%
echo   Gateway   : %NET_GATEWAY% >> %LOGFILE%
echo   DNS       : %NET_DNS% >> %LOGFILE%

echo [*] Configuring static IP: %NET_IPV4%/%NET_PREFIX% via %NET_GATEWAY%

:: ---------------------------------------------------------------------------
:: Convert CIDR prefix length to dotted-decimal subnet mask
:: Full lookup table /0-/32 — no bit-shift arithmetic (unreliable in cmd.exe)
:: ---------------------------------------------------------------------------
call :cidr_to_mask %NET_PREFIX% NET_MASK
echo [*] Subnet mask: %NET_MASK%

:: ---------------------------------------------------------------------------
:: Detect the correct network interface via PowerShell (primary)
:: Falls back to netsh parsing if PowerShell is unavailable
:: ---------------------------------------------------------------------------
set IFACE=

:: 1) PowerShell: find the interface that currently holds our IP
for /f "usebackq delims=" %%I in (`powershell -NoProfile -NonInteractive -Command ^
    "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq '%NET_IPV4%' } | Select-Object -ExpandProperty InterfaceAlias" 2^>nul`) do (
    set IFACE=%%I
    goto :have_iface
)

:: 2) PowerShell: first adapter with Status=Up
for /f "usebackq delims=" %%I in (`powershell -NoProfile -NonInteractive -Command ^
    "Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1 -ExpandProperty Name" 2^>nul`) do (
    set IFACE=%%I
    goto :have_iface
)

:: 3) Classic netsh fallback (locale-dependent, last resort)
for /f "tokens=1 delims=:" %%A in ('netsh interface show interface ^| findstr /i "connected"') do (
    set IFACE=%%A
    goto :have_iface
)

:have_iface
set IFACE=%IFACE: =%

if "%IFACE%"=="" (
    echo [WARN] Interface not detected — defaulting to 'Ethernet' >> %LOGFILE%
    set IFACE=Ethernet
)

echo [*] Target interface: %IFACE%
echo   Interface : %IFACE% >> %LOGFILE%

:: ---------------------------------------------------------------------------
:: Remove any existing IP configuration on this interface before applying
:: static — avoids duplicate address entries
:: ---------------------------------------------------------------------------
echo [*] Flushing existing IP configuration...
powershell -NoProfile -NonInteractive -Command ^
    "Get-NetIPAddress -InterfaceAlias '%IFACE%' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -NonInteractive -Command ^
    "Get-NetRoute -InterfaceAlias '%IFACE%' -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue" >nul 2>&1

:: ---------------------------------------------------------------------------
:: Apply static IP — PowerShell primary, netsh fallback
:: ---------------------------------------------------------------------------
echo [*] Assigning static IP...
powershell -NoProfile -NonInteractive -Command ^
    "New-NetIPAddress -InterfaceAlias '%IFACE%' -IPAddress '%NET_IPV4%' -PrefixLength %NET_PREFIX% -DefaultGateway '%NET_GATEWAY%' -ErrorAction Stop" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [WARN] PowerShell New-NetIPAddress failed — trying netsh fallback... >> %LOGFILE%
    netsh interface ip set address name="%IFACE%" static %NET_IPV4% %NET_MASK% %NET_GATEWAY% >nul 2>&1
    if !ERRORLEVEL! neq 0 (
        echo [ERROR] Both methods failed to set static IP. >> %LOGFILE%
        goto :verify
    )
)
echo [OK] Static IP assigned >> %LOGFILE%

:: ---------------------------------------------------------------------------
:: Apply DNS — PowerShell primary, netsh fallback
:: ---------------------------------------------------------------------------
echo [*] Setting DNS servers...
powershell -NoProfile -NonInteractive -Command ^
    "Set-DnsClientServerAddress -InterfaceAlias '%IFACE%' -ServerAddresses ('%NET_DNS%','8.8.4.4') -ErrorAction Stop" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [WARN] PowerShell DNS failed — trying netsh fallback... >> %LOGFILE%
    netsh interface ip set dns name="%IFACE%" static %NET_DNS% >nul 2>&1
    netsh interface ip add dns name="%IFACE%" 8.8.4.4 index=2 >nul 2>&1
)
echo [OK] DNS configured (%NET_DNS%, 8.8.4.4) >> %LOGFILE%

:: ---------------------------------------------------------------------------
:: Verify gateway connectivity — ping up to 5 times
:: ---------------------------------------------------------------------------
:verify
echo [*] Verifying gateway connectivity...
set /a attempts=0
:ping_gw_loop
ping -n 1 -w 2000 %NET_GATEWAY% >nul 2>&1
if %ERRORLEVEL%==0 goto :ping_gw_ok
set /a attempts+=1
if %attempts% LSS 5 (
    timeout /t 2 /nobreak >nul
    goto :ping_gw_loop
)
echo [WARN] Gateway %NET_GATEWAY% not reachable after 5 attempts >> %LOGFILE%
goto :verify_dns

:ping_gw_ok
echo [OK] Gateway %NET_GATEWAY% reachable >> %LOGFILE%

:: ---------------------------------------------------------------------------
:: Verify DNS resolution using nslookup
:: ---------------------------------------------------------------------------
:verify_dns
echo [*] Verifying DNS resolution...
nslookup microsoft.com %NET_DNS% >nul 2>&1
if %ERRORLEVEL%==0 (
    echo [OK] DNS resolution OK using %NET_DNS% >> %LOGFILE%
) else (
    echo [WARN] DNS resolution failed on %NET_DNS% — trying 8.8.4.4... >> %LOGFILE%
    nslookup microsoft.com 8.8.4.4 >nul 2>&1
    if !ERRORLEVEL!==0 (
        echo [OK] DNS resolution OK using 8.8.4.4 >> %LOGFILE%
    ) else (
        echo [WARN] DNS resolution failed on both servers. Check connectivity. >> %LOGFILE%
    )
)

:: ---------------------------------------------------------------------------
:: Summary
:: ---------------------------------------------------------------------------
echo.
echo [OK] Static network configuration applied:
echo      IP      : %NET_IPV4%
echo      Mask    : %NET_MASK%
echo      Gateway : %NET_GATEWAY%
echo      DNS     : %NET_DNS%, 8.8.4.4
echo      IFACE   : %IFACE%
echo [%date% %time%] Static network config complete >> %LOGFILE%

exit /b 0

:: ===========================================================================
:: :cidr_to_mask  <prefix_length>  <output_variable>
:: Full lookup table /0-/32 — no bit-shift arithmetic
:: ===========================================================================
:cidr_to_mask
set /a cidr=%1
if %cidr%==0  set %2=0.0.0.0&           goto :eof
if %cidr%==1  set %2=128.0.0.0&         goto :eof
if %cidr%==2  set %2=192.0.0.0&         goto :eof
if %cidr%==3  set %2=224.0.0.0&         goto :eof
if %cidr%==4  set %2=240.0.0.0&         goto :eof
if %cidr%==5  set %2=248.0.0.0&         goto :eof
if %cidr%==6  set %2=252.0.0.0&         goto :eof
if %cidr%==7  set %2=254.0.0.0&         goto :eof
if %cidr%==8  set %2=255.0.0.0&         goto :eof
if %cidr%==9  set %2=255.128.0.0&       goto :eof
if %cidr%==10 set %2=255.192.0.0&       goto :eof
if %cidr%==11 set %2=255.224.0.0&       goto :eof
if %cidr%==12 set %2=255.240.0.0&       goto :eof
if %cidr%==13 set %2=255.248.0.0&       goto :eof
if %cidr%==14 set %2=255.252.0.0&       goto :eof
if %cidr%==15 set %2=255.254.0.0&       goto :eof
if %cidr%==16 set %2=255.255.0.0&       goto :eof
if %cidr%==17 set %2=255.255.128.0&     goto :eof
if %cidr%==18 set %2=255.255.192.0&     goto :eof
if %cidr%==19 set %2=255.255.224.0&     goto :eof
if %cidr%==20 set %2=255.255.240.0&     goto :eof
if %cidr%==21 set %2=255.255.248.0&     goto :eof
if %cidr%==22 set %2=255.255.252.0&     goto :eof
if %cidr%==23 set %2=255.255.254.0&     goto :eof
if %cidr%==24 set %2=255.255.255.0&     goto :eof
if %cidr%==25 set %2=255.255.255.128&   goto :eof
if %cidr%==26 set %2=255.255.255.192&   goto :eof
if %cidr%==27 set %2=255.255.255.224&   goto :eof
if %cidr%==28 set %2=255.255.255.240&   goto :eof
if %cidr%==29 set %2=255.255.255.248&   goto :eof
if %cidr%==30 set %2=255.255.255.252&   goto :eof
if %cidr%==31 set %2=255.255.255.254&   goto :eof
if %cidr%==32 set %2=255.255.255.255&   goto :eof
echo [WARN] Unknown prefix /%cidr% — defaulting mask to 255.255.255.0 >> %LOGFILE%
set %2=255.255.255.0
goto :eof
