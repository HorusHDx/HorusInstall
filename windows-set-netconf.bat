rem ============================================================================
rem windows-set-netconf.bat
rem HorusInstall - Linux to Windows reinstall tool
rem Based on: github.com/bin456789/reinstall (GPL-3.0)
rem Modified by: HorusHDx
rem
rem Purpose: Configure static IPv4/IPv6 on the first Windows boot for machines
rem          that cannot use DHCP (static IP VPS, dedicated servers, etc.)
rem
rem This file is placed on the Windows system drive by reinstall.sh before
rem the installer reboots into Windows. It runs once via windows-setup.bat
rem and then deletes itself.
rem
rem Placeholders below are replaced at runtime by reinstall.sh:
rem   mac_addr     : MAC address of the NIC to configure (colon-separated)
rem   ipv4_addr    : IPv4 address with CIDR prefix  (e.g. 192.168.1.2/24)
rem   ipv4_gateway : IPv4 default gateway           (e.g. 192.168.1.1)
rem   ipv4_dns1    : Primary IPv4 DNS server
rem   ipv4_dns2    : Secondary IPv4 DNS server
rem   ipv6_addr    : IPv6 address with prefix       (e.g. 2001:db8::2/64)
rem   ipv6_gateway : IPv6 default gateway           (e.g. 2001:db8::1)
rem   ipv6_dns1    : Primary IPv6 DNS server
rem   ipv6_dns2    : Secondary IPv6 DNS server
rem
rem If mac_addr is not defined the script exits without making any changes,
rem which is the correct behavior for DHCP machines.
rem ============================================================================

rem -- Default placeholder values (replaced by reinstall.sh at runtime) --------
rem set mac_addr=11:22:33:aa:bb:cc
rem set ipv4_addr=192.168.1.2/24
rem set ipv4_gateway=192.168.1.1
rem set ipv4_dns1=8.8.8.8
rem set ipv4_dns2=8.8.4.4
rem set ipv6_addr=2001:db8::2/64
rem set ipv6_gateway=2001:db8::1
rem set ipv6_dns1=2606:4700:4700::1111
rem set ipv6_dns2=2606:4700:4700::1001

@echo off

rem Force code page 437 (English/ASCII) to avoid output encoding issues
mode con cp select=437 >nul

rem ============================================================================
rem Disable IPv6 address randomization.
rem Without this, the system generates a random IPv6 identifier on each boot,
rem which may differ from the address shown in the hosting control panel.
rem ============================================================================
netsh interface ipv6 set global randomizeidentifiers=disabled

rem ============================================================================
rem If no MAC address was injected, this is a DHCP machine — nothing to do.
rem ============================================================================
if not defined mac_addr goto :cleanup

rem ============================================================================
rem Locate the network interface index by MAC address.
rem
rem We try three methods in order of preference:
rem   1. wmic.exe         (fastest; present on Vista through Windows 10/11 22H2)
rem   2. Get-WmiObject    (PowerShell fallback; works on Win7+)
rem   3. Get-CimInstance  (PowerShell modern fallback; works on Win8+)
rem
rem Notes:
rem   - wmic was removed from Windows 11 24H2, so some DD images lack it.
rem   - wmic output uses \r\r\n line endings; findstr strips the trailing \r
rem     but we still use %id% (not !id!) to avoid variable expansion issues.
rem   - Vista has no built-in PowerShell; wmic covers it.
rem ============================================================================

if exist "%windir%\system32\wbem\wmic.exe" (
    for /f "tokens=2 delims==" %%a in (
        'wmic nic where "MACAddress='%mac_addr%'" get InterfaceIndex /format:list ^| findstr "^InterfaceIndex=[0-9][0-9]*$"'
    ) do set id=%%a
)

if not defined id (
    for /f %%a in (
        'powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
        -Command "(Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.MACAddress -eq '%mac_addr%' }).InterfaceIndex" ^| findstr "^[0-9][0-9]*$"'
    ) do set id=%%a
)

if not defined id (
    for /f %%a in (
        'powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
        -Command "(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.MACAddress -eq '%mac_addr%' }).InterfaceIndex" ^| findstr "^[0-9][0-9]*$"'
    ) do set id=%%a
)

rem If we still could not find the interface, skip configuration
if not defined id (
    echo Warning: Could not find network interface with MAC %mac_addr%. Skipping static IP config.
    goto :cleanup
)

rem ============================================================================
rem Configure static IPv4 address and gateway
rem
rem Notes:
rem   - gwmetric default is 1; setting to 0 enables auto-metric.
rem   - We use %id% (not !id!) to avoid trailing \r issues from wmic output.
rem ============================================================================
if defined ipv4_addr if defined ipv4_gateway (
    netsh interface ipv4 set address %id% static %ipv4_addr% gateway=%ipv4_gateway% gwmetric=0
)

rem ============================================================================
rem Configure static IPv4 DNS servers
rem
rem The "add dnsservers" subcommand (plural) was introduced in Windows 7.
rem Vista uses the singular "add dnsserver" form.
rem We detect which form is supported by checking the help output.
rem ============================================================================
for %%i in (1 2) do (
    if defined ipv4_dns%%i (
        netsh interface ipv4 add | findstr "dnsservers" >nul
        if ErrorLevel 1 (
            rem Vista: singular form, no "no" at the end
            setlocal EnableDelayedExpansion
            netsh interface ipv4 add dnsserver %id% !ipv4_dns%%i! %%i
            endlocal
        ) else (
            rem Windows 7+: plural form, append "no" to avoid overwriting previous entry
            setlocal EnableDelayedExpansion
            netsh interface ipv4 add dnsservers %id% !ipv4_dns%%i! %%i no
            endlocal
        )
    )
)

rem ============================================================================
rem Configure static IPv6 address and default route
rem ============================================================================
if defined ipv6_addr if defined ipv6_gateway (
    netsh interface ipv6 set address %id% %ipv6_addr%
    netsh interface ipv6 add route prefix=::/0 %id% %ipv6_gateway%
)

rem ============================================================================
rem Configure static IPv6 DNS servers
rem Same Vista vs Win7+ detection as IPv4 DNS above.
rem ============================================================================
for %%i in (1 2) do (
    if defined ipv6_dns%%i (
        netsh interface ipv6 add | findstr "dnsservers" >nul
        if ErrorLevel 1 (
            rem Vista
            setlocal EnableDelayedExpansion
            netsh interface ipv6 add dnsserver %id% !ipv6_dns%%i! %%i
            endlocal
        ) else (
            rem Windows 7+
            setlocal EnableDelayedExpansion
            netsh interface ipv6 add dnsservers %id% !ipv6_dns%%i! %%i no
            endlocal
        )
    )
)

rem ============================================================================
rem Custom RDP port configuration (only runs if --rdp-port was specified)
rem %rdp_port% is replaced by reinstall.sh; if not set, this block is skipped.
rem ============================================================================
if defined rdp_port (
    echo Configuring custom RDP port: %rdp_port%

    rem Update the RDP port in the registry
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" ^
        /v PortNumber /t REG_DWORD /d %rdp_port% /f

    rem Open the custom port in Windows Firewall
    netsh advfirewall firewall add rule ^
        name="HorusInstall - RDP Custom Port" ^
        protocol=TCP ^
        dir=in ^
        localport=%rdp_port% ^
        action=allow

    rem Remove the default RDP rule if it exists (port 3389 no longer needed)
    netsh advfirewall firewall delete rule name="Remote Desktop" >nul 2>&1
)

rem ============================================================================
rem Allow ICMP ping if requested (--allow-ping flag)
rem %allow_ping% is replaced by reinstall.sh with "1" or left undefined.
rem ============================================================================
if "%allow_ping%"=="1" (
    echo Enabling ICMP ping responses...
    netsh advfirewall firewall add rule ^
        name="HorusInstall - Allow ICMPv4 Echo" ^
        protocol=icmpv4:8,any ^
        dir=in ^
        action=allow
    netsh advfirewall firewall add rule ^
        name="HorusInstall - Allow ICMPv6 Echo" ^
        protocol=icmpv6:128,any ^
        dir=in ^
        action=allow
)

rem ============================================================================
rem Cleanup: delete this script after it has run.
rem It contains sensitive network details and is no longer needed.
rem ============================================================================
:cleanup
del "%~f0"
