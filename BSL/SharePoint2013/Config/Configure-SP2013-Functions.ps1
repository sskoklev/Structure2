﻿
###################################################################################################################
# MK: search for MK to see what was changed
#     Replaced all Write-Host with log
#
###################################################################################################################
# ===================================================================================
# EXTERNAL FUNCTIONS
# ===================================================================================

# Check that the version of the script matches the Version (essentially the schema) of the input XML so we don't have any unexpected behavior
Function CheckXMLVersion ([xml]$xmlinput)
{
    $getXMLVersion = $xmlinput.Configuration.Version
    # The value below will increment whenever there is an update to the format of the AutoSPInstallerInput XML file
    $scriptVersion = "3.98"
    if ($getXMLVersion -ne $scriptVersion)
    {
        log " - Warning! Your versions of the XML ($getXMLVersion) and script ($scriptVersion) are mismatched."
        log " - You should compare against the latest AutoSPInstallerInput.XML for missing/updated elements."
        # Pause "proceed if you are sure this is OK, or Ctrl-C to exit" "y"
        # MK: added throw
        throw "ERROR: Your versions of the XML ($getXMLVersion) and script ($scriptVersion) are mismatched."
    }
}

#Region Validate Passphrase
Function ValidatePassphrase([xml]$xmlinput)
{
    # Check if passphrase is supplied
    $farmPassphrase = $xmlinput.Configuration.Farm.Passphrase
    If (!($farmPassphrase) -or ($farmPassphrase -eq ""))
    {
        Return
    }
    $groups=0
    If ($farmPassphrase -cmatch "[a-z]") { $groups = $groups + 1 }
    If ($farmPassphrase -cmatch "[A-Z]") { $groups = $groups + 1 }
    If ($farmPassphrase -match "[0-9]") { $groups = $groups + 1 }
    If ($farmPassphrase -match "[^a-zA-Z0-9]") { $groups = $groups + 1 }

    If (($groups -lt 3) -or ($farmPassphrase.length -lt 8))
    {
        log " - Farm passphrase does not meet complexity requirements."
        log " - It must be at least 8 characters long and contain three of these types:"
        log "  - Upper case letters"
        log "  - Lower case letters"
        log "  - Digits"
        log "  - Other characters"
        Throw " - Farm passphrase does not meet complexity requirements."
    }
}
#EndRegion

#Region Validate Credentials
Function ValidateCredentials([xml]$xmlinput)
{
    WriteLine
    WriteLine
    log " - Validating user accounts and passwords..."
    If ($env:COMPUTERNAME -eq $env:USERDOMAIN)
    {
        Throw " - You are running this script under a local machine user account. You must be a domain user"
    }

    ForEach($node in $xmlinput.SelectNodes("//*[@Password]|//*[@password]|//*[@ContentAccessAccountPassword]|//*[@UnattendedIDPassword]|//*[@SyncConnectionAccountPassword]|//*[Password]|//*[password]|//*[ContentAccessAccountPassword]|//*[UnattendedIDPassword]|//*[SyncConnectionAccountPassword]"))
    {
        $user = (GetFromNode $node "username")
        If ($user -eq "") { $user = (GetFromNode $node "Username") }
        If ($user -eq "") { $user = (GetFromNode $node "Account") }
        If ($user -eq "") { $user = (GetFromNode $node "ContentAccessAccount") }
        If ($user -eq "") { $user = (GetFromNode $node "UnattendedIDUser") }
        If ($user -eq "") { $user = (GetFromNode $node "SyncConnectionAccount") }

        $password = (GetFromNode $node "password")
        If ($password -eq "") { $password = (GetFromNode $node "Password") }
        If ($password -eq "") { $password = (GetFromNode $node "ContentAccessAccountPassword") }
        If ($password -eq "") { $password = (GetFromNode $node "UnattendedIDPassword") }
        If ($password -eq "") { $password = (GetFromNode $node "SyncConnectionAccountPassword") }

        If (($password -ne "") -and ($user -ne ""))
        {
            $currentDomain = "LDAP://" + ([ADSI]"").distinguishedName
            log " - Account `"$user`" ($($node.Name))..." 
            $dom = New-Object System.DirectoryServices.DirectoryEntry($currentDomain,$user,$password)
            If ($dom.Path -eq $null)
            {
                log "Invalid!"
                $acctInvalid = $true
            }
            Else
            {
                log "Verified."
            }
        }
    }
    if ($xmlinput.Configuration.WebApplications)
    {
        # Get application pool accounts
        foreach ($webApp in $($xmlinput.Configuration.WebApplications.WebApplication))
        {
            $appPoolAccounts = @($appPoolAccounts+$webApp.applicationPoolAccount)
            # Get site collection owners #
            foreach ($siteCollection in $($webApp.SiteCollections.SiteCollection))
            {
                if (!([string]::IsNullOrEmpty($siteCollection.Owner)))
                {
                    $siteCollectionOwners = @($siteCollectionOwners+$siteCollection.Owner)
                }
            }
        }
    }
    $appPoolAccounts = $appPoolAccounts | Select-Object -Unique
    $siteCollectionOwners = $siteCollectionOwners | Select-Object -Unique
    # Check for the existence of object cache accounts and other ones for which we don't need to specify passwords
    $accountsToCheck = @($xmlinput.Configuration.Farm.ObjectCacheAccounts.SuperUser,$xmlinput.Configuration.Farm.ObjectCacheAccounts.SuperReader)+$appPoolAccounts+$siteCollectionOwners | Select-Object -Unique
    foreach ($account in $accountsToCheck)
    {
        $domain,$accountName = $account -split "\\"
        log " - Account `"$account`"..." 
        if (!(userExists $accountName))
        {
            log "Invalid!"
            $acctInvalid = $true
        }
        else
        {
            log "Verified."
        }
    }
    If ($acctInvalid) {Throw " - At least one set of credentials is invalid.`n - Check usernames and passwords in each place they are used."}
    WriteLine
}
#EndRegion

#Region Trust Source Path & Remove IE Enhanced Security
Function AddSourcePathToLocalIntranetZone
{
    # Ensure that if we're running from a UNC path, the host portion is added to the Local Intranet zone so we don't get the "Open File - Security Warning"
    If ($env:dp0 -like "\\*")
    {
        WriteLine
        $safeHost = ($env:dp0 -split "\\")[2]
        log " - Adding `"$safeHost`" to local Intranet security zone..."
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Name $safeHost -ItemType Leaf -Force | Out-Null
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$safeHost" -Name "file" -value "1" -PropertyType dword -Force | Out-Null
        WriteLine
    }
}

Function RemoveIEEnhancedSecurity([xml]$xmlinput)
{
    WriteLine
    If ($xmlinput.Configuration.Install.Disable.IEEnhancedSecurity -eq "True")
    {
        log " - Disabling IE Enhanced Security..."
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name isinstalled -Value 0
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name isinstalled -Value 0
        Rundll32 iesetup.dll, IEHardenLMSettings,1,True
        Rundll32 iesetup.dll, IEHardenUser,1,True
        Rundll32 iesetup.dll, IEHardenAdmin,1,True
        If (Test-Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}")
        {
            Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
        }
        If (Test-Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}")
        {
            Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
        }

        #This doesn't always exist
        Remove-ItemProperty "HKCU:\SOFTWARE\Microsoft\Internet Explorer\Main" "First Home Page" -ErrorAction SilentlyContinue
    }
    Else
    {
        log " - Not configured to change IE Enhanced Security."
    }
    WriteLine
}
#EndRegion

#Region Disable Certificate Revocation List checks
Function DisableCRLCheck([xml]$xmlinput)
{
    WriteLine
    If ($xmlinput.Configuration.Install.Disable.CertificateRevocationListCheck -eq "True")
    {
        log " - Disabling Certificate Revocation List (CRL) check..."
        log "  - Registry..."
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\WinTrust\Trust Providers\Software Publishing" -Name State -PropertyType DWord -Value 146944 -Force | Out-Null
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\WinTrust\Trust Providers\Software Publishing" -Name State -PropertyType DWord -Value 146944 -Force | Out-Null
        log "  - Machine.config files..."
        [array]$frameworkVersions = "v2.0.50727","v4.0.30319" # For .Net 2.0 and .Net 4.0
        ForEach($bitsize in ("","64"))
        {
            foreach ($frameworkVersion in $frameworkVersions)
            {
                # Added a check below for $xml because on Windows Server 2012 machines, the path to $xml doesn't exist until the .Net Framework is installed, so the steps below were failing
                $xml = [xml](Get-Content "$env:windir\Microsoft.NET\Framework$bitsize\$frameworkVersion\CONFIG\Machine.config" -ErrorAction SilentlyContinue)
                if ($xml)
                {
                    if ($bitsize -eq "64") {log "   - $frameworkVersion..." }
                    If (!$xml.DocumentElement.SelectSingleNode("runtime"))
                    {
                        $runtime = $xml.CreateElement("runtime")
                        $xml.DocumentElement.AppendChild($runtime) | Out-Null
                    }
                    If (!$xml.DocumentElement.SelectSingleNode("runtime/generatePublisherEvidence"))
                    {
                        $gpe = $xml.CreateElement("generatePublisherEvidence")
                        $xml.DocumentElement.SelectSingleNode("runtime").AppendChild($gpe) | Out-Null
                    }
                    $xml.DocumentElement.SelectSingleNode("runtime/generatePublisherEvidence").SetAttribute("enabled","false") | Out-Null
                    $xml.Save("$env:windir\Microsoft.NET\Framework$bitsize\$frameworkVersion\CONFIG\Machine.config")
                    if ($bitsize -eq "64") {log "OK."}
                }
                else
                {
                    if ($bitsize -eq "") {$bitsize = "32"}
                    log "$bitsize-bit machine.config not found - could not disable CRL check."
                }
            }
        }
        log " - Done."
    }
    Else
    {
        log " - Not changing CRL check behavior."
    }
    WriteLine
}
#EndRegion

#Region Start logging to user's desktop
Function StartTracing ($server)
{
    If (!$isTracing)
    {
        # Look for an existing log file start time in the registry so we can re-use the same log file
		$regKey = Get-Item -Path "HKLM:\SOFTWARE\AutoSPInstaller\" -ErrorAction SilentlyContinue
		If ($regKey) {$script:Logtime = $regkey.GetValue("LogTime")}
		If ([string]::IsNullOrEmpty($logtime)) {$script:Logtime = Get-Date -Format yyyy-MM-dd_h-mm}
        If ($server) {$script:LogFile = "$env:USERPROFILE\Desktop\AutoSPInstaller-$server-$script:Logtime.rtf"}
        else {$script:LogFile = "$env:USERPROFILE\Desktop\AutoSPInstaller-$script:Logtime.rtf"}
        Start-Transcript -Path $logFile -Append -Force
        If ($?) {$script:isTracing = $true}
    }
}
#EndRegion

#Region Check Input File
Function CheckInput
{
    # Check that the config file exists.
    If (-not $(Test-Path -Path $inputFile -Type Leaf))
    {
        log " - Input file '" + $inputFile + "' does not exist."
    }
}
#EndRegion

#Region Check For or Create Config Files
Function CheckConfigFiles([xml]$xmlinput)
{
    #Region SharePoint config file
    if (Test-Path -Path (Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.Install.ConfigFile)))
    {
        # Just use the existing config file we found
        $script:configFile = Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.Install.ConfigFile)
        log " - Using existing config file:`n - $configFile"
    }
    else
    {
        Get-MajorVersionNumber $xmlinput
        # Write out a new config file based on defaults and the values provided in $inputFile
        $pidKey = $xmlinput.Configuration.Install.PIDKey
        # Do a rudimentary check on the presence and format of the product key
        if ($pidKey -notlike "?????-?????-?????-?????-?????")
        {
            throw " - The Product ID (PIDKey) is missing or badly formatted.`n - Check the value of <PIDKey> in `"$(Split-Path -Path $inputFile -Leaf)`" and try again."
        }
        $officeServerPremium = $xmlinput.Configuration.Install.SKU -replace "Enterprise","1" -replace "Standard","0"
        $installDir = $xmlinput.Configuration.Install.InstallDir
        # Set $installDir to the default value if it's not specified in $xmlinput
        if ([string]::IsNullOrEmpty($installDir)) {$installDir = "%PROGRAMFILES%\Microsoft Office Servers\"}
        $dataDir = $xmlinput.Configuration.Install.DataDir
        $dataDir = $dataDir.TrimEnd("\")
        # Set $dataDir to the default value if it's not specified in $xmlinput
        if ([string]::IsNullOrEmpty($dataDir)) {$dataDir = "%PROGRAMFILES%\Microsoft Office Servers\$env:spVer.0\Data"}
        $xmlConfig = @"
<Configuration>
  <Package Id="sts">
    <Setting Id="LAUNCHEDFROMSETUPSTS" Value="Yes"/>
  </Package>
  <Package Id="spswfe">
    <Setting Id="SETUPCALLED" Value="1"/>
    <Setting Id="OFFICESERVERPREMIUM" Value="$officeServerPremium" />
  </Package>
  <ARP ARPCOMMENTS="Installed with AutoSPInstaller (http://autospinstaller.com)" ARPCONTACT="brian@autospinstaller.com" />
  <Logging Type="verbose" Path="%temp%" Template="SharePoint Server Setup(*).log"/>
  <Display Level="basic" CompletionNotice="No" AcceptEula="Yes"/>
  <INSTALLLOCATION Value="$installDir"/>
  <DATADIR Value="$dataDir"/>
  <PIDKEY Value="$pidKey"/>
  <Setting Id="SERVERROLE" Value="APPLICATION"/>
  <Setting Id="USINGUIINSTALLMODE" Value="1"/>
  <Setting Id="SETUPTYPE" Value="CLEAN_INSTALL"/>
  <Setting Id="SETUP_REBOOT" Value="Never"/>
  <Setting Id="AllowWindowsClientInstall" Value="True"/>
</Configuration>
"@
        $script:configFile = Join-Path -Path (Get-Item $env:TEMP).FullName -ChildPath $($xmlinput.Configuration.Install.ConfigFile)
        log " - Writing $($xmlinput.Configuration.Install.ConfigFile) to $((Get-Item $env:TEMP).FullName)..."
        Set-Content -Path "$configFile" -Force -Value $xmlConfig
    }
    #EndRegion

    #Region OWA config file
    if ($xmlinput.Configuration.OfficeWebApps.Install -eq $true)
    {
        if (Test-Path -Path (Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.OfficeWebApps.ConfigFile)))
        {
            # Just use the existing config file we found
            $script:configFileOWA = Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.OfficeWebApps.ConfigFile)
            log " - Using existing OWA config file:`n - $configFileOWA"
        }
        else
        {
            # Write out a new config file based on defaults and the values provided in $inputFile
            $pidKeyOWA = $xmlinput.Configuration.OfficeWebApps.PIDKeyOWA
            # Do a rudimentary check on the presence and format of the product key
            if ($pidKeyOWA -notlike "?????-?????-?????-?????-?????")
            {
                throw " - The OWA Product ID (PIDKey) is missing or badly formatted.`n - Check the value of <PIDKeyOWA> in `"$(Split-Path -Path $inputFile -Leaf)`" and try again."
            }
            $xmlConfigOWA = @"
<Configuration>
	<Package Id="sts">
		<Setting Id="LAUNCHEDFROMSETUPSTS" Value="Yes"/>
	</Package>
    <ARP ARPCOMMENTS="Installed with AutoSPInstaller (http://autospinstaller.com)" ARPCONTACT="brian@autospinstaller.com" />
	<Logging Type="verbose" Path="%temp%" Template="Wac Server Setup(*).log"/>
	<Display Level="basic" CompletionNotice="no" />
	<Setting Id="SERVERROLE" Value="APPLICATION"/>
	<PIDKEY Value="$pidKeyOWA"/>
	<Setting Id="USINGUIINSTALLMODE" Value="1"/>
	<Setting Id="SETUPTYPE" Value="CLEAN_INSTALL"/>
	<Setting Id="SETUP_REBOOT" Value="Never"/>
	<Setting Id="AllowWindowsClientInstall" Value="True"/>
</Configuration>
"@
            $script:configFileOWA = Join-Path -Path (Get-Item $env:TEMP).FullName -ChildPath $($xmlinput.Configuration.OfficeWebApps.ConfigFile)
            log " - Writing $($xmlinput.Configuration.OfficeWebApps.ConfigFile) to $((Get-Item $env:TEMP).FullName)..."
            Set-Content -Path "$configFileOWA" -Force -Value $xmlConfigOWA
        }
    }
    #EndRegion

    #Region Project Server config file
    if ($xmlinput.Configuration.ProjectServer.Install -eq $true)
    {
        if (Test-Path -Path (Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.ProjectServer.ConfigFile)))
        {
            # Just use the existing config file we found
            $script:configFileProjectServer = Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.ProjectServer.ConfigFile)
            log " - Using existing ProjectServer config file:`n - $configFileProjectServer"
        }
        else
        {
            # Write out a new config file based on defaults and the values provided in $inputFile
            $pidKeyProjectServer = $xmlinput.Configuration.ProjectServer.PIDKeyProjectServer
            # Do a rudimentary check on the presence and format of the product key
            if ($pidKeyProjectServer -notlike "?????-?????-?????-?????-?????")
            {
                throw " - The Project Server Product ID (PIDKey) is missing or badly formatted.`n - Check the value of <PIDKeyProjectServer> in `"$(Split-Path -Path $inputFile -Leaf)`" and try again."
            }
            $xmlConfigProjectServer = @"
<Configuration>
    <Package Id="sts">
      <Setting Id="LAUNCHEDFROMSETUPSTS" Value="Yes"/>
    </Package>
      <Package Id="PJSRVWFE">
        <Setting Id="PSERVER" Value="1"/>
      </Package>
    <ARP ARPCOMMENTS="Installed with AutoSPInstaller (http://autospinstaller.com)" ARPCONTACT="brian@autospinstaller.com" />
    <Logging Type="verbose" Path="%temp%" Template="Project Server Setup(*).log"/>
    <Display Level="basic" CompletionNotice="No" AcceptEula="Yes"/>
	<Setting Id="SERVERROLE" Value="APPLICATION"/>
	<PIDKEY Value="$pidKeyProjectServer"/>
	<Setting Id="USINGUIINSTALLMODE" Value="1"/>
	<Setting Id="SETUPTYPE" Value="CLEAN_INSTALL"/>
	<Setting Id="SETUP_REBOOT" Value="Never"/>
	<Setting Id="AllowWindowsClientInstall" Value="True"/>
</Configuration>
"@
            $script:configFileProjectServer = Join-Path -Path (Get-Item $env:TEMP).FullName -ChildPath $($xmlinput.Configuration.ProjectServer.ConfigFile)
            log " - Writing $($xmlinput.Configuration.ProjectServer.ConfigFile) to $((Get-Item $env:TEMP).FullName)..."
            Set-Content -Path "$configFileProjectServer" -Force -Value $xmlConfigProjectServer
        }
    }
    #EndRegion

    #Region ForeFront answer file
    if (ShouldIProvision $xmlinput.Configuration.ForeFront -eq $true)
    {
        if (Test-Path -Path (Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.ForeFront.ConfigFile)))
        {
            # Just use the existing answer file we found
            $script:configFileForeFront = Join-Path -Path $env:dp0 -ChildPath $($xmlinput.Configuration.ForeFront.ConfigFile)
            log " - Using existing ForeFront answer file:`n - $configFileForeFront"
        }
        else
        {
            $farmAcct = $xmlinput.Configuration.Farm.Account.Username
            $farmAcctPWD = $xmlinput.Configuration.Farm.Account.Password
            # Write out a new answer file based on defaults and the values provided in $inputFile
            $xmlConfigForeFront = @"
<?xml version="1.0" encoding="utf-8"?>
<FSSAnswerFile>
  <AcceptLicense>true</AcceptLicense>
  <AcceptRestart>true</AcceptRestart>
  <AcceptReplacePreviousVS>true</AcceptReplacePreviousVS>
  <InstallType>Full</InstallType>
  <Folders>
    <!--Leave these empty to use the default values-->
    <ProgramFolder></ProgramFolder>
    <DataFolder></DataFolder>
  </Folders>
  <ProxyInformation>
    <UseProxy>false</UseProxy>
    <ServerName></ServerName>
    <Port>80</Port>
    <UserName></UserName>
    <Password></Password>
  </ProxyInformation>
  <SharePointInformation>
    <UserName>$farmAcct</UserName>
    <Password>$farmAcctPWD</Password>
  </SharePointInformation>
  <EnableAntiSpamNow>false</EnableAntiSpamNow>
  <EnableCustomerExperienceImprovementProgram>false</EnableCustomerExperienceImprovementProgram>
</FSSAnswerFile>
"@
            $script:configFileForeFront = Join-Path -Path (Get-Item $env:TEMP).FullName -ChildPath $($xmlinput.Configuration.ForeFront.ConfigFile)
            log " - Writing $($xmlinput.Configuration.ForeFront.ConfigFile) to $((Get-Item $env:TEMP).FullName)..."
            Set-Content -Path "$configFileForeFront" -Force -Value $xmlConfigForeFront
        }
    }
    #EndRegion
}
#EndRegion

#Region Check Installation Account
# ===================================================================================
# Func: CheckInstallAccount
# Desc: Check the install account and
# ===================================================================================
Function CheckInstallAccount([xml]$xmlinput)
{
    # Check if we are running under Farm Account credentials
    $farmAcct = $xmlinput.Configuration.Farm.Account.Username
    If ($env:USERDOMAIN+"\"+$env:USERNAME -eq $farmAcct)
    {
        log " - WARNING: Running install using Farm Account: $farmAcct"
    }
}
#EndRegion

#Region Disable Loopback Check and Services
# ===================================================================================
# Func: DisableLoopbackCheck
# Desc: Disable Loopback Check
# ===================================================================================
Function DisableLoopbackCheck([xml]$xmlinput)
{
    # Disable the Loopback Check on stand alone demo servers.
    # This setting usually kicks out a 401 error when you try to navigate to sites that resolve to a loopback address e.g.  127.0.0.1
    If ($xmlinput.Configuration.Install.Disable.LoopbackCheck -eq $true)
    {
        WriteLine
        log " - Disabling Loopback Check..."

        $lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa"
        $lsaPathValue = Get-ItemProperty -path $lsaPath
        If (-not ($lsaPathValue.DisableLoopbackCheck -eq "1"))
        {
            New-ItemProperty HKLM:\System\CurrentControlSet\Control\Lsa -Name "DisableLoopbackCheck" -value "1" -PropertyType dword -Force | Out-Null
        }
        WriteLine
    }
}

# ===================================================================================
# Func: DisableServices
# Desc: Disable Unused Services or set status to Manual
# ===================================================================================
Function DisableServices([xml]$xmlinput)
{
    If ($xmlinput.Configuration.Install.Disable.UnusedServices -eq $true)
    {
        WriteLine
        log " - Setting services Spooler, AudioSrv and TabletInputService to Manual..."

        $servicesToSetManual = "Spooler","AudioSrv","TabletInputService"
        ForEach ($svcName in $servicesToSetManual)
        {
            $svc = get-wmiobject win32_service | where-object {$_.Name -eq $svcName}
            $svcStartMode = $svc.StartMode
            $svcState = $svc.State
            If (($svcState -eq "Running") -and ($svcStartMode -eq "Auto"))
            {
                Stop-Service -Name $svcName
                Set-Service -name $svcName -StartupType Manual
                log " - Service $svcName is now set to Manual start"
            }
            Else
            {
                log " - $svcName is already stopped and set Manual, no action required."
            }
        }

        log " - Setting unused services WerSvc to Disabled..."
        $servicesToDisable = "WerSvc"
        ForEach ($svcName in $servicesToDisable)
        {
            $svc = get-wmiobject win32_service | where-object {$_.Name -eq $svcName}
            $svcStartMode = $svc.StartMode
            $svcState = $svc.State
            If (($svcState -eq "Running") -and (($svcStartMode -eq "Auto") -or ($svcStartMode -eq "Manual")))
            {
                Stop-Service -Name $svcName
                Set-Service -name $svcName -StartupType Disabled
                log " - Service $svcName is now stopped and disabled."
            }
            Else
            {
                log " - $svcName is already stopped and disabled, no action required."
            }
        }
        log " - Finished disabling services."
        WriteLine
    }
}
#EndRegion


#Region Install Office Web Apps 2010
# ===================================================================================
# Func: InstallOfficeWebApps2010
# Desc: Installs the OWA binaries in unattended mode
# From: Ported over by user http://www.codeplex.com/site/users/view/cygoh originally from the InstallSharePoint function, fixed up by brianlala
# Originally posted on: http://autospinstaller.codeplex.com/discussions/233530
# ===================================================================================
Function InstallOfficeWebApps2010([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    If ($xmlinput.Configuration.OfficeWebApps.Install -eq $true -and $env:spVer -eq "14") # Check for SP2010
    {
        WriteLine
        If (Test-Path "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\TEMPLATE\FEATURES\OfficeWebApps\feature.xml") # Crude way of checking if Office Web Apps is already installed
        {
            log " - Office Web Apps binaries appear to be already installed - skipping install."
        }
        Else
        {
            $spYears = @{"14" = "2010"; "15" = "2013"}
            $spYear = $spYears.$env:spVer
            # Install Office Web Apps Binaries
            If (Test-Path "$bits\$spYear\OfficeWebApps\setup.exe")
            {
                log " - Installing Office Web Apps binaries..." 
                $startTime = Get-Date
                Start-Process "$bits\$spYear\OfficeWebApps\setup.exe" -ArgumentList "/config `"$configFileOWA`"" -WindowStyle Minimized
                Show-Progress -Process setup -Color Blue -Interval 5
                $delta,$null = (New-TimeSpan -Start $startTime -End (Get-Date)).ToString() -split "\."
                log " - Office Web Apps setup completed in $delta."
                If (-not $?) {
                    Throw " - Error $LASTEXITCODE occurred running $bits\$spYear\OfficeWebApps\setup.exe"
                }
                # Parsing most recent Office Web Apps Setup log for errors or restart requirements, since $LASTEXITCODE doesn't seem to work...
                $setupLog = Get-ChildItem -Path (Get-Item $env:TEMP).FullName | ? {$_.Name -like "Wac Server Setup*"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
                If ($setupLog -eq $null)
                {
                    Throw " - Could not find Office Web Apps Setup log file!"
                }
                # Get error(s) from log
                $setupLastError = $setupLog | select-string -SimpleMatch -Pattern "Error:" | Select-Object -Last 1 #| ? {$_.Line -notlike "*Startup task*"}
                If ($setupLastError)
                {
                    log $setupLastError.Line
                    Invoke-Item -Path "$((Get-Item $env:TEMP).FullName)\$setupLog"
                    Throw " - Review the log file and try to correct any error conditions."
                }
                # Look for restart requirement in log
                $setupRestartNotNeeded = $setupLog | select-string -SimpleMatch -Pattern "System reboot is not pending."
                If (!($setupRestartNotNeeded))
                {
                    Throw " - Office Webapps setup requires a restart. Run the script again after restarting to continue."
                }
                log " - Waiting for SharePoint Products and Technologies Wizard to launch..." 
                While ((Get-Process |?{$_.ProcessName -like "psconfigui*"}) -eq $null)
                {
                    log "." 
                    Start-Sleep 1
                }
                # The Connect-SPConfigurationDatabase cmdlet throws an error about an "upgrade required" if we don't at least *launch* the Wizard, so we wait to let it launch, then kill it.
                Start-Sleep 10
                log "OK."
                log " - Exiting Products and Technologies Wizard - using PowerShell instead!"
                Stop-Process -Name psconfigui
            }
            Else
            {
                Throw " - Install path $bits\$spYear\OfficeWebApps not found!!"
            }
        }
        WriteLine
    }
}
#EndRegion

#Region Install Project Server
# ===================================================================================
# Func: InstallProjectServer
# Desc: Installs the Project Server binaries in unattended mode
# ===================================================================================
Function InstallProjectServer([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    If ($xmlinput.Configuration.ProjectServer.Install -eq $true -and $env:SPVer -eq "15") # Check for SP2013 since we don't support installing Project Server 2010 at this point
    {
        WriteLine
        # Create a hash table with major version to product year mappings
        $spYears = @{"14" = "2010"; "15" = "2013"}
        $spYear = $spYears.$env:spVer
        # There has to be a better way to check whether Project Server is installed...
        $projectServerInstalled = Test-Path -Path "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\CONFIG\BIN\Microsoft.ProjectServer.dll"
        If ($projectServerInstalled)
        {
            log " - Project Server $spYear binaries appear to be already installed - skipping installation."
        }
        Else
        {
            # Install Project Server Binaries
            If (Test-Path "$bits\$spYear\ProjectServer\setup.exe")
            {
                log " - Installing Project Server $spYear binaries..." 
                $startTime = Get-Date
                Start-Process "$bits\$spYear\ProjectServer\setup.exe" -ArgumentList "/config `"$configFileProjectServer`"" -WindowStyle Minimized
                Show-Progress -Process setup -Color Blue -Interval 5
                $delta,$null = (New-TimeSpan -Start $startTime -End (Get-Date)).ToString() -split "\."
                log " - Project Server $spYear setup completed in $delta."
                If (-not $?)
                {
                    Throw " - Error $LASTEXITCODE occurred running $bits\$spYear\ProjectServer\setup.exe"
                }

                # Parsing most recent Project Server Setup log for errors or restart requirements, since $LASTEXITCODE doesn't seem to work...
                $setupLog = Get-ChildItem -Path (Get-Item $env:TEMP).FullName | ? {$_.Name -like "Project Server Setup*"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
                If ($setupLog -eq $null)
                {
                    Throw " - Could not find Project Server Setup log file!"
                }

                # Get error(s) from log
                $setupLastError = $setupLog | Select-String -SimpleMatch -Pattern "Error:" | Select-Object -Last 1
                $setupSuccess = $setupLog | Select-String -SimpleMatch -Pattern "Successfully installed package: pserver"
                if (!$setupSuccess) {$setupSuccess = $setupLog | Select-String -SimpleMatch -Pattern "Successfully configured package: pserver"} # In case we are just configuring pre-installed or partially-installed product
                If ($setupLastError -and !$setupSuccess)
                {
                    log $setupLastError.Line
                    Invoke-Item -Path "$((Get-Item $env:TEMP).FullName)\$setupLog"
                    Throw " - Review the log file and try to correct any error conditions."
                }
                # Look for restart requirement in log, but only if we installed fresh vs. just configuring
                if ($setupSuccess -like "*installed*")
                {
                    $setupRestartNotNeeded = $setupLog | select-string -SimpleMatch -Pattern "System reboot is not pending."
                    If (!$setupRestartNotNeeded)
                    {
                        Throw " - Project Server setup requires a restart. Run the script again after restarting to continue."
                    }
                }
                log " - Waiting for SharePoint Products and Technologies Wizard to launch..." 
                While ((Get-Process |?{$_.ProcessName -like "psconfigui*"}) -eq $null)
                {
                    log "." 
                    Start-Sleep 1
                }
                log "OK."
                log " - Exiting Products and Technologies Wizard - using PowerShell instead!"
                Stop-Process -Name psconfigui
            }
            Else
            {
                log "Project Server installation requested, but install path $bits\$spYear\ProjectServer not found!!"
                # pause "continue"
                # MK: added throw
                throw "Project Server installation requested, but install path $bits\$spYear\ProjectServer not found!!"
            }
        }
        WriteLine
    }
}
#EndRegion

#Region Configure Office Web Apps 2010
Function ConfigureOfficeWebApps([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    If ($xmlinput.Configuration.OfficeWebApps.Install -eq $true -and $env:spVer -eq "14") # Check for SP2010
    {
        WriteLine
        Try
        {
            log " - Configuring Office Web Apps..."
            # Install Help Files
            log " - Installing Help Collection..."
            Install-SPHelpCollection -All
            ##WaitForHelpInstallToFinish
            # Install application content
            log " - Installing Application Content..."
            Install-SPApplicationContent
            # Secure resources
            log " - Securing Resources..."
            Initialize-SPResourceSecurity
            # Install Services
            log " - Installing Services..."
            Install-SPService
            If (!$?) {Throw}
            # Install (all) features
            log " - Installing Features..."
            $features = Install-SPFeature -AllExistingFeatures -Force
        }
        Catch
        {
            log $_
            Throw " - Error configuring Office Web Apps!"
        }
        WriteLine
    }
}
#EndRegion

#Region Install Language Packs
# ===================================================================================
# Func: Install Language Packs
# Desc: Install language packs and report on any languages installed
# ===================================================================================
Function InstallLanguagePacks([xml]$xmlinput)
{
    WriteLine
    Get-MajorVersionNumber $xmlinput
    $spYears = @{"14" = "2010"; "15" = "2013"}
    $spYear = $spYears.$env:spVer
    #Get installed languages from registry (HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Office Server\$env:spVer.0\InstalledLanguages)
    $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\$env:spVer.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}   # Look for extracted language packs
    $extractedLanguagePacks = (Get-ChildItem -Path "$bits\$spYear\LanguagePacks" -Name -Include "??-??" -ErrorAction SilentlyContinue)
    $serverLanguagePacks = (Get-ChildItem -Path "$bits\$spYear\LanguagePacks" -Name -Include ServerLanguagePack_*.exe -ErrorAction SilentlyContinue)
    If ($extractedLanguagePacks)
    {
        log " - Installing SharePoint Language Packs:"
        ForEach ($languagePackFolder in $extractedLanguagePacks)
        {
            $language = $installedOfficeServerLanguages | ? {$_ -eq $languagePackFolder}
            If (!$language)
            {
                log "  - Installing extracted language pack $languagePackFolder..." 
                $startTime = Get-Date
                Start-Process -WorkingDirectory "$bits\$spYear\LanguagePacks\$languagePackFolder\" -FilePath "setup.exe" -ArgumentList "/config $bits\$spYear\LanguagePacks\$languagePackFolder\Files\SetupSilent\config.xml"
                Show-Progress -Process setup -Color Blue -Interval 5
                $delta,$null = (New-TimeSpan -Start $startTime -End (Get-Date)).ToString() -split "\."
                log "  - Language pack $languagePackFolder setup completed in $delta."
            }
        }
        log " - Language Pack installation complete."
    }
    # Look for Server language pack installers
    ElseIf ($serverLanguagePacks)
    {
        log " - Installing SharePoint Language Packs:"
        ForEach ($languagePack in $serverLanguagePacks)
        {
            # Slightly convoluted check to see if language pack is already installed, based on name of language pack file.
            # This only works if you've renamed your language pack(s) to follow the convention "ServerLanguagePack_XX-XX.exe" where <XX-XX> is a culture such as <en-us>.
            $language = $installedOfficeServerLanguages | ? {$_ -eq (($languagePack -replace "ServerLanguagePack_","") -replace ".exe","")}
            If (!$language)
            {
                log " - Installing $languagePack..." 
                $startTime = Get-Date
                Start-Process -FilePath "$bits\$spYear\LanguagePacks\$languagePack" -ArgumentList "/quiet /norestart"
                Show-Progress -Process $($languagePack -replace ".exe", "") -Color Blue -Interval 5
                $delta,$null = (New-TimeSpan -Start $startTime -End (Get-Date)).ToString() -split "\."
                log " - Language pack $languagePack setup completed in $delta."
                $language = (($languagePack -replace "ServerLanguagePack_","") -replace ".exe","")
                # Install Foundation Language Pack SP1, then Server Language Pack SP1, if found
                If (Get-ChildItem -Path "$bits\$spYear\LanguagePacks" -Name -Include spflanguagepack2010sp1-kb2460059-x64-fullfile-$language.exe -ErrorAction SilentlyContinue)
                {
                    log " - Installing Foundation language pack SP1 for $language..." 
                    Start-Process -WorkingDirectory "$bits\$spYear\LanguagePacks\" -FilePath "spflanguagepack2010sp1-kb2460059-x64-fullfile-$language.exe" -ArgumentList "/quiet /norestart"
                    Show-Progress -Process spflanguagepack2010sp1-kb2460059-x64-fullfile-$language -Color Blue -Interval 5
                    # Install Server Language Pack SP1, if found
                    If (Get-ChildItem -Path "$bits\$spYear\LanguagePacks" -Name -Include serverlanguagepack2010sp1-kb2460056-x64-fullfile-$language.exe -ErrorAction SilentlyContinue)
                    {
                        log " - Installing Server language pack SP1 for $language..." 
                        Start-Process -WorkingDirectory "$bits\$spYear\LanguagePacks\" -FilePath "serverlanguagepack2010sp1-kb2460056-x64-fullfile-$language.exe" -ArgumentList "/quiet /norestart"
                        Show-Progress -Process serverlanguagepack2010sp1-kb2460056-x64-fullfile-$language -Color Blue -Interval 5
                    }
                    Else
                    {
                        log "Server Language Pack SP1 not found for $language!"
                        log "You must install it for the language service pack patching process to be complete."
                    }
                }
                Else {log " - No Language Pack service packs found."}
            }
            Else
            {
                log " - Language $language already appears to be installed, skipping."
            }
        }
        log " - Language Pack installation complete."
    }
    Else
    {
        log " - No language packs found in $bits\$spYear\LanguagePacks, skipping."
    }

    # Get and note installed languages
    $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\$env:spVer.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}
    log " - Currently installed languages:"
    ForEach ($language in $installedOfficeServerLanguages)
    {
        log "  -" ([System.Globalization.CultureInfo]::GetCultureInfo($language).DisplayName)
    }
    WriteLine
}
#EndRegion

#Region Install Updates
# ===================================================================================
# Func: InstallUpdates
# Desc: Install SharePoint Updates (CUs and Service Packs) to work around slipstreaming issues
# ===================================================================================
Function InstallUpdates
{
    WriteLine
    log " - Looking for SharePoint updates to install..."
    Get-MajorVersionNumber $xmlinput
    $spYears = @{"14" = "2010"; "15" = "2013"}
    $spYear = $spYears.$env:spVer
    # Result codes below are from http://technet.microsoft.com/en-us/library/cc179058(v=office.14).aspx
    $oPatchInstallResultCodes = @{"17301" = "Error: General Detection error";
                                  "17302" = "Error: Applying patch";
                                  "17303" = "Error: Extracting file";
                                  "17021" = "Error: Creating temp folder";
                                  "17022" = "Success: Reboot flag set";
                                  "17023" = "Error: User cancelled installation";
                                  "17024" = "Error: Creating folder failed";
                                  "17025" = "Patch already installed";
                                  "17026" = "Patch already installed to admin installation";
                                  "17027" = "Installation source requires full file update";
                                  "17028" = "No product installed for contained patch";
                                  "17029" = "Patch failed to install";
                                  "17030" = "Detection: Invalid CIF format";
                                  "17031" = "Detection: Invalid baseline";
                                  "17034" = "Error: Required patch does not apply to the machine";
                                  "17038" = "You do not have sufficient privileges to complete this installation for all users of the machine. Log on as administrator and then retry this installation";
                                  "17044" = "Installer was unable to run detection for this package"}
    if ($spYear -eq "2010")
    {
        $sp2010SP1 = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "officeserver2010sp1-kb2460045-x64-fullfile-en-us.exe" -Recurse -ErrorAction SilentlyContinue
        # In case we find more than one (e.g. in subfolders), grab the first one
        if ($sp2010SP1 -is [system.array]) {$sp2010SP1 = $sp2010SP1[0]}
        $sp2010June2013CU = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "ubersrv2010-kb2817527-fullfile-x64-glb.exe" -Recurse -ErrorAction SilentlyContinue
        # In case we find more than one (e.g. in subfolders), grab the first one
        if ($sp2010June2013CU -is [system.array]) {$sp2010June2013CU = $sp2010June2013CU[0]}
        $sp2010SP2 = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "oserversp2010-kb2687453-fullfile-x64-en-us.exe" -Recurse -ErrorAction SilentlyContinue
        # In case we find more than one (e.g. in subfolders), grab the first one
        if ($sp2010SP2 -is [system.array]) {$sp2010SP2 = $sp2010SP2[0]}
        # Get installed SharePoint languages, so we can determine which language pack updates to apply
        $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\$env:spVer.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}
        # First & foremost, install SP2 if it's there
        if ($sp2010SP2)
        {
            InstallSpecifiedUpdate $sp2010SP2 "Service Pack 2"
        }
        # Otherwise, install SP1 as it is a required baseline for any post-June 2012 CUs
        elseif ($sp2010SP1)
        {
            InstallSpecifiedUpdate $sp2010SP1 "Service Pack 1"
        }
        # Next, install the June 2013 CU if it's found in \Updates
        if ($sp2010June2013CU)
        {
            InstallSpecifiedUpdate $sp2010June2013CU "June 2013 CU"
        }
        # Now find any language pack service packs, using the naming conventions for both SP1 and SP2
        $sp2010LPServicePacks = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include serverlanguagepack2010sp*.exe,oslpksp2010*.exe -Recurse -ErrorAction SilentlyContinue | Sort-Object -Descending
        # Now install language pack service packs - only if they match a currently-installed SharePoint language
        foreach ($installedOfficeServerLanguage in $installedOfficeServerLanguages)
        {
            [array]$sp2010LPServicePacksToInstall += $sp2010LPServicePacks | Where-Object {$_ -like "*$installedOfficeServerLanguage*"}
        }
        if ($sp2010LPServicePacksToInstall)
        {
            foreach ($sp2010LPServicePack in $sp2010LPServicePacksToInstall)
            {
                InstallSpecifiedUpdate $sp2010LPServicePack "Language Pack Service Pack"
            }
        }
        if ($xmlinput.Configuration.OfficeWebApps.Install -eq $true)
        {
            $sp2010OWAUpdates = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include wac*.exe -Recurse -ErrorAction SilentlyContinue | Sort-Object -Descending
            if ($sp2010OWAUpdates.Count -ge 1)
            {
                foreach ($sp2010OWAUpdate in $sp2010OWAUpdates)
                {
                    InstallSpecifiedUpdate $sp2010OWAUpdate "Office Web Apps Update"
                }
            }
        }
    }
    if ($spYear -eq "2013")
    {
        # Do SP1 first, if it's found
        $sp2013SP1 = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "officeserversp2013-kb2880552-fullfile-x64-en-us.exe" -Recurse -ErrorAction SilentlyContinue
        if ($sp2013SP1)
        {
            # In case we find more than one (e.g. in subfolders), grab the first one
            if ($sp2013SP1 -is [system.array]) {$sp2013SP1 = $sp2013SP1[0]}
            InstallSpecifiedUpdate $sp2013SP1 "Service Pack 1"
        }
        if ($xmlinput.Configuration.ProjectServer.Install -eq $true)
        {
            if ($sp2013SP1)
            {
                # Look for Project Server 2013 SP1, since we have SharePoint Server SP1
                $sp2013ProjectSP1 = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "projectserversp2013-kb2817434-fullfile-x64-en-us.exe" -Recurse -ErrorAction SilentlyContinue
                if ($sp2013ProjectSP1)
                {
                    # In case we find more than one (e.g. in subfolders), grab the first one
                    if ($sp2013ProjectSP1 -is [system.array]) {$sp2013ProjectSP1 = $sp2013ProjectSP1[0]}
                    InstallSpecifiedUpdate $sp2013ProjectSP1 "Project Server Service Pack 1"
                }
                else
                {
                    log "Project Server Service Pack 1 wasn't found. Since SharePoint itself will be updated to SP1, you should download and install Project Server 2013 SP1 for your server/farm to be completely patched."
                }
            }
            else
            {
                # Look for a Project Server March PU
                $marchPublicUpdate = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "ubersrvprjsp2013-kb2768001-fullfile-x64-glb.exe" -Recurse -ErrorAction SilentlyContinue
                if (!$marchPublicUpdate)
                {
                    # In case we forgot to include the Project Server March PU, just look for the SharePoint Server March PU
                    $marchPublicUpdate = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "ubersrvsp2013-kb2767999-fullfile-x64-glb.exe" -Recurse -ErrorAction SilentlyContinue
                    if ($marchPublicUpdate)
                    {
                        log "The Project Server March PU wasn't found, but the regular SharePoint Server March PU was, and will be applied. However you should download and install the full Project Server March PU and any subsequent updates afterwards for your server/farm to be completely patched."
                    }
                }
            }
        }
        else
        {
            if (!$sp2013SP1)
            {
                # Look for the SharePoint Server March PU
                $marchPublicUpdate = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include "ubersrvsp2013-kb2767999-fullfile-x64-glb.exe" -Recurse -ErrorAction SilentlyContinue
            }
        }
        if ($marchPublicUpdate)
        {
            # In case we find more than one (e.g. in subfolders), grab the first one
            if ($marchPublicUpdate -is [system.array]) {$marchPublicUpdate = $marchPublicUpdate[0]}
            InstallSpecifiedUpdate $marchPublicUpdate "March 2013 Public Update"
        }
    }
    # Get all CUs except the March 2013 PU for SharePoint / Project Server 2013 and the June 2013 CU for SharePoint 2010
    $cumulativeUpdates = Get-ChildItem -Path "$bits\$spYear\Updates" -Name -Include office2010*.exe,ubersrv*.exe,ubersts*.exe,*pjsrv*.exe,sharepointsp2013*.exe,coreserver201*.exe -Recurse -ErrorAction SilentlyContinue | Where-Object {$_ -notlike "*ubersrvsp2013-kb2767999-fullfile-x64-glb.exe" -and $_ -notlike "*ubersrvprjsp2013-kb2768001-fullfile-x64-glb.exe" -and $_ -notlike "*ubersrv2010-kb2817527-fullfile-x64-glb.exe"} | Sort-Object -Descending
    # Filter out Project Server updates if we aren't installing Project Server
    if ($xmlinput.Configuration.ProjectServer.Install -ne $true)
    {
        $cumulativeUpdates = $cumulativeUpdates | Where-Object {($_ -notlike "*prj*.exe") -and ($_ -notlike "*pjsrv*.exe")}
    }
    # Look for Server Cumulative Update installers
    if ($cumulativeUpdates)
    {
        # Display warning about missing March 2013 PU only if we are actually installing SP2013 and SP1 isn't already installed and the SP1 installer isn't found
        if ($spYear -eq "2013" -and !($sp2013SP1 -or (CheckFor2013SP1)) -and !$marchPublicUpdate)
        {
            log "  - Note: the March 2013 PU package wasn't found in ..\$spYear\Updates; it may need to be installed first if it wasn't slipstreamed."
        }
        # Now attempt to install any other CUs found in the \Updates folder
        log "  - Installing SharePoint Cumulative Updates:"
        ForEach ($cumulativeUpdate in $cumulativeUpdates)
        {
            # Get the file name only, in case $cumulativeUpdate includes part of a path (e.g. is in a subfolder)
            $splitCumulativeUpdate = Split-Path -Path $cumulativeUpdate -Leaf
            log "   - Installing $splitCumulativeUpdate..." 
            $startTime = Get-Date
            Start-Process -FilePath "$bits\$spYear\Updates\$cumulativeUpdate" -ArgumentList "/passive /norestart"
            Show-Progress -Process $($splitCumulativeUpdate -replace ".exe", "") -Color Blue -Interval 5
            $delta,$null = (New-TimeSpan -Start $startTime -End (Get-Date)).ToString() -split "\."
            $oPatchInstallLog = Get-ChildItem -Path (Get-Item $env:TEMP).FullName | ? {$_.Name -like "opatchinstall*.log"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
            # Get install result from log
            $oPatchInstallResultMessage = $oPatchInstallLog | Select-String -SimpleMatch -Pattern "OPatchInstall: Property 'SYS.PROC.RESULT' value" | Select-Object -Last 1
            If (!($oPatchInstallResultMessage -like "*value '0'*")) # Anything other than 0 means unsuccessful but that's not necessarily a bad thing
            {
                $null,$oPatchInstallResultCode = $oPatchInstallResultMessage.Line -split "OPatchInstall: Property 'SYS.PROC.RESULT' value '"
                $oPatchInstallResultCode = $oPatchInstallResultCode.TrimEnd("'")
                # OPatchInstall: Property 'SYS.PROC.RESULT' value '17028' means the patch was not needed or installed product was newer
                if ($oPatchInstallResultCode -eq "17028") {log "   - Patch not required; installed product is same or newer."}
                elseif ($oPatchInstallResultCode -eq "17031")
                {
                    log "Error 17031: Detection: Invalid baseline"
                    log "A baseline patch (e.g. March 2013 PU for SP2013, SP1 for SP2010) is missing!"
                    log "   - Either slipstream the missing patch first, or include the patch package in the ..\$spYear\Updates folder."
                    # Pause "continue"
                    # MK: added throw
                    throw "ERROR: Error 17031: Detection: Invalid baseline"
                }
                else {log "   - $($oPatchInstallResultCodes.$oPatchInstallResultCode)"}
            }
            log "   - $splitCumulativeUpdate install completed in $delta."
        }
        log "  - Cumulative Update installation complete."
    }
    # Finally, install SP2 last in case we applied the June 2013 CU which would not have properly detected SP2...
    if ($sp2010SP2 -and $sp2010June2013CU -and $spYear -eq "2010")
    {
        InstallSpecifiedUpdate $sp2010SP2 "Service Pack 2"
    }
    if (!$marchPublicUpdate -and !$cumulativeUpdates)
    {
        log " - No other updates found in $bits\$spYear\Updates, proceeding..."
    }
    else
    {
        log " - Finished installing SharePoint updates."
    }
    WriteLine
}
# ===================================================================================
# Func: InstallSpecifiedUpdate
# Desc: Installs a specified SharePoint Updates (CU or Service Pack)
# ===================================================================================
Function InstallSpecifiedUpdate ($updateFile, $updateName)
{
    # Get the file name only, in case $updateFile includes part of a path (e.g. is in a subfolder)
    $splitUpdateFile = Split-Path -Path $updateFile -Leaf
    log "  - Installing SP$spYear $updateName $splitUpdateFile..." 
    $startTime = Get-Date
    Start-Process -FilePath "$bits\$spYear\Updates\$updateFile" -ArgumentList "/passive /norestart"
    Show-Progress -Process $($splitUpdateFile -replace ".exe", "") -Color Blue -Interval 5
    $delta,$null = (New-TimeSpan -Start $startTime -End (Get-Date)).ToString() -split "\."
    $oPatchInstallLog = Get-ChildItem -Path (Get-Item $env:TEMP).FullName | ? {$_.Name -like "opatchinstall*.log"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
    # Get install result from log
    $oPatchInstallResultMessage = $oPatchInstallLog | Select-String -SimpleMatch -Pattern "OPatchInstall: Property 'SYS.PROC.RESULT' value" | Select-Object -Last 1
    If (!($oPatchInstallResultMessage -like "*value '0'*")) # Anything other than 0 means unsuccessful but that's not necessarily a bad thing
    {
        $null,$oPatchInstallResultCode = $oPatchInstallResultMessage.Line -split "OPatchInstall: Property 'SYS.PROC.RESULT' value '"
        $oPatchInstallResultCode = $oPatchInstallResultCode.TrimEnd("'")
        # OPatchInstall: Property 'SYS.PROC.RESULT' value '17028' means the patch was not needed or installed product was newer
        if ($oPatchInstallResultCode -eq "17028") {log "   - Patch not required; installed product is same or newer."}
        elseif ($oPatchInstallResultCode -eq "17031")
        {
            log "Error 17031: Detection: Invalid baseline"
            log "A baseline patch (e.g. March 2013 PU for SP2013, SP1 for SP2010) is missing!"
            log "   - Either slipstream the missing patch first, or include the patch package in the ..\$spYear\Updates folder."
            # Pause "continue"
            # MK: added throw
            throw "Error 17031: Detection: Invalid baseline"
        }
        else {log "  - $($oPatchInstallResultCodes.$oPatchInstallResultCode)"}
    }
    log "  - $updateName install completed in $delta."
}
#EndRegion

#Region Configure Farm Account
# ===================================================================================
# Func: ConfigureFarmAdmin
# Desc: Sets up the farm account and adds to Local admins if needed
# ===================================================================================
Function ConfigureFarmAdmin([xml]$xmlinput)
{
    # Per Spencer Harbar, the farm account needs to be a local admin when provisioning distributed cache, so if it's being requested for provisioning we'll add it to Administrators here
    If (($xmlinput.Configuration.Farm.Account.getAttribute("AddToLocalAdminsDuringSetup") -eq $true) -or (ShouldIProvision $xmlinput.Configuration.ServiceApps.UserProfileServiceApp -eq $true) -or (ShouldIProvision $xmlinput.Configuration.Farm.Services.DistributedCache -eq $true))
    {
        WriteLine
        # Add to Admins Group
        $farmAcct = $xmlinput.Configuration.Farm.Account.Username
        log " - Adding $farmAcct to local Administrators" 
        If ($xmlinput.Configuration.Farm.Account.LeaveInLocalAdmins -ne $true) {log " (only for install)..."}
        Else {log " ..."}
        $farmAcctDomain,$farmAcctUser = $farmAcct -Split "\\"
        Try
        {
            $builtinAdminGroup = Get-AdministratorsGroup
            ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Add("WinNT://$farmAcctDomain/$farmAcctUser")
            If (-not $?) {Throw}
            # Restart the SPTimerV4 service if it's running, so it will pick up the new credential
            If ((Get-Service -Name SPTimerV4).Status -eq "Running")
            {
                log " - Restarting SharePoint Timer Service..."
                Restart-Service SPTimerV4
            }
        }
        Catch {log " - $farmAcct is already a member of `"$builtinAdminGroup`"."}
        WriteLine
    }
}

# ===================================================================================
# Func: GetFarmCredentials
# Desc: Return the credentials for the farm account, prompt the user if need more info
# ===================================================================================
Function GetFarmCredentials([xml]$xmlinput)
{
    $farmAcct = $xmlinput.Configuration.Farm.Account.Username
    $farmAcctPWD = $xmlinput.Configuration.Farm.Account.Password
    If (!($farmAcct) -or $farmAcct -eq "" -or !($farmAcctPWD) -or $farmAcctPWD -eq "")
    {
        # MK: added throw
        # log  " - Prompting for Farm Account:"
        # $script:farmCredential = $host.ui.PromptForCredential("Farm Setup", "Enter Farm Account Credentials:", "$farmAcct", "NetBiosUserName" )
        throw "ERROR: Farm Account is missing!"
    }
    Else
    {
        $secPassword = ConvertTo-SecureString "$farmAcctPWD" -AsPlaintext -Force
        $script:farmCredential = New-Object System.Management.Automation.PsCredential $farmAcct,$secPassword
    }
    Return $farmCredential
}
#EndRegion

#Region Get Farm Passphrase
Function GetFarmPassphrase([xml]$xmlinput)
{
    $farmPassphrase = $xmlinput.Configuration.Farm.Passphrase
    If (!($farmPassphrase) -or ($farmPassphrase -eq ""))
    {
        $farmPassphrase = Read-Host -Prompt " - Please enter the farm passphrase now" -AsSecureString
        If (!($farmPassphrase) -or ($farmPassphrase -eq "")) { Throw " - Farm passphrase is required!" }
    }
    Return $farmPassphrase
}
#EndRegion

#Region Get Secure Farm Passphrase
# ===================================================================================
# Func: GetSecureFarmPassphrase
# Desc: Return the Farm Phrase as a secure string
# ===================================================================================
Function GetSecureFarmPassphrase([xml]$xmlinput)
{
    If (!($farmPassphrase) -or ($farmPassphrase -eq ""))
    {
        $farmPassphrase = GetFarmPassPhrase $xmlinput
    }
    If ($farmPassPhrase.GetType().Name -ne "SecureString")
    {
        $secPhrase = ConvertTo-SecureString $farmPassphrase -AsPlaintext -Force
    }
    Else {$secPhrase = $farmPassphrase}
    Return $secPhrase
}
#EndRegion

#Region Update Service Process Identity

# ====================================================================================
# Func: UpdateProcessIdentity
# Desc: Updates the account a specified service runs under to the general app pool account
# ====================================================================================
Function UpdateProcessIdentity ($serviceToUpdate)
{
    $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
    # Managed Account
    $managedAccountGen = Get-SPManagedAccount | Where-Object {$_.UserName -eq $($spservice.username)}
    if ($managedAccountGen -eq $null) { Throw " - Managed Account $($spservice.username) not found" }
    if ($serviceToUpdate.Service) {$serviceToUpdate = $serviceToUpdate.Service}
    if ($serviceToUpdate.ProcessIdentity.Username -ne $managedAccountGen.UserName)
    {
        log " - Updating $($serviceToUpdate.TypeName) to run as $($managedAccountGen.UserName)..." 
        # Set the Process Identity to our general App Pool Account; otherwise it's set by default to the Farm Account and gives warnings in the Health Analyzer
        $serviceToUpdate.ProcessIdentity.CurrentIdentityType = "SpecificUser"
        $serviceToUpdate.ProcessIdentity.ManagedAccount = $managedAccountGen
        $serviceToUpdate.ProcessIdentity.Update()
        $serviceToUpdate.ProcessIdentity.Deploy()
        log "Done."
    }
    else {log " - $($serviceToUpdate.TypeName) is already configured to run as $($managedAccountGen.UserName)."}
}
#EndRegion

#Region Create or Join Farm
# ===================================================================================
# Func: CreateOrJoinFarm
# Desc: Check if the farm is created
# ===================================================================================
Function CreateOrJoinFarm([xml]$xmlinput, $secPhrase, $farmCredential)
{
    WriteLine
    Get-MajorVersionNumber $xmlinput
    $dbPrefix = Get-DBPrefix $xmlinput
    $configDB = $dbPrefix+$xmlinput.Configuration.Farm.Database.ConfigDB

    # Look for an existing farm and join the farm if not already joined, or create a new farm
    Try
    {
        log " - Checking farm membership for $env:COMPUTERNAME in `"$configDB`"..." 
        $spFarm = Get-SPFarm | Where-Object {$_.Name -eq $configDB} -ErrorAction SilentlyContinue
        log "."
    }
    Catch {log "Not joined yet."}
    If ($spFarm -eq $null)
    {
        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
        $centralAdminContentDB = $dbPrefix+$xmlinput.Configuration.Farm.CentralAdmin.Database
        # If the SharePoint version is newer than 2010, set the new -SkipRegisterAsDistributedCacheHost parameter when creating/joining the farm if we aren't requesting it for the current server
        if (($env:spVer -ge "15") -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.DistributedCache -eq $true))
        {
            $distCacheSwitch = @{SkipRegisterAsDistributedCacheHost = $true}
            log " - This host has been requested to be excluded from the Distributed Cache cluster."
        }
        else {$distCacheSwitch = @{}}
        log " - Attempting to join farm on `"$configDB`"..."
        $connectFarm = Connect-SPConfigurationDatabase -DatabaseName "$configDB" -Passphrase $secPhrase -DatabaseServer "$dbServer" @distCacheSwitch -ErrorAction SilentlyContinue
        If (-not $?)
        {
            log " - No existing farm found.`n - Creating config database `"$configDB`"..."
            # Waiting a few seconds seems to help with the Connect-SPConfigurationDatabase barging in on the New-SPConfigurationDatabase command; not sure why...
            Start-Sleep 5
            New-SPConfigurationDatabase -DatabaseName "$configDB" -DatabaseServer "$dbServer" -AdministrationContentDatabaseName "$centralAdminContentDB" -Passphrase $secPhrase -FarmCredentials $farmCredential @distCacheSwitch
            If (-not $?) {Throw " - Error creating new farm configuration database"}
            Else {$farmMessage = " - Done creating configuration database for farm."}
        }
        Else
        {
            $farmMessage = " - Done joining farm."
            [bool]$script:FarmExists = $true

        }
    }
    Else
    {
        [bool]$script:FarmExists = $true
        $farmMessage = " - $env:COMPUTERNAME is already joined to farm on `"$configDB`"."
    }

    log $farmMessage
    WriteLine
}
#EndRegion

#Region PSConfig
Function Run-PSConfig
{
    Start-Process -FilePath $PSConfig -ArgumentList "-cmd upgrade -inplace b2b -force -cmd applicationcontent -install -cmd installfeatures" -NoNewWindow -Wait
}
Function Check-PSConfig
{
    $PSConfigLogLocation = $((Get-SPDiagnosticConfig).LogLocation) -replace "%CommonProgramFiles%","$env:CommonProgramFiles"
    $PSConfigLog = Get-ChildItem -Path $PSConfigLogLocation | ? {$_.Name -like "PSCDiagnostics*"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
    If ($PSConfigLog -eq $null)
    {
        Throw " - Could not find PSConfig log file!"
    }
    Else
    {
        # Get error(s) from log
        $PSConfigLastError = $PSConfigLog | select-string -SimpleMatch -CaseSensitive -Pattern "ERR" | Select-Object -Last 1
        return $PSConfigLastError
    }
}
#EndRegion

#Region Configure Farm
# ===================================================================================
# Func: CreateCentralAdmin
# Desc: Setup Central Admin Web Site, Check the topology of an existing farm, and configure the farm as required.
# ===================================================================================
Function CreateCentralAdmin([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    # Get all Central Admin service instances in the farm
    $centralAdminServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Administration.SPWebServiceInstance" -and $_.Name -eq "WSS_Administration"}
    # Get those Central Admin services that are Online
    $centralAdminServicesOnline = $centralAdminServices | ? {$_.Status -eq "Online"}
    # Get the local Central Admin service
    $localCentralAdminService = $centralAdminServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
    If ((ShouldIProvision $xmlinput.Configuration.Farm.CentralAdmin -eq $true) -and ($localCentralAdminService.Status -ne "Online"))
    {
        Try
        {
            # Check if there is already a Central Admin provisioned in the farm; if not, create one
            If (!(Get-SPWebApplication -IncludeCentralAdministration | ? {$_.IsAdministrationWebApplication}) -or $centralAdminServicesOnline.Count -lt 1)
            {
                # Create Central Admin for farm
                log " - Creating Central Admin site..."
                $centralAdminPort = $xmlinput.Configuration.Farm.CentralAdmin.Port
                $newCentralAdmin = New-SPCentralAdministration -Port $centralAdminPort -WindowsAuthProvider "NTLM" -ErrorVariable err
                If (-not $?) {Throw " - Error creating central administration application"}
                log " - Waiting for Central Admin site..." 
                While ($localCentralAdminService.Status -ne "Online")
                {
                    log "." 
                    Start-Sleep 1
                    $centralAdminServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Administration.SPWebServiceInstance" -and $_.Name -eq "WSS_Administration"}
                    $localCentralAdminService = $centralAdminServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                }
                log $($localCentralAdminService.Status)
                
                If ($xmlinput.Configuration.Farm.CentralAdmin.UseSSL -eq $true)
                {
                    log " - Enabling SSL for Central Admin..."
                    $centralAdmin = Get-SPWebApplication -IncludeCentralAdministration | ? {$_.IsAdministrationWebApplication}
                    $SSLHostHeader = $env:COMPUTERNAME
                    $SSLPort = $centralAdminPort
                    $SSLSiteName = $centralAdmin.DisplayName
                    New-SPAlternateURL -Url "https://$($env:COMPUTERNAME):$centralAdminPort" -Zone Default -WebApplication $centralAdmin | Out-Null
                    if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
                    {
                        log " - Assigning certificate(s) in a separate PowerShell window..."
                        Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList "-Command `". $env:dp0\AutoSPInstallerFunctions.ps1`; AssignCert $SSLHostHeader $SSLPort $SSLSiteName; Start-Sleep 2`"" -Wait
                    }
                    else {AssignCert $SSLHostHeader $SSLPort $SSLSiteName}
                }
            }
            # Otherwise create a Central Admin site locally, with an AAM to the existing Central Admin
            Else
            {
                log " - Creating local Central Admin site..."
                $newCentralAdmin = New-SPCentralAdministration
            }
        }
        Catch
        {
            If ($err -like "*update conflict*")
            {
                log "A concurrency error occured, trying again."
                CreateCentralAdmin $xmlinput
            }
            Else
            {
                Throw $_
            }
        }
    }
}

# ===================================================================================
# Func: CheckFarmTopology
# Desc: Check if there is already more than one server in the farm (not including the database server)
# ===================================================================================
Function CheckFarmTopology([xml]$xmlinput)
{
    $dbPrefix = Get-DBPrefix $xmlinput
    $configDB = $dbPrefix+$xmlinput.Configuration.Farm.Database.ConfigDB
    $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
    $spFarm = Get-SPFarm | Where-Object {$_.Name -eq $configDB}
    ForEach ($srv in $spFarm.Servers) {If (($srv -like "*$dbServer*") -and ($dbServer -ne $env:COMPUTERNAME)) {[bool]$dbLocal = $false}}
    If (($($spFarm.Servers.Count) -gt 1) -and ($dbLocal -eq $false)) {[bool]$script:FirstServer = $false}
    Else {[bool]$script:FirstServer = $true}
}

# ===================================================================================
# Func: WaitForHelpInstallToFinish
# Desc: Waits for the Help Collection timer job to complete before proceeding, in order to avoid concurrency errors
# From: Adapted from a function submitted by CodePlex user jwthompson98
# ===================================================================================
Function WaitForHelpInstallToFinish
{
    log "  - Waiting for Help Collection Installation timer job..." 
    # Wait for the timer job to start
    Do
    {
        log "." 
        Start-Sleep -Seconds 1
    }
    Until
    (
        (Get-SPFarm).TimerService.RunningJobs | Where-Object {$_.JobDefinition.TypeName -eq "Microsoft.SharePoint.Help.HelpCollectionInstallerJob"}
    )
    log "Started."
    log "  - Waiting for Help Collection Installation timer job to complete: " 
    # Monitor the timer job and display progress
    $helpJob = (Get-SPFarm).TimerService.RunningJobs | Where-Object {$_.JobDefinition.TypeName -eq "Microsoft.SharePoint.Help.HelpCollectionInstallerJob"} | Sort StartTime | Select -Last 1
    While ($helpJob -ne $null)
    {
        log "$($helpJob.PercentageDone)%" 
        Start-Sleep -Milliseconds 250
        for ($i = 0; $i -lt 3; $i++)
        {
            log "." 
            Start-Sleep -Milliseconds 250
        }
        $backspaceCount = (($helpJob.PercentageDone).ToString()).Length + 3
        for ($count = 0; $count -le $backspaceCount; $count++) {log "`b `b" }
        $helpJob = (Get-SPFarm).TimerService.RunningJobs | Where-Object {$_.JobDefinition.TypeName -eq "Microsoft.SharePoint.Help.HelpCollectionInstallerJob"} | Sort StartTime | Select -Last 1
    }
    log "OK."
}

# ===================================================================================
# Func: ConfigureFarm
# Desc: Setup Central Admin Web Site, Check the topology of an existing farm, and configure the farm as required.
# ===================================================================================
Function ConfigureFarm([xml]$xmlinput)
{
    WriteLine
    Get-MajorVersionNumber $xmlinput
    log " - Configuring the SharePoint farm/server..."
    # Force a full configuration if this is the first web/app server in the farm
    If ((!($farmExists)) -or ($firstServer -eq $true) -or (CheckIfUpgradeNeeded -eq $true)) {[bool]$doFullConfig = $true}
    Try
    {
        If ($doFullConfig)
        {
            # Install Help Files
            log " - Installing Help Collection..."
            Install-SPHelpCollection -All
            ##WaitForHelpInstallToFinish
        }
        # Secure resources
        log " - Securing Resources..."
        Initialize-SPResourceSecurity
        # Install Services
        log " - Installing Services..."
        Install-SPService
        If ($doFullConfig)
        {
            # Install (all) features
            log " - Installing Features..."
            $features = Install-SPFeature -AllExistingFeatures -Force
        }
        CreateCentralAdmin $xmlinput
        # Update Central Admin branding text for SharePoint 2013 based on the XML input Environment attribute
        if ($env:spVer -eq "15" -and !([string]::IsNullOrEmpty($xmlinput.Configuration.Environment)))
        {
            # From http://www.wictorwilen.se/sharepoint-2013-central-administration-productivity-tip?utm_source=feedburner&utm_medium=feed&utm_campaign=Feed%3A+WictorWilen+%28Wictor+Wil%C3%A9n+-+SharePoint+MCA%2C+MCM+and+MVP%29
            log " - Updating Central Admin branding text to `"$($xmlinput.Configuration.Environment)`"..."
            $suiteBarBrandingElement = "SharePoint - " + $xmlinput.Configuration.Environment
            $ca = Get-SPWebApplication -IncludeCentralAdministration | ? {$_.IsAdministrationWebApplication}
            $ca.SuiteBarBrandingElementHtml = "<div class='ms-core-brandingText'>$suiteBarBrandingElement</div>"
            $ca.Update()
        }
        # Install application content if this is a new farm
        If ($doFullConfig)
        {
            log " - Installing Application Content..."
            Install-SPApplicationContent
        }
    }
    Catch
    {
        If ($err -like "*update conflict*")
        {
            log "A concurrency error occured, trying again."
            CreateCentralAdmin $xmlinput
        }
        Else
        {
            Throw $_
        }
    }
    # Check again if we need to run PSConfig, in case a CU was installed on a subsequent pass of AutoSPInstaller
    if (CheckIfUpgradeNeeded -eq $true)
    {
        $retryNum = 1
        Run-PSConfig
        $PSConfigLastError = Check-PSConfig
        while (!([string]::IsNullOrEmpty($PSConfigLastError)) -and $retryNum -le 4)
        {
            log $PSConfigLastError.Line
            log " - An error occurred running PSConfig, trying again ($retryNum)..."
            Start-Sleep -Seconds 5
            $retryNum += 1
            Run-PSConfig
            $PSConfigLastError = Check-PSConfig
        }
        If ($retryNum -ge 5)
        {
            log " - After $retryNum retries to run PSConfig, trying GUI-based..."
            Start-Process -FilePath $PSConfigUI -NoNewWindow -Wait
        }
        Clear-Variable -Name PSConfigLastError -ErrorAction SilentlyContinue
        Clear-Variable -Name PSConfigLog -ErrorAction SilentlyContinue
        Clear-Variable -Name retryNum -ErrorAction SilentlyContinue
    }
    $spRegVersion = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\$env:spVer.0\").GetValue("Version")
    If (!($spRegVersion))
    {
        log " - Creating Version registry value (workaround for bug in PS-based install)"
        log  " - Getting version number... "
        $spBuild = "$($(Get-SPFarm).BuildVersion.Major).0.0.$($(Get-SPFarm).BuildVersion.Build)"
        log "$spBuild"
        New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\$env:spVer.0\" -Name Version -Value $spBuild -ErrorAction SilentlyContinue | Out-Null
    }
    # Set an environment variable for the 14/15 hive (SharePoint root)
    [Environment]::SetEnvironmentVariable($env:spVer, "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer", "Machine")

    # Let's make sure the SharePoint Timer Service (SPTimerV4) is running
    # Per workaround in http://www.paulgrimley.com/2010/11/side-effects-of-attaching-additional.html
    If ((Get-Service SPTimerV4).Status -eq "Stopped")
    {
        log " - Starting $((Get-Service SPTimerV4).DisplayName) Service..."
        Start-Service SPTimerV4
        If (!$?) {Throw " - Could not start Timer service!"}
    }
    if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
    {
        log " - Stopping Default Web Site in a separate PowerShell window..."
        Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList "-Command `". $env:dp0\AutoSPInstallerFunctions.ps1`; Stop-DefaultWebsite; Start-Sleep 2`"" -Wait
    }
    else {Stop-DefaultWebsite}
    log " - Done initial farm/server config."
    WriteLine
}

#EndRegion

#Region Configure Language Packs
Function ConfigureLanguagePacks([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\$env:spVer.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}
    $languagePackInstalled = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\$env:spVer.0\WSS\").GetValue("LanguagePackInstalled")
    # If there were language packs installed we need to run psconfig to configure them
    If (($languagePackInstalled -eq "1") -and ($installedOfficeServerLanguages.Count -gt 1))
    {
        WriteLine
        log " - Configuring language packs..."
        # Let's sleep for a while to let the farm config catch up...
        Start-Sleep 20
        $retryNum += 1
        # Run PSConfig.exe per http://sharepoint.stackexchange.com/questions/9927/sp2010-psconfig-fails-trying-to-configure-farm-after-installing-language-packs
        # Note this was changed from v2v to b2b as suggested by CodePlex user jwthompson98
        Run-PSConfig
        $PSConfigLastError = Check-PSConfig
        while (!([string]::IsNullOrEmpty($PSConfigLastError)) -and $retryNum -le 4)
        {
            log $PSConfigLastError.Line
            log " - An error occurred running PSConfig, trying again ($retryNum)..."
            Start-Sleep -Seconds 5
            $retryNum += 1
            Run-PSConfig
            $PSConfigLastError = Check-PSConfig
        }
        If ($retryNum -ge 5)
        {
            log " - After $retryNum retries to run PSConfig, trying GUI-based..."
            Start-Process -FilePath $PSConfigUI -NoNewWindow -Wait
        }
        Clear-Variable -Name PSConfigLastError -ErrorAction SilentlyContinue
        Clear-Variable -Name PSConfigLog -ErrorAction SilentlyContinue
        Clear-Variable -Name retryNum -ErrorAction SilentlyContinue
        WriteLine
    }
}
#EndRegion

#Region Add Managed Accounts
# ===================================================================================
# FUNC: AddManagedAccounts
# DESC: Adds existing accounts to SharePoint managed accounts and creates local profiles for each
# TODO: Make this more robust, prompt for blank values etc.
# ===================================================================================
Function AddManagedAccounts([xml]$xmlinput)
{
    WriteLine
    log " - Adding Managed Accounts..."
    If ($xmlinput.Configuration.Farm.ManagedAccounts)
    {
        # Get the members of the local Administrators group
        $builtinAdminGroup = Get-AdministratorsGroup
        $adminGroup = ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group")
        # This syntax comes from Ying Li (http://myitforum.com/cs2/blogs/yli628/archive/2007/08/30/powershell-script-to-add-remove-a-domain-user-to-the-local-administrators-group-on-a-remote-machine.aspx)
        $localAdmins = $adminGroup.psbase.invoke("Members") | ForEach-Object {$_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)}
        # Ensure Secondary Logon service is enabled and started
        If (!((Get-Service -Name seclogon).Status -eq "Running"))
        {
            log " - Enabling Secondary Logon service..."
            Set-Service -Name seclogon -StartupType Manual
            log " - Starting Secondary Logon service..."
            Start-Service -Name seclogon
        }

        ForEach ($account in $xmlinput.Configuration.Farm.ManagedAccounts.ManagedAccount)
        {
            $username = $account.username
            $password = $account.Password
            $password = ConvertTo-SecureString "$password" -AsPlaintext -Force
            $alreadyAdmin = $false
            # The following was suggested by Matthias Einig (http://www.codeplex.com/site/users/view/matein78)
            # And inspired by http://todd-carter.com/post/2010/05/03/Give-your-Application-Pool-Accounts-A-Profile.aspx & http://blog.brainlitter.com/archive/2010/06/08/how-to-revolve-event-id-1511-windows-cannot-find-the-local-profile-on-windows-server-2008.aspx
            Try
            {
                $credAccount = New-Object System.Management.Automation.PsCredential $username,$password
                $managedAccountDomain,$managedAccountUser = $username -Split "\\"
                log "  - Account `"$managedAccountDomain\$managedAccountUser`:"
                log "   - Creating local profile for $username..."
                # Add managed account to local admins (very) temporarily so it can log in and create its profile
                If (!($localAdmins -contains $managedAccountUser))
                {
                    $builtinAdminGroup = Get-AdministratorsGroup
                    log "   - Adding to local Admins (*temporarily*)..." 
                    ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Add("WinNT://$managedAccountDomain/$managedAccountUser")
                    log "OK."
                }
                Else
                {
                    $alreadyAdmin = $true
                }
                # Spawn a command window using the managed account's credentials, create the profile, and exit immediately
                Start-Process -WorkingDirectory "$env:SYSTEMROOT\System32\" -FilePath "cmd.exe" -ArgumentList "/C" -LoadUserProfile -NoNewWindow -Credential $credAccount
                # Remove managed account from local admins unless it was already there
                $builtinAdminGroup = Get-AdministratorsGroup
                If (-not $alreadyAdmin)
                {
                    log "   - Removing from local Admins..." 
                    ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Remove("WinNT://$managedAccountDomain/$managedAccountUser")
                    if (!$?)
                    {
                        log "."
                        log "   - Could not remove `"$managedAccountDomain\$managedAccountUser`" from local Admins."
                        log "   - Please remove it manually."
                    }
                    else {log "OK."}
                }
                log "  - Done."
            }
            Catch
            {
                $_
                log "."
                log "Could not create local user profile for $username"
                break
            }
            $managedAccount = Get-SPManagedAccount | Where-Object {$_.UserName -eq $username}
            If ($managedAccount -eq $null)
            {
                log "   - Registering managed account $username..."
                If ($username -eq $null -or $password -eq $null)
                {
                    # MK: added throw
                    # log "   - Prompting for Account: "
                    # $credAccount = $host.ui.PromptForCredential("Managed Account", "Enter Account Credentials:", "", "NetBiosUserName" )
                    throw "ERROR: One of managed accouns is missing!"

                }
                Else
                {
                    $credAccount = New-Object System.Management.Automation.PsCredential $username,$password
                }
                New-SPManagedAccount -Credential $credAccount | Out-Null
                If (-not $?) { Throw "   - Failed to create managed account" }
            }
            Else
            {
                log "   - Managed account $username already exists."
            }
        }
    }
    log " - Done Adding Managed Accounts."
    WriteLine
}
#EndRegion

#Region Return SP Managed Account
Function Get-SPManagedAccountXML([xml]$xmlinput, $commonName)
{
    $managedAccountXML = $xmlinput.Configuration.Farm.ManagedAccounts.ManagedAccount | Where-Object { $_.CommonName -eq $commonName }
    Return $managedAccountXML
}
#EndRegion

#Region Get or Create Hosted Services Application Pool
# ====================================================================================
# Func: Get-HostedServicesAppPool
# Desc: Creates and/or returns the Hosted Services Application Pool
# ====================================================================================
Function Get-HostedServicesAppPool ([xml]$xmlinput)
{
    $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
    # Managed Account
    $managedAccountGen = Get-SPManagedAccount | Where-Object {$_.UserName -eq $($spservice.username)}
    If ($managedAccountGen -eq $null) { Throw " - Managed Account $($spservice.username) not found" }
    # App Pool
    $applicationPool = Get-SPServiceApplicationPool "SharePoint Hosted Services" -ea SilentlyContinue
    If ($applicationPool -eq $null)
    {
        log " - Creating SharePoint Hosted Services Application Pool..."
        $applicationPool = New-SPServiceApplicationPool -Name "SharePoint Hosted Services" -account $managedAccountGen
        If (-not $?) { Throw "Failed to create the application pool" }
    }
    Return $applicationPool
}
#EndRegion

#Region Create Generic Service Application
# ===================================================================================
# Func: CreateGenericServiceApplication
# Desc: General function that creates a broad range of service applications
# ===================================================================================
Function CreateGenericServiceApplication()
{
    param
    (
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [String]$serviceConfig,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [String]$serviceInstanceType,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [String]$serviceName,
        [Parameter(Mandatory=$false)]
        [String]$serviceProxyName,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [String]$serviceGetCmdlet,
        [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
        [String]$serviceProxyGetCmdlet,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [String]$serviceNewCmdlet,
        [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
        [String]$serviceProxyNewCmdlet,
        [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
        [String]$serviceProxyNewParams
    )

    Try
    {
        $applicationPool = Get-HostedServicesAppPool $xmlinput
        log " - Provisioning $serviceName..."
        # get the service instance
        $serviceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq $serviceInstanceType}
        $serviceInstance = $serviceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
        If (!$serviceInstance) { Throw " - Failed to get service instance - check product version (Standard vs. Enterprise)" }
        # Start Service instance
        log " - Checking $($serviceInstance.TypeName) instance..."
        If (($serviceInstance.Status -eq "Disabled") -or ($serviceInstance.Status -ne "Online"))
        {
            log " - Starting $($serviceInstance.TypeName) instance..."
            $serviceInstance.Provision()
            If (-not $?) { Throw " - Failed to start $($serviceInstance.TypeName) instance" }
            # Wait
            log " - Waiting for $($serviceInstance.TypeName) instance..." 
            While ($serviceInstance.Status -ne "Online")
            {
                log "." 
                Start-Sleep 1
                $serviceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq $serviceInstanceType}
                $serviceInstance = $serviceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            }
                log $($serviceInstance.Status)
        }
        Else
        {
            log " - $($serviceInstance.TypeName) instance already started."
        }
        # Check if our new cmdlets are available yet,  if not, re-load the SharePoint PS Snapin
        If (!(Get-Command $serviceGetCmdlet -ErrorAction SilentlyContinue))
        {
            log " - Re-importing SP PowerShell Snapin to enable new cmdlets..."
            Remove-PSSnapin Microsoft.SharePoint.PowerShell
            Load-SharePoint-PowerShell
        }
        $getServiceApplication = Invoke-Expression "$serviceGetCmdlet | ? {`$_.Name -eq `"$serviceName`"}"
        If ($getServiceApplication -eq $null)
        {
            log " - Creating $serviceName..."
            # A bit kludgey to accomodate the new PerformancePoint cmdlet in Service Pack 1, and some new SP2010 service apps (and still be able to use the CreateGenericServiceApplication function)
            If ((CheckFor2010SP1) -and ($serviceInstanceType -eq "Microsoft.PerformancePoint.Scorecards.BIMonitoringServiceInstance"))
            {
                $newServiceApplication = Invoke-Expression "$serviceNewCmdlet -Name `"$serviceName`" -ApplicationPool `$applicationPool -DatabaseServer `$dbServer -DatabaseName `$serviceDB"
            }
            Else # Just do the regular non-database-bound service app creation
            {
                $newServiceApplication = Invoke-Expression "$serviceNewCmdlet -Name `"$serviceName`" -ApplicationPool `$applicationPool"
            }
            $getServiceApplication = Invoke-Expression "$serviceGetCmdlet | ? {`$_.Name -eq `"$serviceName`"}"
            if ($getServiceApplication)
            {
                log " - Provisioning $serviceName Proxy..."
                # Because apparently the teams developing the cmdlets for the various service apps didn't communicate with each other, we have to account for the different ways each proxy is provisioned!
                Switch ($serviceInstanceType)
                {
                    "Microsoft.Office.Server.PowerPoint.SharePoint.Administration.PowerPointWebServiceInstance" {& $serviceProxyNewCmdlet -Name "$serviceProxyName" -ServiceApplication $newServiceApplication -AddToDefaultGroup | Out-Null}
                    "Microsoft.Office.Visio.Server.Administration.VisioGraphicsServiceInstance" {& $serviceProxyNewCmdlet -Name "$serviceProxyName" -ServiceApplication $newServiceApplication.Name | Out-Null}
                    "Microsoft.PerformancePoint.Scorecards.BIMonitoringServiceInstance" {& $serviceProxyNewCmdlet -Name "$serviceProxyName" -ServiceApplication $newServiceApplication -Default | Out-Null}
                    "Microsoft.Office.Excel.Server.MossHost.ExcelServerWebServiceInstance" {} # Do nothing because there is no cmdlet to create this services proxy
                    "Microsoft.Office.Access.Server.MossHost.AccessServerWebServiceInstance" {} # Do nothing because there is no cmdlet to create this services proxy
                    "Microsoft.Office.Word.Server.Service.WordServiceInstance" {} # Do nothing because there is no cmdlet to create this services proxy
    				"Microsoft.SharePoint.SPSubscriptionSettingsServiceInstance" {& $serviceProxyNewCmdlet -ServiceApplication $newServiceApplication | Out-Null}
                    "Microsoft.Office.Server.WorkManagement.WorkManagementServiceInstance" {& $serviceProxyNewCmdlet -Name "$serviceProxyName" -ServiceApplication $newServiceApplication -DefaultProxyGroup | Out-Null}
                    "Microsoft.Office.TranslationServices.TranslationServiceInstance" {} # Do nothing because the service app cmdlet automatically creates a proxy with the default name
                    "Microsoft.Office.Access.Services.MossHost.AccessServicesWebServiceInstance" {& $serviceProxyNewCmdlet -application $newServiceApplication | Out-Null}
                    "Microsoft.Office.Server.PowerPoint.Administration.PowerPointConversionServiceInstance" {& $serviceProxyNewCmdlet -Name "$serviceProxyName" -ServiceApplication $newServiceApplication -AddToDefaultGroup | Out-Null}
                    "Microsoft.Office.Project.Server.Administration.PsiServiceInstance" {} # Do nothing because the service app cmdlet automatically creates a proxy with the default name
                    Default {& $serviceProxyNewCmdlet -Name "$serviceProxyName" -ServiceApplication $newServiceApplication | Out-Null}
                }
                log " - Done provisioning $serviceName. "
            }
            else {log "An error occurred provisioning $serviceName! Check the log for any details, then try again."}
        }
        Else
        {
            log " - $serviceName already created."
        }
    }
    Catch
    {
        throw "ERROR: $($_.Exception.Message)"
    }
}
#EndRegion

#Region Sandboxed Code Service
# ===================================================================================
# Func: ConfigureSandboxedCodeService
# Desc: Configures the SharePoint Foundation Sandboxed (User) Code Service
# ===================================================================================
Function ConfigureSandboxedCodeService
{
    If (ShouldIProvision $xmlinput.Configuration.Farm.Services.SandboxedCodeService -eq $true)
    {
        WriteLine
        log " - Starting Sandboxed Code Service"
        $sandboxedCodeServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Administration.SPUserCodeServiceInstance"}
        $sandboxedCodeService = $sandboxedCodeServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
        If ($sandboxedCodeService.Status -ne "Online")
        {
            Try
            {
                log " - Starting Microsoft SharePoint Foundation Sandboxed Code Service..."
                UpdateProcessIdentity $sandboxedCodeService
                $sandboxedCodeService.Update()
                $sandboxedCodeService.Provision()
                If (-not $?) {Throw " - Failed to start Sandboxed Code Service"}
            }
            Catch
            {
                Throw " - An error occurred starting the Microsoft SharePoint Foundation Sandboxed Code Service"
            }
            #Wait
            log " - Waiting for Sandboxed Code service..." 
            While ($sandboxedCodeService.Status -ne "Online")
            {
                log "." 
                Start-Sleep 1
                $sandboxedCodeServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Administration.SPUserCodeServiceInstance"}
                $sandboxedCodeService = $sandboxedCodeServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            }
            log $($sandboxedCodeService.Status)
        }
        Else
        {
            log " - Sandboxed Code Service already started."
        }
        WriteLine
    }
}
#EndRegion

#Region Create Metadata Service Application
# ===================================================================================
# Func: CreateMetadataServiceApp
# Desc: Managed Metadata Service Application
# ===================================================================================
Function CreateMetadataServiceApp([xml]$xmlinput)
{
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.ManagedMetadataServiceApp -eq $true) -and (Get-Command -Name New-SPMetadataServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        Try
        {
            Get-MajorVersionNumber $xmlinput
            $dbPrefix = Get-DBPrefix $xmlinput
            $metaDataDB = $dbPrefix+$xmlinput.Configuration.ServiceApps.ManagedMetadataServiceApp.Database.Name
            $dbServer = $xmlinput.Configuration.ServiceApps.ManagedMetadataServiceApp.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($dbServer))
            {
                $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $farmAcct = $xmlinput.Configuration.Farm.Account.Username
            $metadataServiceName = $xmlinput.Configuration.ServiceApps.ManagedMetadataServiceApp.Name
            $metadataServiceProxyName = $xmlinput.Configuration.ServiceApps.ManagedMetadataServiceApp.ProxyName
            If($metadataServiceName -eq $null) {$metadataServiceName = "Metadata Service Application"}
            If($metadataServiceProxyName -eq $null) {$metadataServiceProxyName = $metadataServiceName}
            log " - Provisioning Managed Metadata Service Application"
            $applicationPool = Get-HostedServicesAppPool $xmlinput
            log " - Starting Managed Metadata Service:"
            # Get the service instance
            $metadataServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Taxonomy.MetadataWebServiceInstance"}
            $metadataServiceInstance = $metadataServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find Metadata service instance" }
            # Start Service instances
            If($metadataServiceInstance.Status -eq "Disabled")
            {
                log " - Starting Metadata Service Instance..."
                $metadataServiceInstance.Provision()
                If (-not $?) { Throw " - Failed to start Metadata service instance" }
                # Wait
                log " - Waiting for Metadata service..." 
                While ($metadataServiceInstance.Status -ne "Online")
                {
                    log "." 
                    Start-Sleep 1
                    $metadataServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Taxonomy.MetadataWebServiceInstance"}
                    $metadataServiceInstance = $metadataServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                }
                log ($metadataServiceInstance.Status)
            }
            Else {log " - Managed Metadata Service already started."}

            $metaDataServiceApp = Get-SPServiceApplication | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Taxonomy.MetadataWebServiceApplication"}
            # Create a Metadata Service Application if we don't already have one
            If ($metaDataServiceApp -eq $null)
            {
                # Create Service App
                log " - Creating Metadata Service Application..."
                $metaDataServiceApp = New-SPMetadataServiceApplication -Name $metadataServiceName -ApplicationPool $applicationPool -DatabaseServer $dbServer -DatabaseName $metaDataDB
                If (-not $?) { Throw " - Failed to create Metadata Service Application" }
            }
            Else
            {
                log " - Managed Metadata Service Application already provisioned."
            }
            $metaDataServiceAppProxy = Get-SPServiceApplicationProxy | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Taxonomy.MetadataWebServiceApplicationProxy"}
            if ($metaDataServiceAppProxy -eq $null)
            {
                # create proxy
                log " - Creating Metadata Service Application Proxy..."
                $metaDataServiceAppProxy = New-SPMetadataServiceApplicationProxy -Name $metadataServiceProxyName -ServiceApplication $metaDataServiceApp -DefaultProxyGroup -ContentTypePushdownEnabled -DefaultKeywordTaxonomy -DefaultSiteCollectionTaxonomy
                If (-not $?) { Throw " - Failed to create Metadata Service Application Proxy" }
            }
            else
            {
                log " - Managed Metadata Service Application Proxy already provisioned."
            }
            if ($metaDataServiceApp -or $metaDataServiceAppProxy)
            {
                # Added to enable Metadata Service Navigation for SP2013, per http://www.toddklindt.com/blog/Lists/Posts/Post.aspx?ID=354
                If ($env:spVer -eq "15")
                {
                    If ($metaDataServiceAppProxy.Properties.IsDefaultSiteCollectionTaxonomy -ne $true)
                    {
                        log " - Configuring Metadata Service Application Proxy..."
                        $metaDataServiceAppProxy.Properties.IsDefaultSiteCollectionTaxonomy = $true
                        $metaDataServiceAppProxy.Update()
                    }
                }
                log " - Granting rights to Metadata Service Application:"
                # Get ID of "Managed Metadata Service"
                $metadataServiceAppToSecure = Get-SPServiceApplication | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Taxonomy.MetadataWebServiceApplication"}
                $metadataServiceAppIDToSecure = $metadataServiceAppToSecure.Id
                # Create a variable that contains the list of administrators for the service application
                $metadataServiceAppSecurity = Get-SPServiceApplicationSecurity $metadataServiceAppIDToSecure
                ForEach ($account in ($xmlinput.Configuration.Farm.ManagedAccounts.ManagedAccount))
                {
                    # Create a variable that contains the claims principal for the service accounts
                    log "  - $($account.username)..."
                    $accountPrincipal = New-SPClaimsPrincipal -Identity $account.username -IdentityType WindowsSamAccountName
                    # Give permissions to the claims principal you just created
                    Grant-SPObjectSecurity $metadataServiceAppSecurity -Principal $accountPrincipal -Rights "Full Access to Term Store"
                }
                # Apply the changes to the Metadata Service application
                Set-SPServiceApplicationSecurity $metadataServiceAppIDToSecure -objectSecurity $metadataServiceAppSecurity
                log " - Done granting rights."
                log " - Done creating Managed Metadata Service Application."
            }
        }
        Catch
        {
            Throw " - Error provisioning the Managed Metadata Service Application. $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Assign Certificate
# ===================================================================================
# Func: AssignCert
# Desc: Create and assign SSL Certificate
# ===================================================================================
Function AssignCert($SSLHostHeader, $SSLPort, $SSLSiteName)
{
    ImportWebAdministration
    Get-MajorVersionNumber $xmlinput
    log " - Assigning certificate to site `"https://$SSLHostHeader`:$SSLPort`""
    # If our SSL host header is a FQDN (contains a dot), look for an existing wildcard cert
    If ($SSLHostHeader -like "*.*")
    {
        # Remove the host portion of the URL and the leading dot
        $splitSSLHostHeader = $SSLHostHeader  -split "\."
        $topDomain = $SSLHostHeader.Substring($splitSSLHostHeader[0].Length + 1)
        # Create a new wildcard cert so we can potentially use it on other sites too
        if ($SSLHostHeader -like "*.$env:USERDNSDOMAIN") {$certCommonName = "*.$env:USERDNSDOMAIN"}
        elseif ($SSLHostHeader -like "*.$topDomain") {$certCommonName = "*.$topDomain"}
        log " - Looking for existing `"$certCommonName`" wildcard certificate..."
        $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -like "CN=$certCommonName*"}
    }
    Else
    {
        # Just create a cert that matches the SSL host header
        $certCommonName = $SSLHostHeader
        log " - Looking for existing `"$certCommonName`" certificate..."
        $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -eq "CN=$certCommonName"}
    }


    If (!$cert)
    {
        log " - None found."
        # MK: the certificates have been created and shold be available
        # MK: start
        # Get the actual location of makecert.exe in case we installed SharePoint in the non-default location
        # $spInstallPath = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Office Server\$env:spVer.0").GetValue("InstallPath")
        # $makeCert = "$spInstallPath\Tools\makecert.exe"
        # If (Test-Path "$makeCert")
        # {
        #     log " - Creating new self-signed certificate $certCommonName..."
        #     Start-Process -NoNewWindow -Wait -FilePath "$makeCert" -ArgumentList "-r -pe -n `"CN=$certCommonName`" -eku 1.3.6.1.5.5.7.3.1 -ss My -sr localMachine -sky exchange -sp `"Microsoft RSA SChannel Cryptographic Provider`" -sy 12"
        #     $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -like "CN=``*$certCommonName"}
        #     if (!$cert) {$cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -eq "CN=$SSLHostHeader"}}
        # }
        # Else
        # {
        #     log " - `"$makeCert`" not found."
        #     log " - Looking for any machine-named certificates we can use..."
        #     # Select the first certificate with the most recent valid date
        #     $cert = Get-ChildItem cert:\LocalMachine\My | ? {$_.Subject -like "*$env:COMPUTERNAME"} | Sort-Object NotBefore -Desc | Select-Object -First 1
        #     If (!$cert)
        #     {
        #         log " - None found, skipping certificate creation."
        #     }
        # }
        # MK: end
    }

    If ($cert)
    {
        $certSubject = $cert.Subject
        log " - Certificate `"$certSubject`" found."
        
        # MK: the following has been done during certificates import
        # MK: strat
        # # Fix up the cert subject name to a file-friendly format
        # $certSubjectName = $certSubject.Split(",")[0] -replace "CN=","" -replace "\*","wildcard"
        # # Export our certificate to a file, then import it to the Trusted Root Certification Authorites store so we don't get nasty browser warnings
        # # This will actually only work if the Subject and the host part of the URL are the same
        # # Borrowed from https://www.orcsweb.com/blog/james/powershell-ing-on-windows-server-how-to-import-certificates-using-powershell/
        # log " - Exporting `"$certSubject`" to `"$certSubjectName.cer`"..."
        # $cert.Export("Cert") | Set-Content -Path "$((Get-Item $env:TEMP).FullName)\$certSubjectName.cer" -Encoding byte
        # $pfx = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        # log " - Importing `"$certSubjectName.cer`" to Local Machine\Root..."
        # $pfx.Import("$((Get-Item $env:TEMP).FullName)\$certSubjectName.cer")
        # $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root","LocalMachine")
        # $store.Open("MaxAllowed")
        # $store.Add($pfx)
        # $store.Close()
        # MK: end

        log " - Assigning certificate `"$certSubject`" to SSL-enabled site..."
        #Set-Location IIS:\SslBindings -ErrorAction Inquire
        if (!(Get-Item IIS:\SslBindings\0.0.0.0!$SSLPort -ErrorAction SilentlyContinue))
        {
            $cert | New-Item IIS:\SslBindings\0.0.0.0!$SSLPort -ErrorAction SilentlyContinue | Out-Null
        }

        # Check if we have specified no host header
        if (!([string]::IsNullOrEmpty($webApp.UseHostHeader)) -and $webApp.UseHostHeader -eq $false)
        {
            Set-ItemProperty IIS:\Sites\$SSLSiteName -Name bindings -Value @{protocol="https";bindingInformation="*:$($SSLPort):"} -ErrorAction SilentlyContinue
        }
        else # Set the binding to the host header
        {
            Set-ItemProperty IIS:\Sites\$SSLSiteName -Name bindings -Value @{protocol="https";bindingInformation="*:$($SSLPort):$($SSLHostHeader)"} -ErrorAction SilentlyContinue
        }

        ## Set-WebBinding -Name $SSLSiteName -BindingInformation ":$($SSLPort):" -PropertyName Port -Value $SSLPort -PropertyName Protocol -Value https
        log " - Certificate has been assigned to site `"https://$SSLHostHeader`:$SSLPort`""
    }
    Else {log " - No certificates were found, and none could be created."}
    $cert = $null
}
#EndRegion

#Region Create Web Applications
# ===================================================================================
# Func: CreateWebApplications
# Desc: Create and  configure the required web applications
# ===================================================================================
Function CreateWebApplications([xml]$xmlinput)
{
    WriteLine
    If ($xmlinput.Configuration.WebApplications)
    {
        log " - Creating web applications..."
        ForEach ($webApp in $xmlinput.Configuration.WebApplications.WebApplication)
        {
            CreateWebApp $webApp
            ConfigureOnlineWebPartCatalog $webApp
            Add-LocalIntranetURL $webApp.URL
            WriteLine
        }
        # Updated so that we don't add URLs to the local hosts file of a server that's not running the Foundation Web Application service
        If ($xmlinput.Configuration.WebApplications.AddURLsToHOSTS -eq $true -and !(($xmlinput.Configuration.Farm.Services.SelectSingleNode("FoundationWebApplication")) -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.FoundationWebApplication -eq $true)))
        {AddToHOSTS}
    }
    WriteLine
}
# ===================================================================================
# Func: CreateWebApp
# Desc: Create the web application
# ===================================================================================
Function CreateWebApp([System.Xml.XmlElement]$webApp)
{
    Get-MajorVersionNumber $xmlinput
    # Look for a managed account that matches the web app type, e.g. "Portal" or "MySiteHost"
    $webAppPoolAccount = Get-SPManagedAccountXML $xmlinput $webApp.Type
    # If no managed account is found matching the web app type, just use the Portal managed account
    if (!$webAppPoolAccount)
    {
        $webAppPoolAccount = Get-SPManagedAccountXML $xmlinput -CommonName "Portal"
        if ([string]::IsNullOrEmpty($webAppPoolAccount.username)) {throw " - `"Portal`" managed account not found! Check your XML."}
    }
    $webAppName = $webApp.name
    $appPool = $webApp.applicationPool
    $dbPrefix = Get-DBPrefix $xmlinput
    $database = $dbPrefix+$webApp.Database.Name
    $dbServer = $webApp.Database.DBServer
    # Check for an existing App Pool
    $existingWebApp = Get-SPWebApplication | Where-Object { ($_.ApplicationPool).Name -eq $appPool }
    $appPoolExists = ($existingWebApp -ne $null)
    # If we haven't specified a DB Server then just use the default used by the Farm
    If ([string]::IsNullOrEmpty($dbServer))
    {
        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
    }
    $url = $webApp.url
    $port = $webApp.port

    $useSSL = $false
    $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\$env:spVer.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}
    # Strip out any protocol value
    If ($url -like "https://*") {$useSSL = $true}
    $hostHeader = $url -replace "http://","" -replace "https://",""
    if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
    {
        log " - Skipping setting the web app directory path name (not currently working on Windows 2012 w/SP2010)..."
        $pathSwitch = @{}
    }
    else
    {
        # Set the directory path for the web app to something a bit more friendly
        ImportWebAdministration
        # Get the default root location for web apps
        $iisWebDir = (Get-ItemProperty "IIS:\Sites\Default Web Site\" -name physicalPath -ErrorAction SilentlyContinue) -replace ("%SystemDrive%","$env:SystemDrive")
        if (!([string]::IsNullOrEmpty($iisWebDir)))
        {
            $pathSwitch = @{Path = "$iisWebDir\wss\VirtualDirectories\$webAppName-$port"}
        }
        else {$pathSwitch = @{}}
    }
    # Only set $hostHeaderSwitch to blank if the UseHostHeader value exists has explicitly been set to false
    if (!([string]::IsNullOrEmpty($webApp.UseHostHeader)) -and $webApp.UseHostHeader -eq $false)
    {
        $hostHeaderSwitch = @{}
    }
    else {$hostHeaderSwitch = @{HostHeader = $hostHeader}}
    if (!([string]::IsNullOrEmpty($webApp.useClaims)) -and $webApp.useClaims -eq $false)
    {
        # Create the web app using Classic mode authentication
        $authProviderSwitch = @{}
    }
    else # Configure new web app to use Claims-based authentication
    {
        If ($($webApp.useBasicAuthentication) -eq $true)
        {
            $authProvider = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication -UseBasicAuthentication
        }
        Else
        {
            $authProvider = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication
        }
        $authProviderSwitch = @{AuthenticationProvider = $authProvider}
        If ((Gwmi Win32_OperatingSystem).Version -like "6.0*") # If we are running Win2008 (non-R2), we may need the claims hotfix
        {
            [bool]$claimsHotfixRequired = $true
            log " - Web Applications using Claims authentication require an update"
            log " - Apply the http://go.microsoft.com/fwlink/?LinkID=184705 update after setup."
        }
    }
    if ($appPoolExists)
    {
        $appPoolAccountSwitch = @{}
    }
    else
    {
        $appPoolAccountSwitch = @{ApplicationPoolAccount = $($webAppPoolAccount.username)}
    }
    $getSPWebApplication = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webAppName}
    If ($getSPWebApplication -eq $null)
    {
        log " - Creating Web App `"$webAppName`""
        New-SPWebApplication -Name $webAppName -ApplicationPool $appPool -DatabaseServer $dbServer -DatabaseName $database -Url $url -Port $port -SecureSocketsLayer:$useSSL @hostHeaderSwitch @appPoolAccountSwitch @authProviderSwitch @pathSwitch | Out-Null
        If (-not $?) { Throw " - Failed to create web application" }
    }
    Else {log " - Web app `"$webAppName`" already provisioned."}
    SetupManagedPaths $webApp
    If ($useSSL)
    {
        $SSLHostHeader = $hostHeader
        $SSLPort = $port
        $SSLSiteName = $webAppName
        if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
        {
            log " - Assigning certificate(s) in a separate PowerShell window..."
            Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList "-Command `". $env:dp0\AutoSPInstallerFunctions.ps1`; AssignCert $SSLHostHeader $SSLPort $SSLSiteName; Start-Sleep 2`"" -Wait
        }
        else {AssignCert $SSLHostHeader $SSLPort $SSLSiteName}
    }

    # If we are provisioning any Office Web Apps, Visio, Excel, Access or PerformancePoint services, we need to grant the generic app pool account access to the newly-created content database
    # Per http://technet.microsoft.com/en-us/library/ff829837.aspx and http://autospinstaller.codeplex.com/workitem/16224 (thanks oceanfly!)
    If ((ShouldIProvision $xmlinput.Configuration.OfficeWebApps.ExcelService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.OfficeWebApps.PowerPointService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.OfficeWebApps.WordViewingService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.VisioService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.AccessService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.AccessServices -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.PerformancePointService -eq $true))
    {
        $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
        log " - Granting $($spservice.username) rights to `"$webAppName`"..." 
        $wa = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webAppName}
        $wa.GrantAccessToProcessIdentity("$($spservice.username)")
        log "OK."
    }
    if ($webApp.GrantCurrentUserFullControl -eq $true)
    {
        $currentUser = "$env:USERDOMAIN\$env:USERNAME"
        $wa = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webAppName}
        if ($wa.UseClaimsAuthentication -eq $true) {$currentUser = 'i:0#.w|' + $currentUser}
        Set-WebAppUserPolicy $wa $currentUser "$env:USERNAME" "Full Control"
    }
    WriteLine
    ConfigureObjectCache $webApp

    if ($webApp.SiteCollections.SelectSingleNode("SiteCollection")) # Only go through these steps if we actually have a site collection to create
    {
        ForEach ($siteCollection in $webApp.SiteCollections.SiteCollection)
        {
            try
            {
            $dbPrefix = Get-DBPrefix $xmlinput
            $getSPSiteCollection = $null
            $siteCollectionName = $siteCollection.Name
            $siteURL = $siteCollection.siteURL
            if (!([string]::IsNullOrEmpty($($siteCollection.CustomDatabase)))) # Check if we have specified a non-default content database for this site collection
            {
                $siteDatabase = $dbPrefix+$siteCollection.CustomDatabase
            }
            else # Just use the first, default content database for the web application
            {
                $siteDatabase = $database
            }
            $template = $siteCollection.template
            # If an OwnerAlias has been specified, make it the primary, and the currently logged-in account the secondary. Otherwise, make the app pool account for the web app the primary owner
            if (!([string]::IsNullOrEmpty($($siteCollection.Owner))))
            {
                $ownerAlias = $siteCollection.Owner
            }
            else
            {
                $ownerAlias = $webAppPoolAccount.username
            }
            $LCID = $siteCollection.LCID
            $siteCollectionLocale = $siteCollection.Locale
            $siteCollectionTime24 = $siteCollection.Time24
            # If a template has been pre-specified, use it when creating the Portal site collection; otherwise, leave it blank so we can select one when the portal first loads
            If (($template -ne $null) -and ($template -ne ""))
            {
                $templateSwitch = @{Template = $template}
            }
            else {$templateSwitch = @{}}
            if ($siteCollection.HostNamedSiteCollection -eq $true)
            {
                $hostHeaderWebAppSwitch = @{HostHeaderWebApplication = $($webApp.url)+":"+$($webApp.port)}
            }
            else {$hostHeaderWebAppSwitch = @{}}
            log " - Checking for Site Collection `"$siteURL`"..."
            $getSPSiteCollection = Get-SPSite -Limit ALL | Where-Object {$_.Url -eq $siteURL}
            If (($getSPSiteCollection -eq $null) -and ($siteURL -ne $null))
            {
                # Verify that the Language we're trying to create the site in is currently installed on the server
                $culture = [System.Globalization.CultureInfo]::GetCultureInfo(([convert]::ToInt32($LCID)))
                $cultureDisplayName = $culture.DisplayName
                If (!($installedOfficeServerLanguages | Where-Object {$_ -eq $culture.Name}))
                {
                    log "You must install the `"$culture ($cultureDisplayName)`" Language Pack before you can create a site using LCID $LCID"
                }
                Else
                {
                    $siteDatabaseExists = Get-SPContentDatabase -Identity $siteDatabase -ErrorAction SilentlyContinue
                    if (!$siteDatabaseExists)
                    {
                        log " - Creating new content database `"$siteDatabase`"..."

                        # MK added -DatabaseServer to ensure site col db is created in correct place
                        New-SPContentDatabase -Name $siteDatabase -DatabaseServer $dbServer -WebApplication (Get-SPWebApplication $wa.url) | Out-Null
                        # New-SPContentDatabase -Name $siteDatabase -WebApplication (Get-SPWebApplication $webApp.url) | Out-Null
                    }
                    log " - Creating Site Collection `"$siteURL`"..."
                    $site = New-SPSite -Url $siteURL -OwnerAlias $ownerAlias -SecondaryOwner $env:USERDOMAIN\$env:USERNAME -ContentDatabase $siteDatabase -Description $siteCollectionName -Name $siteCollectionName -Language $LCID @templateSwitch @hostHeaderWebAppSwitch -ErrorAction Stop

                    # JDM Not all Web Templates greate the default SharePoint Croups that are made by the UI
                    # JDM These lines will insure that the the approproprate SharePoint Groups, Owners, Members, Visitors are created
                    $primaryUser = $site.RootWeb.EnsureUser($ownerAlias)
                    $secondaryUser = $site.RootWeb.EnsureUser("$env:USERDOMAIN\$env:USERNAME")
                    $title = $site.RootWeb.title
                    log " - Ensuring default groups are created..."
                    $site.RootWeb.CreateDefaultAssociatedGroups($primaryUser, $secondaryUser, $title)

                    # Add the Portal Site Connection to the web app, unless of course the current web app *is* the portal
                    # Inspired by http://www.toddklindt.com/blog/Lists/Posts/Post.aspx?ID=264
                    $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
                    $portalSiteColl = $portalWebApp.SiteCollections.SiteCollection | Select-Object -First 1
                    If ($site.URL -ne $portalSiteColl.siteURL)
                    {
                        log " - Setting the Portal Site Connection for `"$siteCollectionName`"..."
                        $site.PortalName = $portalSiteColl.Name
                        $site.PortalUrl = $portalSiteColl.siteUrl
                    }
                    If ($siteCollectionLocale)
                    {
                        log " - Updating the locale for `"$siteCollectionName`" to `"$siteCollectionLocale`"..."
                        $site.RootWeb.Locale = [System.Globalization.CultureInfo]::CreateSpecificCulture($siteCollectionLocale)
                    }
                    If ($siteCollectionTime24)
                    {
                        log " - Updating 24 hour time format for `"$siteCollectionName`" to `"$siteCollectionTime24`"..."
                        $site.RootWeb.RegionalSettings.Time24 = $([System.Convert]::ToBoolean($siteCollectionTime24))
                    }
                    $site.RootWeb.Update()

                    # MK: start
                    $siteCol = get-spsite $siteURL
                    $publicUrl = ([string]$siteURL).ToLower().Replace($env:USERDNSDOMAIN.ToLower(), $clientDomain.ToLower())
    
                    set-spsiteurl -identity $siteCol -url $publicUrl -zone Intranet
                    # MK: end
                }
            }
            Else {log " - Skipping creation of site `"$siteCollectionName`" - already provisioned."}
            if ($siteCollection.HostNamedSiteCollection -eq $true)
            {
                Add-LocalIntranetURL ($siteURL)
                # Updated so that we don't add URLs to the local hosts file of a server that's not running the Foundation Web Application service
                if ($xmlinput.Configuration.WebApplications.AddURLsToHOSTS -eq $true -and !(($xmlinput.Configuration.Farm.Services.SelectSingleNode("FoundationWebApplication")) -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.FoundationWebApplication -eq $true)))
                {
                    # Add the hostname of this host header-based site collection to the local HOSTS so it's immediately resolvable locally
                    # Strip out any protocol and/or port values
                    $hostname,$null = $siteURL -replace "http://","" -replace "https://","" -split ":"
                    AddToHOSTS $hostname
                }
            }
            WriteLine
            }
            catch
            {
                log "WARNING: Exception occurred $($_.Exception.Message). Continue."
            }
        } # foreach site collection
    }
    else
    {
        log " - No site collections specified for $($webapp.url) - skipping."
    }
}

# ===================================================================================
# Func: Set-WebAppUserPolicy
# AMW 1.7.2
# Desc: Set the web application user policy
# Refer to http://technet.microsoft.com/en-us/library/ff758656.aspx
# Updated based on Gary Lapointe example script to include Policy settings 18/10/2010
# ===================================================================================
Function Set-WebAppUserPolicy($wa, $userName, $displayName, $perm)
{
    [Microsoft.SharePoint.Administration.SPPolicyCollection]$policies = $wa.Policies
    [Microsoft.SharePoint.Administration.SPPolicy]$policy = $policies.Add($userName, $displayName)
    [Microsoft.SharePoint.Administration.SPPolicyRole]$policyRole = $wa.PolicyRoles | where {$_.Name -eq $perm}
    If ($policyRole -ne $null)
    {
        log " - Granting $userName $perm to $($wa.Url)..."
        $policy.PolicyRoleBindings.Add($policyRole)
    }
    $wa.Update()
}

# ===================================================================================
# Func: ConfigureObjectCache
# Desc: Applies the portal super accounts to the object cache for a web application
# ===================================================================================
Function ConfigureObjectCache([System.Xml.XmlElement]$webApp)
{
    Try
    {
        $url = $webApp.Url + ":" + $webApp.Port
        $wa = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webApp.Name}
        $superUserAcc = $xmlinput.Configuration.Farm.ObjectCacheAccounts.SuperUser
        $superReaderAcc = $xmlinput.Configuration.Farm.ObjectCacheAccounts.SuperReader
        # If the web app is using Claims auth, change the user accounts to the proper syntax
        If ($wa.UseClaimsAuthentication -eq $true)
        {
            $superUserAcc = 'i:0#.w|' + $superUserAcc
            $superReaderAcc = 'i:0#.w|' + $superReaderAcc
        }
        log " - Applying object cache accounts to `"$url`"..."
        $wa.Properties["portalsuperuseraccount"] = $superUserAcc
        Set-WebAppUserPolicy $wa $superUserAcc "Super User (Object Cache)" "Full Control"
        $wa.Properties["portalsuperreaderaccount"] = $superReaderAcc
        Set-WebAppUserPolicy $wa $superReaderAcc "Super Reader (Object Cache)" "Full Read"
        $wa.Update()
        log " - Done applying object cache accounts to `"$url`""
    }
    Catch
    {
        $_
        log "An error occurred applying object cache to `"$url`""
        #Pause "exit"
        # MK: added throw
        throw "ERROR: $($_.Exception.Message)"
    }
}

# ===================================================================================
# Func: ConfigureOnlineWebPartCatalog
# Desc: Enables / Disables access to the online web parts catalog for each web application
# ===================================================================================
Function ConfigureOnlineWebPartCatalog([System.Xml.XmlElement]$webApp)
{
    If ($webapp.GetAttribute("useOnlineWebPartCatalog") -ne "")
    {
        $url = $webApp.Url + ":" + $webApp.Port
        If ($url -like "*localhost*") {$url = $url -replace "localhost","$env:COMPUTERNAME"}
        log " - Setting online webpart catalog access for `"$url`""

        $wa = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webApp.Name}
        If ($webapp.GetAttribute("useOnlineWebPartCatalog") -eq "True")
        {
            $wa.AllowAccessToWebpartCatalog=$true
        }
        Else
        {
            $wa.AllowAccessToWebpartCatalog=$false
        }
        $wa.Update()
    }
}

# ===================================================================================
# Func: SetupManagedPaths
# Desc: Sets up managed paths for a given web application
# ===================================================================================
Function SetupManagedPaths([System.Xml.XmlElement]$webApp)
{
    $url = $webApp.Url + ":" + $webApp.Port
    If ($url -like "*localhost*") {$url = $url -replace "localhost","$env:COMPUTERNAME"}
    log " - Setting up managed paths for `"$url`""

    If ($webApp.ManagedPaths)
    {
        ForEach ($managedPath in $webApp.ManagedPaths.ManagedPath)
        {
            If ($managedPath.Delete -eq "true")
            {
                log "  - Deleting managed path `"$($managedPath.RelativeUrl)`" at `"$url`""
                Remove-SPManagedPath -Identity $managedPath.RelativeUrl -WebApplication $url -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
            Else
            {
                If ($managedPath.Explicit -eq "true")
                {
                    log "  - Setting up explicit managed path `"$($managedPath.RelativeUrl)`" at `"$url`" and HNSCs..."
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -WebApplication $url -Explicit -ErrorAction SilentlyContinue | Out-Null
                    # Let's create it for host-named site collections too, in case we have any
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -HostHeader -Explicit -ErrorAction SilentlyContinue | Out-Null
                }
                Else
                {
                    log "  - Setting up managed path `"$($managedPath.RelativeUrl)`" at `"$url`" and HNSCs..."
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -WebApplication $url -ErrorAction SilentlyContinue | Out-Null
                    # Let's create it for host-named site collections too, in case we have any
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -HostHeader -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    }

    log " - Done setting up managed paths at `"$url`""
}
#EndRegion

#Region Create User Profile Service Application
# ===================================================================================
# Func: CreateUserProfileServiceApplication
# Desc: Create the User Profile Service Application
# ===================================================================================
Function CreateUserProfileServiceApplication([xml]$xmlinput)
{
    # Based on http://sharepoint.microsoft.com/blogs/zach/Lists/Posts/Post.aspx?ID=50
    Try
    {
        Get-MajorVersionNumber $xmlinput
        $userProfile = $xmlinput.Configuration.ServiceApps.UserProfileServiceApp
        $mySiteWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "MySiteHost"}
        $dbPrefix = Get-DBPrefix $xmlinput
        # If we have asked to create a MySite Host web app, use that as the MySite host location
        if ($mySiteWebApp)
        {
            $mySiteName = $mySiteWebApp.name
            $mySiteURL = $mySiteWebApp.url
            $mySitePort = $mySiteWebApp.port
            $mySiteDBServer = $mySiteWebApp.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($mySiteDBServer))
            {
                $mySiteDBServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $mySiteDB = $dbPrefix+$mySiteWebApp.Database.Name
            $mySiteAppPoolAcct = Get-SPManagedAccountXML $xmlinput -CommonName "MySiteHost"
            if ([string]::IsNullOrEmpty($mySiteAppPoolAcct.username)) {throw " - `"MySiteHost`" managed account not found! Check your XML."}
        }
        $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
        $portalAppPoolAcct = Get-SPManagedAccountXML $xmlinput -CommonName "Portal"
        if ([string]::IsNullOrEmpty($portalAppPoolAcct.username)) {throw " - `"Portal`" managed account not found! Check your XML."}
        $farmAcct = $xmlinput.Configuration.Farm.Account.Username
        $farmAcctPWD = $xmlinput.Configuration.Farm.Account.Password
        # Get the content access accounts of each Search Service Application in the XML (in case there are multiple)
        foreach ($searchServiceApplication in $xmlinput.Configuration.ServiceApps.EnterpriseSearchService.EnterpriseSearchServiceApplications.EnterpriseSearchServiceApplication)
        {
            [array]$contentAccessAccounts += $searchServiceApplication.ContentAccessAccount
        }
        If (($farmAcctPWD -ne "") -and ($farmAcctPWD -ne $null)) {$farmAcctPWD = (ConvertTo-SecureString $farmAcctPWD -AsPlainText -force)}
        $mySiteTemplate = $mySiteWebApp.SiteCollections.SiteCollection.Template
        $mySiteLCID = $mySiteWebApp.SiteCollections.SiteCollection.LCID
        $userProfileServiceName = $userProfile.Name
        $userProfileServiceProxyName = $userProfile.ProxyName
        $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
        If($userProfileServiceName -eq $null) {$userProfileServiceName = "User Profile Service Application"}
        If($userProfileServiceProxyName -eq $null) {$userProfileServiceProxyName = $userProfileServiceName}
        If (!$farmCredential) {[System.Management.Automation.PsCredential]$farmCredential = GetFarmCredentials $xmlinput}
        if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
        {
            log " - Skipping setting the web app directory path name (not currently working on Windows 2012 w/SP2010)..."
            $pathSwitch = @{}
        }
        else
        {
            # Set the directory path for the web app to something a bit more friendly
            ImportWebAdministration
            # Get the default root location for web apps
            $iisWebDir = (Get-ItemProperty "IIS:\Sites\Default Web Site\" -name physicalPath -ErrorAction SilentlyContinue) -replace ("%SystemDrive%","$env:SystemDrive")
            If (!([string]::IsNullOrEmpty($iisWebDir)))
            {
                $pathSwitch = @{Path = "$iisWebDir\wss\VirtualDirectories\$webAppName-$port"}
            }
            else {$pathSwitch = @{}}
        }
        # Only set $hostHeaderSwitch to blank if the UseHostHeader value exists has explicitly been set to false
        if (!([string]::IsNullOrEmpty($webApp.UseHostHeader)) -and $webApp.UseHostHeader -eq $false)
        {
            $hostHeaderSwitch = @{}
        }
        else {$hostHeaderSwitch = @{HostHeader = $hostHeader}}

        If ((ShouldIProvision $userProfile -eq $true) -and (Get-Command -Name New-SPProfileServiceApplication -ErrorAction SilentlyContinue))
        {
            WriteLine
            log " - Provisioning $($userProfile.Name)"
            $applicationPool = Get-HostedServicesAppPool $xmlinput
            # get the service instance
            $profileServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.UserProfileServiceInstance"}
            $profileServiceInstance = $profileServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find User Profile Service instance" }
            # Start Service instance
            log " - Starting User Profile Service instance..."
            If (($profileServiceInstance.Status -eq "Disabled") -or ($profileServiceInstance.Status -ne "Online"))
            {
                $profileServiceInstance.Provision()
                If (-not $?) { Throw " - Failed to start User Profile Service instance" }
                # Wait
                log " - Waiting for User Profile Service..." 
                While ($profileServiceInstance.Status -ne "Online")
                {
                    log "." 
                    Start-Sleep 1
                    $profileServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.UserProfileServiceInstance"}
                    $profileServiceInstance = $profileServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                }
                log $($profileServiceInstance.Status)
            }
            # Create a Profile Service Application
            If ((Get-SPServiceApplication | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.UserProfileApplication"}) -eq $null)
            {
                # Create MySites Web Application if it doesn't already exist, and we've specified to create one
                $getSPWebApplication = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $mySiteName}
                If ($getSPWebApplication -eq $null -and ($mySiteWebApp))
                {
                    log " - Creating Web App `"$mySiteName`"..."
                    New-SPWebApplication -Name $mySiteName -ApplicationPoolAccount $($mySiteAppPoolAcct.username) -ApplicationPool $mySiteAppPool -DatabaseServer $mySiteDBServer -DatabaseName $mySiteDB -Url $mySiteURL -Port $mySitePort -SecureSocketsLayer:$mySiteUseSSL @hostHeaderSwitch @pathSwitch | Out-Null
                }
                Else
                {
                    log " - My Site host already provisioned."
                }

                # Create MySites Site Collection
                If ((Get-SPContentDatabase | Where-Object {$_.Name -eq $mySiteDB})-eq $null -and ($mySiteWebApp))
                {
                    log " - Creating My Sites content DB..."
                    $newMySitesDB = New-SPContentDatabase -DatabaseServer $mySiteDBServer -Name $mySiteDB -WebApplication "$mySiteURL`:$mySitePort"
                    If (-not $?) { Throw " - Failed to create My Sites content DB" }
                }
                If (!(Get-SPSite -Limit ALL | Where-Object {(($_.Url -like "$mySiteURL*") -and ($_.Port -eq "$mySitePort"))}) -and ($mySiteWebApp))
                {
                    log " - Creating My Sites site collection $mySiteURL`:$mySitePort..."
                    # Verify that the Language we're trying to create the site in is currently installed on the server
                    $mySiteCulture = [System.Globalization.CultureInfo]::GetCultureInfo(([convert]::ToInt32($mySiteLCID)))
                    $mySiteCultureDisplayName = $mySiteCulture.DisplayName
                    $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\$env:spVer.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}
                    If (!($installedOfficeServerLanguages | Where-Object {$_ -eq $mySiteCulture.Name}))
                    {
                        Throw " - You must install the `"$mySiteCulture ($mySiteCultureDisplayName)`" Language Pack before you can create a site using LCID $mySiteLCID"
                    }
                    Else
                    {
                        $newMySitesCollection = New-SPSite -Url "$mySiteURL`:$mySitePort" -OwnerAlias $farmAcct -SecondaryOwnerAlias $env:USERDOMAIN\$env:USERNAME -ContentDatabase $mySiteDB -Description $mySiteName -Name $mySiteName -Template $mySiteTemplate -Language $mySiteLCID | Out-Null
                        If (-not $?) {Throw " - Failed to create My Sites site collection"}
                        # Assign SSL certificate, if required
                        If ($mySiteUseSSL)
                        {
                            # Strip out any protocol and/or port values
                            $SSLHostHeader,$null = $mySiteHostLocation -replace "http://","" -replace "https://","" -split ":"
                            $SSLPort = $mySitePort
                            $SSLSiteName = $mySiteName
                            if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
                            {
                                log " - Assigning certificate(s) in a separate PowerShell window..."
                                Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList "-Command `". $env:dp0\AutoSPInstallerFunctions.ps1`; AssignCert $SSLHostHeader $SSLPort $SSLSiteName; Start-Sleep 2`"" -Wait
                            }
                            else {AssignCert $SSLHostHeader $SSLPort $SSLSiteName}
                        }
                    }
                }
                # Create Service App
                log " - Creating $userProfileServiceName..."
                CreateUPSAsAdmin $xmlinput
                log " - Waiting for $userProfileServiceName..." 
                $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                While ($profileServiceApp.Status -ne "Online")
                {
                    [int]$UPSWaitTime = 0
                    # Wait 2 minutes for either the UPS to be created, or the UAC prompt to time out
                    While (($UPSWaitTime -lt 120) -and ($profileServiceApp.Status -ne "Online"))
                    {
                        log "." 
                        Start-Sleep 1
                        $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                        [int]$UPSWaitTime += 1
                    }
                    # If it still isn't Online after 2 minutes, prompt to try again
                    If (!($profileServiceApp))
                    {
                        log "."
                        log "Timed out waiting for service creation (maybe a UAC prompt?). Try again in 30 sec"
                        
                        # MK: commented pause, added sleep
                        # log "`a`a`a" # System beeps
                        # Pause "try again"    
                        Start-Sleep 30
                 

                        CreateUPSAsAdmin $xmlinput
                        log " - Waiting for $userProfileServiceName..." 
                        $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                    }
                    Else {break}
                }
                log $($profileServiceApp.Status)
                # Wait a few seconds for the CreateUPSAsAdmin function to complete
                Start-Sleep 30

                # Get our new Profile Service App
                $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                If (!($profileServiceApp)) {Throw " - Could not get $userProfileServiceName!";}

                # Create Proxy
                log " - Creating $userProfileServiceName Proxy..."
                $profileServiceAppProxy  = New-SPProfileServiceApplicationProxy -Name "$userProfileServiceProxyName" -ServiceApplication $profileServiceApp -DefaultProxyGroup
                If (-not $?) { Throw " - Failed to create $userProfileServiceName Proxy" }

                log " - Granting rights to ($userProfileServiceName):"
                # Create a variable that contains the guid for the User Profile service for which you want to delegate permissions
                $serviceAppIDToSecure = Get-SPServiceApplication $($profileServiceApp.Id)

                # Create a variable that contains the list of administrators for the service application
                $profileServiceAppSecurity = Get-SPServiceApplicationSecurity $serviceAppIDToSecure -Admin
                # Create a variable that contains the permissions for the service application
                $profileServiceAppPermissions = Get-SPServiceApplicationSecurity $serviceAppIDToSecure

                # Create variables that contains the claims principals for current (Setup) user, genral service account, MySite App Pool, Portal App Pool and Content Access accounts
                # Then give 'Full Control' permissions to the current (Setup) user, general service account, MySite App Pool, Portal App Pool account and content access account claims principals
                $currentUserAcctPrincipal = New-SPClaimsPrincipal -Identity $env:USERDOMAIN\$env:USERNAME -IdentityType WindowsSamAccountName
                $spServiceAcctPrincipal = New-SPClaimsPrincipal -Identity $($spservice.username) -IdentityType WindowsSamAccountName
                Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $currentUserAcctPrincipal -Rights "Full Control"
                Grant-SPObjectSecurity $profileServiceAppPermissions -Principal $currentUserAcctPrincipal -Rights "Full Control"
                Grant-SPObjectSecurity $profileServiceAppPermissions -Principal $spServiceAcctPrincipal -Rights "Full Control"
                If ($mySiteAppPoolAcct)
                {
                    log "  - $($mySiteAppPoolAcct.username)..."
                    $mySiteAppPoolAcctPrincipal = New-SPClaimsPrincipal -Identity $($mySiteAppPoolAcct.username) -IdentityType WindowsSamAccountName
                    Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $mySiteAppPoolAcctPrincipal -Rights "Full Control"
                }
                If ($portalAppPoolAcct)
                {
                    log "  - $($portalAppPoolAcct.username)..."
                    $portalAppPoolAcctPrincipal = New-SPClaimsPrincipal -Identity $($portalAppPoolAcct.username) -IdentityType WindowsSamAccountName
                    Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $portalAppPoolAcctPrincipal -Rights "Full Control"
                }
                If ($contentAccessAccounts)
                {
                    foreach ($contentAccessAcct in $contentAccessAccounts)
                    {
                        # Give 'Retrieve People Data for Search Crawlers' permissions to the Content Access claims principal
                        log "  - $contentAccessAcct..."
                        $contentAccessAcctPrincipal = New-SPClaimsPrincipal -Identity $contentAccessAcct -IdentityType WindowsSamAccountName
                        Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $contentAccessAcctPrincipal -Rights "Retrieve People Data for Search Crawlers"
                    }
                }

                # Apply the changes to the User Profile service application
                Set-SPServiceApplicationSecurity $serviceAppIDToSecure -objectSecurity $profileServiceAppSecurity -Admin
                Set-SPServiceApplicationSecurity $serviceAppIDToSecure -objectSecurity $profileServiceAppPermissions
                log " - Done granting rights."

                # Add link to resources list
                AddResourcesLink "User Profile Administration" ("_layouts/ManageUserProfileServiceApplication.aspx?ApplicationID=" +  $profileServiceApp.Id)

                If ($portalAppPoolAcct)
                {
                    # Grant the Portal App Pool account rights to the Profile and Social DBs
                    $profileDB = $dbPrefix+$userProfile.Database.ProfileDB
                    $socialDB = $dbPrefix+$userProfile.Database.SocialDB
                    log " - Granting $($portalAppPoolAcct.username) rights to $mySiteDB..."
                    Get-SPDatabase | ? {$_.Name -eq $mySiteDB} | Add-SPShellAdmin -UserName $($portalAppPoolAcct.username)
                    log " - Granting $($portalAppPoolAcct.username) rights to $profileDB..."
                    Get-SPDatabase | ? {$_.Name -eq $profileDB} | Add-SPShellAdmin -UserName $($portalAppPoolAcct.username)
                    log " - Granting $($portalAppPoolAcct.username) rights to $socialDB..."
                    Get-SPDatabase | ? {$_.Name -eq $socialDB} | Add-SPShellAdmin -UserName $($portalAppPoolAcct.username)
                }
                log " - Enabling the Activity Feed Timer Job.."
                If ($profileServiceApp) {Get-SPTimerJob | ? {$_.TypeName -eq "Microsoft.Office.Server.ActivityFeed.ActivityFeedUPAJob"} | Enable-SPTimerJob}

                log " - Done creating $userProfileServiceName."
            }


            # Start User Profile Synchronization Service
            # Get User Profile Service
            $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}

            If ($profileServiceApp -and ($userProfile.StartProfileSync -eq $true))
            {
                If ($userProfile.EnableNetBIOSDomainNames -eq $true)
                {
                    log " - Enabling NetBIOS domain names for $userProfileServiceName..."
                    $profileServiceApp.NetBIOSDomainNamesEnabled = 1
                    $profileServiceApp.Update()
                }

                # Get User Profile Synchronization Service
                log " - Checking User Profile Synchronization Service..." 
                $profileSyncServices = @(Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.ProfileSynchronizationServiceInstance"})
                
                $synchServer = $userProfile.SynchServer

                $profileSyncService = $profileSyncServices | ? {MatchComputerName $_.Parent.Address $synchServer}
                
                # Attempt to start only if there are no online Profile Sync Service instances in the farm as we don't want to start multiple Sync instances (running against the same Profile Service at least)
                If (!($profileSyncServices | ? {$_.Status -eq "Online"}))
                {
                    # Inspired by http://technet.microsoft.com/en-us/library/ee721049.aspx
                    If (!($farmAcct)) {$farmAcct = (Get-SPFarm).DefaultServiceAccount}
                    If (!($farmAcctPWD))
                    {
                        log "`n"
                        throw "ERROR: Missing Farm Account Password"
                    }
                    log "`n"

                    # Check for an existing UPS credentials timer job (e.g. from a prior provisioning attempt), and delete it
                    $UPSCredentialsJob = Get-SPTimerJob | ? {$_.Name -eq "windows-service-credentials-FIMSynchronizationService"}
                    If ($UPSCredentialsJob.Status -eq "Online")
                    {
                        log " - Deleting existing sync credentials timer job..."
                        $UPSCredentialsJob.Delete()
                    }

                    # MK: start synch service must run under farm account identity
                    $farmAcct = $xmlinput.Configuration.Farm.Account.Username
                    # UpdateProcessIdentity $profileSyncService
                    UpdateProcessIdentityToRunAs  $profileSyncService $farmAcct
                    # MK: end
                    
                    $profileSyncService.Update()
                    log " - Waiting for User Profile Synchronization Service..." 
                    # Provision the User Profile Sync Service
                    $profileServiceApp.SetSynchronizationMachine($synchServer, $profileSyncService.Id, $farmAcct, (ConvertTo-PlainText $farmAcctPWD))
                    If (($profileSyncService.Status -ne "Provisioning") -and ($profileSyncService.Status -ne "Online")) {log "`n - Waiting for User Profile Synchronization Service to start..." }
                    # Monitor User Profile Sync service status
                    While ($profileSyncService.Status -ne "Online")
                    {
                        While ($profileSyncService.Status -ne "Provisioning")
                        {
                            log "." 
                            Start-Sleep 1
                            $profileSyncService = @(Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.ProfileSynchronizationServiceInstance"}) | ? {MatchComputerName $_.Parent.Address $synchServer}
                        }
                        If ($profileSyncService.Status -eq "Provisioning")
                        {
                            log $($profileSyncService.Status)
                            log " - Provisioning User Profile Sync Service, please wait..." 
                        }
                        While($profileSyncService.Status -eq "Provisioning" -and $profileSyncService.Status -ne "Disabled")
                        {
                            log "." 
                            Start-Sleep 1
                            $profileSyncService = @(Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.ProfileSynchronizationServiceInstance"}) | ? {MatchComputerName $_.Parent.Address $synchServer}
                        }
                        If ($profileSyncService.Status -ne "Online")
                        {
                            log ".`a`a"
                            log " - User Profile Synchronization Service could not be started!"
                            break
                        }
                        Else
                        {
                            log $($profileSyncService.Status)
                            # Need to recycle the Central Admin app pool before we can do anything with the User Profile Sync Service
                            log " - Recycling Central Admin app pool..."
                            # From http://sharepoint.nauplius.net/2011/09/iisreset-not-required-after-starting.html
                            $appPool = gwmi -Namespace "root\MicrosoftIISv2" -class "IIsApplicationPool" | where {$_.Name -eq "W3SVC/APPPOOLS/SharePoint Central Administration v4"}
                            If ($appPool)
                            {
                                $appPool.Recycle()
                            }
                            $newlyProvisionedSync = $true
                        }
                    }

                    # Attempt to create a sync connection only on a successful, newly-provisioned User Profile Sync service
                    # We don't have the ability to check for existing connections and we don't want to overwrite/duplicate any existing sync connections
                    # Note that this isn't really supported anyhow, and that only SharePoint 2010 Service Pack 1 and above includes the Add-SPProfileSyncConnection cmdlet
                    If ((CheckFor2010SP1) -and ($userProfile.CreateDefaultSyncConnection -eq $true) -and ($newlyProvisionedSync -eq $true))
                    {
                        log " - Creating a default Profile Sync connection..."
                        $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                        # Thanks to Codeplex user Reshetkov for this ingenious one-liner to build the default domain OU
                        $connectionSyncOU = "DC="+$env:USERDNSDOMAIN -replace "\.",",DC="
                        $syncConnectionDomain,$syncConnectionAcct = ($userProfile.SyncConnectionAccount) -split "\\"
                        $addProfileSyncCmd = @"
Add-PsSnapin Microsoft.SharePoint.PowerShell
Write-Host " - Creating default Sync connection..."
`$syncConnectionAcctPWD = (ConvertTo-SecureString -String `'$($userProfile.SyncConnectionAccountPassword)`' -AsPlainText -Force)
Add-SPProfileSyncConnection -ProfileServiceApplication $($profileServiceApp.Id) -ConnectionForestName $env:USERDNSDOMAIN -ConnectionDomain $syncConnectionDomain -ConnectionUserName "$syncConnectionAcct" -ConnectionSynchronizationOU "$connectionSyncOU" -ConnectionPassword `$syncConnectionAcctPWD
If (!`$?)
{
Write-Host "Press any key to exit..."
`$null = `$host.UI.RawUI.ReadKey(`"NoEcho,IncludeKeyDown`")
}
Else {Write-Host " - Done.";Start-Sleep 15}
"@
                        $addProfileScriptFile = "$((Get-Item $env:TEMP).FullName)\AutoSPInstaller-AddProfileSyncCmd.ps1"
                        $addProfileSyncCmd | Out-File $addProfileScriptFile
                        if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
                        {
                            $versionSwitch = "-Version 2"
                        }
                        else {$versionSwitch = ""}
                        # Run our Add-SPProfileSyncConnection script as the Farm Account - doesn't seem to work otherwise
                        Start-Process -WorkingDirectory $PSHOME -FilePath "powershell.exe" -Credential $farmCredential -ArgumentList "-ExecutionPolicy Bypass -Command Start-Process -WorkingDirectory `"'$PSHOME'`" -FilePath `"'powershell.exe'`" -ArgumentList `"'$versionSwitch -ExecutionPolicy Bypass $addProfileScriptFile'`" -Verb Runas" -Wait
                        # Give Add-SPProfileSyncConnection time to complete before continuing
                        Start-Sleep 120
                        Remove-Item -LiteralPath $addProfileScriptFile -Force -ErrorAction SilentlyContinue
                    }
                }
                Else {log "Already started."}
            }
            Else
            {
                log " - Could not get User Profile Service, or StartProfileSync is False."
            }
            WriteLine
        }
    }
    Catch
    {
        Throw " - Error Provisioning the User Profile Service Application. $($_.Exception.Message)"
    }
}

Function CreateUserProfileServiceApplication_ORIGINAL([xml]$xmlinput)
{
    # Based on http://sharepoint.microsoft.com/blogs/zach/Lists/Posts/Post.aspx?ID=50
    Try
    {
        Get-MajorVersionNumber $xmlinput
        $userProfile = $xmlinput.Configuration.ServiceApps.UserProfileServiceApp
        $mySiteWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "MySiteHost"}
        $dbPrefix = Get-DBPrefix $xmlinput
        # If we have asked to create a MySite Host web app, use that as the MySite host location
        if ($mySiteWebApp)
        {
            $mySiteName = $mySiteWebApp.name
            $mySiteURL = $mySiteWebApp.url
            $mySitePort = $mySiteWebApp.port
            $mySiteDBServer = $mySiteWebApp.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($mySiteDBServer))
            {
                $mySiteDBServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $mySiteDB = $dbPrefix+$mySiteWebApp.Database.Name
            $mySiteAppPoolAcct = Get-SPManagedAccountXML $xmlinput -CommonName "MySiteHost"
            if ([string]::IsNullOrEmpty($mySiteAppPoolAcct.username)) {throw " - `"MySiteHost`" managed account not found! Check your XML."}
        }
        $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
        $portalAppPoolAcct = Get-SPManagedAccountXML $xmlinput -CommonName "Portal"
        if ([string]::IsNullOrEmpty($portalAppPoolAcct.username)) {throw " - `"Portal`" managed account not found! Check your XML."}
        $farmAcct = $xmlinput.Configuration.Farm.Account.Username
        $farmAcctPWD = $xmlinput.Configuration.Farm.Account.Password
        # Get the content access accounts of each Search Service Application in the XML (in case there are multiple)
        foreach ($searchServiceApplication in $xmlinput.Configuration.ServiceApps.EnterpriseSearchService.EnterpriseSearchServiceApplications.EnterpriseSearchServiceApplication)
        {
            [array]$contentAccessAccounts += $searchServiceApplication.ContentAccessAccount
        }
        If (($farmAcctPWD -ne "") -and ($farmAcctPWD -ne $null)) {$farmAcctPWD = (ConvertTo-SecureString $farmAcctPWD -AsPlainText -force)}
        $mySiteTemplate = $mySiteWebApp.SiteCollections.SiteCollection.Template
        $mySiteLCID = $mySiteWebApp.SiteCollections.SiteCollection.LCID
        $userProfileServiceName = $userProfile.Name
        $userProfileServiceProxyName = $userProfile.ProxyName
        $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
        If($userProfileServiceName -eq $null) {$userProfileServiceName = "User Profile Service Application"}
        If($userProfileServiceProxyName -eq $null) {$userProfileServiceProxyName = $userProfileServiceName}
        If (!$farmCredential) {[System.Management.Automation.PsCredential]$farmCredential = GetFarmCredentials $xmlinput}
        if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
        {
            log " - Skipping setting the web app directory path name (not currently working on Windows 2012 w/SP2010)..."
            $pathSwitch = @{}
        }
        else
        {
            # Set the directory path for the web app to something a bit more friendly
            ImportWebAdministration
            # Get the default root location for web apps
            $iisWebDir = (Get-ItemProperty "IIS:\Sites\Default Web Site\" -name physicalPath -ErrorAction SilentlyContinue) -replace ("%SystemDrive%","$env:SystemDrive")
            If (!([string]::IsNullOrEmpty($iisWebDir)))
            {
                $pathSwitch = @{Path = "$iisWebDir\wss\VirtualDirectories\$webAppName-$port"}
            }
            else {$pathSwitch = @{}}
        }
        # Only set $hostHeaderSwitch to blank if the UseHostHeader value exists has explicitly been set to false
        if (!([string]::IsNullOrEmpty($webApp.UseHostHeader)) -and $webApp.UseHostHeader -eq $false)
        {
            $hostHeaderSwitch = @{}
        }
        else {$hostHeaderSwitch = @{HostHeader = $hostHeader}}

        If ((ShouldIProvision $userProfile -eq $true) -and (Get-Command -Name New-SPProfileServiceApplication -ErrorAction SilentlyContinue))
        {
            WriteLine
            log " - Provisioning $($userProfile.Name)"
            $applicationPool = Get-HostedServicesAppPool $xmlinput
            # get the service instance
            $profileServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.UserProfileServiceInstance"}
            $profileServiceInstance = $profileServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find User Profile Service instance" }
            # Start Service instance
            log " - Starting User Profile Service instance..."
            If (($profileServiceInstance.Status -eq "Disabled") -or ($profileServiceInstance.Status -ne "Online"))
            {
                $profileServiceInstance.Provision()
                If (-not $?) { Throw " - Failed to start User Profile Service instance" }
                # Wait
                log " - Waiting for User Profile Service..." 
                While ($profileServiceInstance.Status -ne "Online")
                {
                    log "." 
                    Start-Sleep 1
                    $profileServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.UserProfileServiceInstance"}
                    $profileServiceInstance = $profileServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                }
                log $($profileServiceInstance.Status)
            }
            # Create a Profile Service Application
            If ((Get-SPServiceApplication | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.UserProfileApplication"}) -eq $null)
            {
                # Create MySites Web Application if it doesn't already exist, and we've specified to create one
                $getSPWebApplication = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $mySiteName}
                If ($getSPWebApplication -eq $null -and ($mySiteWebApp))
                {
                    log " - Creating Web App `"$mySiteName`"..."
                    New-SPWebApplication -Name $mySiteName -ApplicationPoolAccount $($mySiteAppPoolAcct.username) -ApplicationPool $mySiteAppPool -DatabaseServer $mySiteDBServer -DatabaseName $mySiteDB -Url $mySiteURL -Port $mySitePort -SecureSocketsLayer:$mySiteUseSSL @hostHeaderSwitch @pathSwitch | Out-Null
                }
                Else
                {
                    log " - My Site host already provisioned."
                }

                # Create MySites Site Collection
                If ((Get-SPContentDatabase | Where-Object {$_.Name -eq $mySiteDB})-eq $null -and ($mySiteWebApp))
                {
                    log " - Creating My Sites content DB..."
                    $newMySitesDB = New-SPContentDatabase -DatabaseServer $mySiteDBServer -Name $mySiteDB -WebApplication "$mySiteURL`:$mySitePort"
                    If (-not $?) { Throw " - Failed to create My Sites content DB" }
                }
                If (!(Get-SPSite -Limit ALL | Where-Object {(($_.Url -like "$mySiteURL*") -and ($_.Port -eq "$mySitePort"))}) -and ($mySiteWebApp))
                {
                    log " - Creating My Sites site collection $mySiteURL`:$mySitePort..."
                    # Verify that the Language we're trying to create the site in is currently installed on the server
                    $mySiteCulture = [System.Globalization.CultureInfo]::GetCultureInfo(([convert]::ToInt32($mySiteLCID)))
                    $mySiteCultureDisplayName = $mySiteCulture.DisplayName
                    $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\$env:spVer.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}
                    If (!($installedOfficeServerLanguages | Where-Object {$_ -eq $mySiteCulture.Name}))
                    {
                        Throw " - You must install the `"$mySiteCulture ($mySiteCultureDisplayName)`" Language Pack before you can create a site using LCID $mySiteLCID"
                    }
                    Else
                    {
                        $newMySitesCollection = New-SPSite -Url "$mySiteURL`:$mySitePort" -OwnerAlias $farmAcct -SecondaryOwnerAlias $env:USERDOMAIN\$env:USERNAME -ContentDatabase $mySiteDB -Description $mySiteName -Name $mySiteName -Template $mySiteTemplate -Language $mySiteLCID | Out-Null
                        If (-not $?) {Throw " - Failed to create My Sites site collection"}
                        # Assign SSL certificate, if required
                        If ($mySiteUseSSL)
                        {
                            # Strip out any protocol and/or port values
                            $SSLHostHeader,$null = $mySiteHostLocation -replace "http://","" -replace "https://","" -split ":"
                            $SSLPort = $mySitePort
                            $SSLSiteName = $mySiteName
                            if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
                            {
                                log " - Assigning certificate(s) in a separate PowerShell window..."
                                Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList "-Command `". $env:dp0\AutoSPInstallerFunctions.ps1`; AssignCert $SSLHostHeader $SSLPort $SSLSiteName; Start-Sleep 2`"" -Wait
                            }
                            else {AssignCert $SSLHostHeader $SSLPort $SSLSiteName}
                        }
                    }
                }
                # Create Service App
                log " - Creating $userProfileServiceName..."
                CreateUPSAsAdmin $xmlinput
                log " - Waiting for $userProfileServiceName..." 
                $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                While ($profileServiceApp.Status -ne "Online")
                {
                    [int]$UPSWaitTime = 0
                    # Wait 2 minutes for either the UPS to be created, or the UAC prompt to time out
                    While (($UPSWaitTime -lt 120) -and ($profileServiceApp.Status -ne "Online"))
                    {
                        log "." 
                        Start-Sleep 1
                        $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                        [int]$UPSWaitTime += 1
                    }
                    # If it still isn't Online after 2 minutes, prompt to try again
                    If (!($profileServiceApp))
                    {
                        log "."
                        log "Timed out waiting for service creation (maybe a UAC prompt?). Try again in 30 sec"
                        
                        # MK: commented pause, added sleep
                        # log "`a`a`a" # System beeps
                        # Pause "try again"    
                        Start-Sleep 30
                 

                        CreateUPSAsAdmin $xmlinput
                        log " - Waiting for $userProfileServiceName..." 
                        $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                    }
                    Else {break}
                }
                log $($profileServiceApp.Status)
                # Wait a few seconds for the CreateUPSAsAdmin function to complete
                Start-Sleep 30

                # Get our new Profile Service App
                $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                If (!($profileServiceApp)) {Throw " - Could not get $userProfileServiceName!";}

                # Create Proxy
                log " - Creating $userProfileServiceName Proxy..."
                $profileServiceAppProxy  = New-SPProfileServiceApplicationProxy -Name "$userProfileServiceProxyName" -ServiceApplication $profileServiceApp -DefaultProxyGroup
                If (-not $?) { Throw " - Failed to create $userProfileServiceName Proxy" }

                log " - Granting rights to ($userProfileServiceName):"
                # Create a variable that contains the guid for the User Profile service for which you want to delegate permissions
                $serviceAppIDToSecure = Get-SPServiceApplication $($profileServiceApp.Id)

                # Create a variable that contains the list of administrators for the service application
                $profileServiceAppSecurity = Get-SPServiceApplicationSecurity $serviceAppIDToSecure -Admin
                # Create a variable that contains the permissions for the service application
                $profileServiceAppPermissions = Get-SPServiceApplicationSecurity $serviceAppIDToSecure

                # Create variables that contains the claims principals for current (Setup) user, genral service account, MySite App Pool, Portal App Pool and Content Access accounts
                # Then give 'Full Control' permissions to the current (Setup) user, general service account, MySite App Pool, Portal App Pool account and content access account claims principals
                $currentUserAcctPrincipal = New-SPClaimsPrincipal -Identity $env:USERDOMAIN\$env:USERNAME -IdentityType WindowsSamAccountName
                $spServiceAcctPrincipal = New-SPClaimsPrincipal -Identity $($spservice.username) -IdentityType WindowsSamAccountName
                Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $currentUserAcctPrincipal -Rights "Full Control"
                Grant-SPObjectSecurity $profileServiceAppPermissions -Principal $currentUserAcctPrincipal -Rights "Full Control"
                Grant-SPObjectSecurity $profileServiceAppPermissions -Principal $spServiceAcctPrincipal -Rights "Full Control"
                If ($mySiteAppPoolAcct)
                {
                    log "  - $($mySiteAppPoolAcct.username)..."
                    $mySiteAppPoolAcctPrincipal = New-SPClaimsPrincipal -Identity $($mySiteAppPoolAcct.username) -IdentityType WindowsSamAccountName
                    Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $mySiteAppPoolAcctPrincipal -Rights "Full Control"
                }
                If ($portalAppPoolAcct)
                {
                    log "  - $($portalAppPoolAcct.username)..."
                    $portalAppPoolAcctPrincipal = New-SPClaimsPrincipal -Identity $($portalAppPoolAcct.username) -IdentityType WindowsSamAccountName
                    Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $portalAppPoolAcctPrincipal -Rights "Full Control"
                }
                If ($contentAccessAccounts)
                {
                    foreach ($contentAccessAcct in $contentAccessAccounts)
                    {
                        # Give 'Retrieve People Data for Search Crawlers' permissions to the Content Access claims principal
                        log "  - $contentAccessAcct..."
                        $contentAccessAcctPrincipal = New-SPClaimsPrincipal -Identity $contentAccessAcct -IdentityType WindowsSamAccountName
                        Grant-SPObjectSecurity $profileServiceAppSecurity -Principal $contentAccessAcctPrincipal -Rights "Retrieve People Data for Search Crawlers"
                    }
                }

                # Apply the changes to the User Profile service application
                Set-SPServiceApplicationSecurity $serviceAppIDToSecure -objectSecurity $profileServiceAppSecurity -Admin
                Set-SPServiceApplicationSecurity $serviceAppIDToSecure -objectSecurity $profileServiceAppPermissions
                log " - Done granting rights."

                # Add link to resources list
                AddResourcesLink "User Profile Administration" ("_layouts/ManageUserProfileServiceApplication.aspx?ApplicationID=" +  $profileServiceApp.Id)

                If ($portalAppPoolAcct)
                {
                    # Grant the Portal App Pool account rights to the Profile and Social DBs
                    $profileDB = $dbPrefix+$userProfile.Database.ProfileDB
                    $socialDB = $dbPrefix+$userProfile.Database.SocialDB
                    log " - Granting $($portalAppPoolAcct.username) rights to $mySiteDB..."
                    Get-SPDatabase | ? {$_.Name -eq $mySiteDB} | Add-SPShellAdmin -UserName $($portalAppPoolAcct.username)
                    log " - Granting $($portalAppPoolAcct.username) rights to $profileDB..."
                    Get-SPDatabase | ? {$_.Name -eq $profileDB} | Add-SPShellAdmin -UserName $($portalAppPoolAcct.username)
                    log " - Granting $($portalAppPoolAcct.username) rights to $socialDB..."
                    Get-SPDatabase | ? {$_.Name -eq $socialDB} | Add-SPShellAdmin -UserName $($portalAppPoolAcct.username)
                }
                log " - Enabling the Activity Feed Timer Job.."
                If ($profileServiceApp) {Get-SPTimerJob | ? {$_.TypeName -eq "Microsoft.Office.Server.ActivityFeed.ActivityFeedUPAJob"} | Enable-SPTimerJob}

                log " - Done creating $userProfileServiceName."
            }


            # Start User Profile Synchronization Service
            # Get User Profile Service
            $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}

            If ($profileServiceApp -and ($userProfile.StartProfileSync -eq $true))
            {
                If ($userProfile.EnableNetBIOSDomainNames -eq $true)
                {
                    log " - Enabling NetBIOS domain names for $userProfileServiceName..."
                    $profileServiceApp.NetBIOSDomainNamesEnabled = 1
                    $profileServiceApp.Update()
                }

                # Get User Profile Synchronization Service
                log " - Checking User Profile Synchronization Service..." 
                $profileSyncServices = @(Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.ProfileSynchronizationServiceInstance"})
                $profileSyncService = $profileSyncServices | ? {MatchComputerName $_.Parent.Address $env:COMPUTERNAME}
                # Attempt to start only if there are no online Profile Sync Service instances in the farm as we don't want to start multiple Sync instances (running against the same Profile Service at least)
                If (!($profileSyncServices | ? {$_.Status -eq "Online"}))
                {
                    # Inspired by http://technet.microsoft.com/en-us/library/ee721049.aspx
                    If (!($farmAcct)) {$farmAcct = (Get-SPFarm).DefaultServiceAccount}
                    If (!($farmAcctPWD))
                    {
                        log "`n"
                        $farmAcctPWD = Read-Host -Prompt " - Please (re-)enter the Farm Account Password" -AsSecureString
                    }
                    log "`n"

                    # Check for an existing UPS credentials timer job (e.g. from a prior provisioning attempt), and delete it
                    $UPSCredentialsJob = Get-SPTimerJob | ? {$_.Name -eq "windows-service-credentials-FIMSynchronizationService"}
                    If ($UPSCredentialsJob.Status -eq "Online")
                    {
                        log " - Deleting existing sync credentials timer job..."
                        $UPSCredentialsJob.Delete()
                    }

                    # MK: start synch service must run under farm account identity
                    $farmAcct = $xmlinput.Configuration.Farm.Account.Username
                    # UpdateProcessIdentity $profileSyncService
                    UpdateProcessIdentityToRunAs  $profileSyncService $farmAcct
                    # MK: end
                    
                    $profileSyncService.Update()
                    log " - Waiting for User Profile Synchronization Service..." 
                    # Provision the User Profile Sync Service
                    $profileServiceApp.SetSynchronizationMachine($env:COMPUTERNAME, $profileSyncService.Id, $farmAcct, (ConvertTo-PlainText $farmAcctPWD))
                    If (($profileSyncService.Status -ne "Provisioning") -and ($profileSyncService.Status -ne "Online")) {log "`n - Waiting for User Profile Synchronization Service to start..." }
                    # Monitor User Profile Sync service status
                    While ($profileSyncService.Status -ne "Online")
                    {
                        While ($profileSyncService.Status -ne "Provisioning")
                        {
                            log "." 
                            Start-Sleep 1
                            $profileSyncService = @(Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.ProfileSynchronizationServiceInstance"}) | ? {MatchComputerName $_.Parent.Address $env:COMPUTERNAME}
                        }
                        If ($profileSyncService.Status -eq "Provisioning")
                        {
                            log $($profileSyncService.Status)
                            log " - Provisioning User Profile Sync Service, please wait..." 
                        }
                        While($profileSyncService.Status -eq "Provisioning" -and $profileSyncService.Status -ne "Disabled")
                        {
                            log "." 
                            Start-Sleep 1
                            $profileSyncService = @(Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Administration.ProfileSynchronizationServiceInstance"}) | ? {MatchComputerName $_.Parent.Address $env:COMPUTERNAME}
                        }
                        If ($profileSyncService.Status -ne "Online")
                        {
                            log ".`a`a"
                            log " - User Profile Synchronization Service could not be started!"
                            break
                        }
                        Else
                        {
                            log $($profileSyncService.Status)
                            # Need to recycle the Central Admin app pool before we can do anything with the User Profile Sync Service
                            log " - Recycling Central Admin app pool..."
                            # From http://sharepoint.nauplius.net/2011/09/iisreset-not-required-after-starting.html
                            $appPool = gwmi -Namespace "root\MicrosoftIISv2" -class "IIsApplicationPool" | where {$_.Name -eq "W3SVC/APPPOOLS/SharePoint Central Administration v4"}
                            If ($appPool)
                            {
                                $appPool.Recycle()
                            }
                            $newlyProvisionedSync = $true
                        }
                    }

                    # Attempt to create a sync connection only on a successful, newly-provisioned User Profile Sync service
                    # We don't have the ability to check for existing connections and we don't want to overwrite/duplicate any existing sync connections
                    # Note that this isn't really supported anyhow, and that only SharePoint 2010 Service Pack 1 and above includes the Add-SPProfileSyncConnection cmdlet
                    If ((CheckFor2010SP1) -and ($userProfile.CreateDefaultSyncConnection -eq $true) -and ($newlyProvisionedSync -eq $true))
                    {
                        log " - Creating a default Profile Sync connection..."
                        $profileServiceApp = Get-SPServiceApplication |?{$_.DisplayName -eq $userProfileServiceName}
                        # Thanks to Codeplex user Reshetkov for this ingenious one-liner to build the default domain OU
                        $connectionSyncOU = "DC="+$env:USERDNSDOMAIN -replace "\.",",DC="
                        $syncConnectionDomain,$syncConnectionAcct = ($userProfile.SyncConnectionAccount) -split "\\"
                        $addProfileSyncCmd = @"
Add-PsSnapin Microsoft.SharePoint.PowerShell
Write-Host " - Creating default Sync connection..."
`$syncConnectionAcctPWD = (ConvertTo-SecureString -String `'$($userProfile.SyncConnectionAccountPassword)`' -AsPlainText -Force)
Add-SPProfileSyncConnection -ProfileServiceApplication $($profileServiceApp.Id) -ConnectionForestName $env:USERDNSDOMAIN -ConnectionDomain $syncConnectionDomain -ConnectionUserName "$syncConnectionAcct" -ConnectionSynchronizationOU "$connectionSyncOU" -ConnectionPassword `$syncConnectionAcctPWD
If (!`$?)
{
Write-Host "Press any key to exit..."
`$null = `$host.UI.RawUI.ReadKey(`"NoEcho,IncludeKeyDown`")
}
Else {Write-Host " - Done.";Start-Sleep 15}
"@
                        $addProfileScriptFile = "$((Get-Item $env:TEMP).FullName)\AutoSPInstaller-AddProfileSyncCmd.ps1"
                        $addProfileSyncCmd | Out-File $addProfileScriptFile
                        if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
                        {
                            $versionSwitch = "-Version 2"
                        }
                        else {$versionSwitch = ""}
                        # Run our Add-SPProfileSyncConnection script as the Farm Account - doesn't seem to work otherwise
                        Start-Process -WorkingDirectory $PSHOME -FilePath "powershell.exe" -Credential $farmCredential -ArgumentList "-ExecutionPolicy Bypass -Command Start-Process -WorkingDirectory `"'$PSHOME'`" -FilePath `"'powershell.exe'`" -ArgumentList `"'$versionSwitch -ExecutionPolicy Bypass $addProfileScriptFile'`" -Verb Runas" -Wait
                        # Give Add-SPProfileSyncConnection time to complete before continuing
                        Start-Sleep 120
                        Remove-Item -LiteralPath $addProfileScriptFile -Force -ErrorAction SilentlyContinue
                    }
                }
                Else {log "Already started."}
            }
            Else
            {
                log " - Could not get User Profile Service, or StartProfileSync is False."
            }
            WriteLine
        }
    }
    Catch
    {
        Throw " - Error Provisioning the User Profile Service Application. $($_.Exception.Message)"
    }
}
# ===================================================================================
# Func: CreateUPSAsAdmin
# Desc: Create the User Profile Service Application itself as the Farm Admin account, in a session with elevated privileges
#       This incorporates the workaround by @harbars & @glapointe http://www.harbar.net/archive/2010/10/30/avoiding-the-default-schema-issue-when-creating-the-user-profile.aspx
#       Modified to work within AutoSPInstaller (to pass our script variables to the Farm Account credential's PowerShell session)
# ===================================================================================

Function CreateUPSAsAdmin([xml]$xmlinput)
{
    Try
    {
        $mySiteWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "MySiteHost"}
        $mySiteManagedPath = $userProfile.MySiteManagedPath
        # If we have asked to create a MySite Host web app, use that as the MySite host location
        if ($mySiteWebApp)
        {
            $mySiteURL = $mySiteWebApp.url
            $mySitePort = $mySiteWebApp.port
            $mySiteHostLocation = $mySiteURL+":"+$mySitePort
        }
        else # Use the value provided in the $userProfile node
        {
            $mySiteHostLocation = $userProfile.MySiteHostLocation
        }
        if ([string]::IsNullOrEmpty($mySiteManagedPath))
        {
            # Don't specify the MySiteManagedPath switch if it was left blank. This will effectively use the default path of "personal/sites"
            # Note that an empty hashtable doesn't seem to work here so we just put an empty string
            $mySiteManagedPathSwitch = ""
        }
        else
        {
            # Attempt to use the path we specified in the XML
            $mySiteManagedPathSwitch = "-MySiteManagedPath `"$mySiteManagedPath`"" # This format required to parse properly in the script block below
        }
        $farmAcct = $xmlinput.Configuration.Farm.Account.Username
        $userProfileServiceName = $userProfile.Name
        $dbServer = $userProfile.Database.DBServer
        # If we haven't specified a DB Server then just use the default used by the Farm
        If ([string]::IsNullOrEmpty($dbServer))
        {
            $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
        }
        # Set the ProfileDBServer, SyncDBServer and SocialDBServer to the same value ($dbServer). Maybe in the future we'll want to get more granular...?
        $profileDBServer = $dbServer
        $syncDBServer = $dbServer
        $socialDBServer = $dbServer
        $dbPrefix = Get-DBPrefix $xmlinput
        $profileDB = $dbPrefix+$userProfile.Database.ProfileDB
        $syncDB = $dbPrefix+$userProfile.Database.SyncDB
        $socialDB = $dbPrefix+$userProfile.Database.SocialDB
        $applicationPool = Get-HostedServicesAppPool $xmlinput
        If (!$farmCredential) {[System.Management.Automation.PsCredential]$farmCredential = GetFarmCredentials $xmlinput}
        $scriptFile = "$((Get-Item $env:TEMP).FullName)\AutoSPInstaller-ScriptBlock.ps1"
        # Write the script block, with expanded variables to a temporary script file that the Farm Account can get at
        
        Write-Output "Write-Host `"Creating $userProfileServiceName as $farmAcct...`"" | Out-File $scriptFile -Width 400
        Write-Output "Add-PsSnapin Microsoft.SharePoint.PowerShell" | Out-File $scriptFile -Width 400 -Append
        Write-Output "`$newProfileServiceApp = New-SPProfileServiceApplication -Name `"$userProfileServiceName`" -ApplicationPool `"$($applicationPool.Name)`" -ProfileDBServer $profileDBServer -ProfileDBName $profileDB -ProfileSyncDBServer $syncDBServer -ProfileSyncDBName $syncDB -SocialDBServer $socialDBServer -SocialDBName $socialDB -MySiteHostLocation $mySiteHostLocation $mySiteManagedPathSwitch" | Out-File $scriptFile -Width 400 -Append
        Write-Output "If (-not `$?) {Write-Error `" - Failed to create $userProfileServiceName`"; Write-Host `"Press any key to exit...`"; `$null = `$host.UI.RawUI.ReadKey`(`"NoEcho,IncludeKeyDown`"`)}" | Out-File $scriptFile -Width 400 -Append
        #Write-Output "If (-not `$?) {Write-Error `"ERROR - Failed to create $userProfileServiceName`"; exit -1}" | Out-File $scriptFile -Width 400 -Append
        # Grant the current install account rights to the newly-created Profile DB - needed since it's going to be running PowerShell commands against it
        Write-Output "`$profileDBId = Get-SPDatabase | ? {`$_.Name -eq `"$profileDB`"}" | Out-File $scriptFile -Width 400 -Append
        Write-Output "Add-SPShellAdmin -UserName `"$env:USERDOMAIN\$env:USERNAME`" -database `$profileDBId" | Out-File $scriptFile -Width 400 -Append
        # Grant the current install account rights to the newly-created Social DB as well
        Write-Output "`$socialDBId = Get-SPDatabase | ? {`$_.Name -eq `"$socialDB`"}" | Out-File $scriptFile -Width 400 -Append
        Write-Output "Add-SPShellAdmin -UserName `"$env:USERDOMAIN\$env:USERNAME`" -database `$socialDBId" | Out-File $scriptFile -Width 400 -Append
        # Add the -Version 2 switch in case we are installing SP2010 on Windows Server 2012 or 2012 R2
        if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
        {
            $versionSwitch = "-Version 2"
        }
        else {$versionSwitch = ""}

        # MK: we are not using remote install
        If (Confirm-LocalSession) # LOCAL SESSION Create the UPA as usual if this isn't a remote session
        {          
            # MK: starting a new process causes UAC to pop up which doesnt work in automated deployment
            # Start a process under the Farm Account's credentials, then spawn an elevated process within to finally execute the script file that actually creates the UPS
            #Start-Process -WorkingDirectory $PSHOME -FilePath "powershell.exe" -Credential $farmCredential -ArgumentList "-ExecutionPolicy Bypass -Command Start-Process -WorkingDirectory `"'$PSHOME'`" -FilePath `"'powershell.exe'`" -ArgumentList `"'$versionSwitch -ExecutionPolicy Bypass $scriptFile'`" -Verb Runas" -Wait

            # MK - start
            $newProfileServiceApp = New-SPProfileServiceApplication -Name $userProfileServiceName -ApplicationPool $applicationPool.Name -ProfileDBServer $profileDBServer -ProfileDBName $profileDB -ProfileSyncDBServer $syncDBServer -ProfileSyncDBName $syncDB -SocialDBServer $socialDBServer -SocialDBName $socialDB -MySiteHostLocation $mySiteHostLocation -MySiteManagedPath "personal"
            If (-not $?) 
            {
                throw "ERROR - Failed to create User Profile Service Application"; 
            }

            $profileDBId = Get-SPDatabase | ? {$_.Name -eq $profileDB}
            Add-SPShellAdmin -UserName $farmAcct -database $profileDBId

            $socialDBId = Get-SPDatabase | ? {$_.Name -eq $socialDB}
            Add-SPShellAdmin -UserName $farmAcct -database $socialDBId
            # MK - end
        }
        Else # REMOTE SESSION Do some fancy stuff to get this to work over a remote session
        {
            log " - Enabling remoting to $env:COMPUTERNAME..."
            Enable-WSManCredSSP -Role Client -Force -DelegateComputer $env:COMPUTERNAME | Out-Null # Yes that's right, we're going to "remote" into the local computer...
            Start-Sleep 10
            log " - Creating temporary `"remote`" session to $env:COMPUTERNAME..."
            $UPSession = New-PSSession -Name "UPS-Session" -Authentication Credssp -Credential $farmCredential -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue
            If (!$UPSession)
            {
                # Try again
                log "Couldn't create remote session to $env:COMPUTERNAME; trying again..."
                CreateUPSAsAdmin $xmlinput
            }
            # Pass the value of $scriptFile to the new session
            Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name ScriptFile -Value $value} -ArgumentList $scriptFile -Session $UPSession
            log " - Creating $userProfileServiceName under `"remote`" session..."
            # Start a (local) process (on our "remote" session), then spawn an elevated process within to finally execute the script file that actually creates the UPS
            Invoke-Command -ScriptBlock {Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList "-ExecutionPolicy Bypass $scriptFile" -Verb Runas} -Session $UPSession
        }
    }
    Catch
    {
        throw "ERROR: $($_.Exception.Message)"
    }
    finally
    {
        # Delete the temporary script file if we were successful in creating the UPA
        $profileServiceApp = Get-SPServiceApplication | ? {$_.DisplayName -eq $userProfileServiceName}
        If ($profileServiceApp) {Remove-Item -LiteralPath $scriptFile -Force}
    }
}
#EndRegion

#Region Create State Service Application
Function CreateStateServiceApp([xml]$xmlinput)
{
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.StateService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.AccessService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.VisioService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.AccessServices -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.ServiceApps.WebAnalyticsService -eq $true))
    {
        WriteLine
        Try
        {
            $stateService = $xmlinput.Configuration.ServiceApps.StateService
            $dbServer = $stateService.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($dbServer))
            {
                $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $dbPrefix = Get-DBPrefix $xmlinput
            $stateServiceDB = $dbPrefix+$stateService.Database.Name
            $stateServiceName = $stateService.Name
            $stateServiceProxyName = $stateService.ProxyName
            If ($stateServiceName -eq $null) {$stateServiceName = "State Service Application"}
            If ($stateServiceProxyName -eq $null) {$stateServiceProxyName = $stateServiceName}
            $getSPStateServiceApplication = Get-SPStateServiceApplication
            If ($getSPStateServiceApplication -eq $null)
            {
                log " - Provisioning State Service Application..."
                New-SPStateServiceDatabase -DatabaseServer $dbServer -Name $stateServiceDB | Out-Null
                New-SPStateServiceApplication -Name $stateServiceName -Database $stateServiceDB | Out-Null
                Get-SPStateServiceDatabase | Initialize-SPStateServiceDatabase | Out-Null
                log " - Creating State Service Application Proxy..."
                Get-SPStateServiceApplication | New-SPStateServiceApplicationProxy -Name $stateServiceProxyName -DefaultProxyGroup | Out-Null
                log " - Done creating State Service Application."
            }
            Else {log " - State Service Application already provisioned."}
        }
        Catch
        {
            throw "ERROR:  - Error provisioning the state service application. $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Create SP Usage Application
# ===================================================================================
# Func: CreateSPUsageApp
# Desc: Creates the Usage and Health Data Collection service application
# ===================================================================================
Function CreateSPUsageApp([xml]$xmlinput)
{
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.SPUsageService -eq $true) -and (Get-Command -Name New-SPUsageApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        Try
        {
            $dbServer = $xmlinput.Configuration.ServiceApps.SPUsageService.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($dbServer))
            {
                $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $spUsageApplicationName = $xmlinput.Configuration.ServiceApps.SPUsageService.Name
            $dbPrefix = Get-DBPrefix $xmlinput
            $spUsageDB = $dbPrefix+$xmlinput.Configuration.ServiceApps.SPUsageService.Database.Name
            $getSPUsageApplication = Get-SPUsageApplication
            If ($getSPUsageApplication -eq $null)
            {
                log " - Provisioning SP Usage Application..."
                New-SPUsageApplication -Name $spUsageApplicationName -DatabaseServer $dbServer -DatabaseName $spUsageDB | Out-Null
                # Need this to resolve a known issue with the Usage Application Proxy not automatically starting/provisioning
                # Thanks and credit to Jesper Nygaard Schi?tt (jesper@schioett.dk) per http://autospinstaller.codeplex.com/Thread/View.aspx?ThreadId=237578 !
                log " - Fixing Usage and Health Data Collection Proxy..."
                $spUsageApplicationProxy = Get-SPServiceApplicationProxy | where {$_.DisplayName -eq $spUsageApplicationName}
                $spUsageApplicationProxy.Provision()
                # End Usage Proxy Fix
                log " - Enabling usage processing timer job..."
                $usageProcessingJob = Get-SPTimerJob | ? {$_.TypeName -eq "Microsoft.SharePoint.Administration.SPUsageProcessingJobDefinition"}
                $usageProcessingJob.IsDisabled = $false
                $usageProcessingJob.Update()
                log " - Done provisioning SP Usage Application."
            }
            Else {log " - SP Usage Application already provisioned."}
        }
        Catch
        {
            Throw " - Error provisioning the SP Usage Application. $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Configure Logging

# ===================================================================================
# Func: ConfigureIISLogging
# Desc: Configures IIS Logging for the local server
# ===================================================================================
Function ConfigureIISLogging([xml]$xmlinput)
{
    WriteLine
    $IISLogConfig = $xmlinput.Configuration.Farm.Logging.IISLogs
    log " - Configuring IIS logging..."
    # New: Check for PowerShell version > 2 in case this is being run on Windows Server 2012
    If (!([string]::IsNullOrEmpty($IISLogConfig.Path)) -and $host.Version.Major -gt 2)
    {
        $IISLogDir = $IISLogConfig.Path
        EnsureFolder $IISLogDir
        ImportWebAdministration
        $oldIISLogDir = Get-WebConfigurationProperty "/system.applicationHost/sites/siteDefaults" -name logfile.directory.Value
        $oldIISLogDir = $oldIISLogDir -replace ("%SystemDrive%","$env:SystemDrive")
        If ($IISLogDir -ne $oldIISLogDir) # Only change the global IIS logging location if the desired location is different than the current
        {
            log " - Setting the global IIS logging location..."
            # The line below is from http://stackoverflow.com/questions/4626791/powershell-command-to-set-iis-logging-settings
            Set-WebConfigurationProperty "/system.applicationHost/sites/siteDefaults" -name logfile.directory -value $IISLogDir
            # TODO: Fix this so it actually moves all files within subfolders
            If (Test-Path -Path $oldIISLogDir)
            {
                log " - Moving any contents in old location $oldIISLogDir to $IISLogDir..."
                ForEach ($item in $(Get-ChildItem -Path $oldIISLogDir))
                {
                    Move-Item -Path $oldIISLogDir\$item -Destination $IISLogDir -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Else # Assume default value if none was specified in the XML input file
    {
        $IISLogDir = "$env:SystemDrive\Inetpub\logs" # We omit the trailing \LogFiles so we can compress the entire \logs\ folder including Failed Requests etc.
    }
    # Finally, enable NTFS compression on the IIS log location to save disk space
    If ($IISLogConfig.Compress -eq $true)
    {
        CompressFolder $IISLogDir
    }
    WriteLine
}

# ===================================================================================
# Func: ConfigureDiagnosticLogging
# Desc: Configures Diagnostic (ULS) Logging for the farm
# From: Originally suggested by Codeplex user leowu70: http://autospinstaller.codeplex.com/discussions/254499
#       And Codeplex user timiun: http://autospinstaller.codeplex.com/discussions/261598
# ===================================================================================
Function ConfigureDiagnosticLogging([xml]$xmlinput)
{
    WriteLine
    Get-MajorVersionNumber $xmlinput
    $ULSLogConfig = $xmlinput.Configuration.Farm.Logging.ULSLogs
    $ULSLogDir = $ULSLogConfig.LogLocation
    $ULSLogDiskSpace = $ULSLogConfig.LogDiskSpaceUsageGB
    $ULSLogRetention = $ULSLogConfig.DaysToKeepLogs
    $ULSLogCutInterval = $ULSLogConfig.LogCutInterval
    log " - Configuring SharePoint diagnostic (ULS) logging..."
    If (!([string]::IsNullOrEmpty($ULSLogDir)))
    {
        $doConfig = $true
        EnsureFolder $ULSLogDir
        $oldULSLogDir = $(Get-SPDiagnosticConfig).LogLocation
        $oldULSLogDir = $oldULSLogDir -replace ("%CommonProgramFiles%","$env:CommonProgramFiles")
    }
    Else # Assume default value if none was specified in the XML input file
    {
        $ULSLogDir = "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\LOGS"
    }
    If (!([string]::IsNullOrEmpty($ULSLogDiskSpace)))
    {
        $doConfig = $true
        $ULSLogMaxDiskSpaceUsageEnabled = $true
    }
    Else # Assume default values if none were specified in the XML input file
    {
        $ULSLogDiskSpace = 1000
        $ULSLogMaxDiskSpaceUsageEnabled = $false
    }
    If (!([string]::IsNullOrEmpty($ULSLogRetention)))
    {$doConfig = $true}
    Else # Assume default value if none was specified in the XML input file
    {
        $ULSLogRetention = 14
    }
    If (!([string]::IsNullOrEmpty($ULSLogCutInterval)))
    {$doConfig = $true}
    Else # Assume default value if none was specified in the XML input file
    {
        $ULSLogCutInterval = 30
    }
    # Only modify the Diagnostic Config if we have specified at least one value in the XML input file
    If ($doConfig)
    {
        log " - Setting SharePoint diagnostic (ULS) logging options:"
        log "  - DaysToKeepLogs: $ULSLogRetention"
        log "  - LogMaxDiskSpaceUsageEnabled: $ULSLogMaxDiskSpaceUsageEnabled"
        log "  - LogDiskSpaceUsageGB: $ULSLogDiskSpace"
        log "  - LogLocation: $ULSLogDir"
        log "  - LogCutInterval: $ULSLogCutInterval"
        Set-SPDiagnosticConfig -DaysToKeepLogs $ULSLogRetention -LogMaxDiskSpaceUsageEnabled:$ULSLogMaxDiskSpaceUsageEnabled -LogDiskSpaceUsageGB $ULSLogDiskSpace -LogLocation $ULSLogDir -LogCutInterval $ULSLogCutInterval
        # Only move log files if the old & new locations are different, and if the old location actually had a value
        If (($ULSLogDir -ne $oldULSLogDir) -and (!([string]::IsNullOrEmpty($oldULSLogDir))))
        {
            log " - Moving any contents in old location $oldULSLogDir to $ULSLogDir..."
            ForEach ($item in $(Get-ChildItem -Path $oldULSLogDir) | Where-Object {$_.Name -like "*.log"})
            {
                Move-Item -Path $oldULSLogDir\$item -Destination $ULSLogDir -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Finally, enable NTFS compression on the ULS log location to save disk space
    If ($ULSLogConfig.Compress -eq $true)
    {
        CompressFolder $ULSLogDir
    }
    WriteLine
}

# ===================================================================================
# Func: ConfigureUsageLogging
# Desc: Configures Usage Logging for the farm
# From: Submitted by Codeplex user deedubya (http://www.codeplex.com/site/users/view/deedubya); additional tweaks by @brianlala
# ===================================================================================
Function ConfigureUsageLogging([xml]$xmlinput)
{
    WriteLine
    If (Get-SPUsageService)
    {
        Get-MajorVersionNumber $xmlinput
        $usageLogConfig = $xmlinput.Configuration.Farm.Logging.UsageLogs
        $usageLogDir = $usageLogConfig.UsageLogDir
        $usageLogMaxSpaceGB = $usageLogConfig.UsageLogMaxSpaceGB
        $usageLogCutTime = $usageLogConfig.UsageLogCutTime
        log " - Configuring Usage Logging..."
        # Syntax for command: Set-SPUsageService [-LoggingEnabled {1 | 0}] [-UsageLogLocation <Path>] [-UsageLogMaxSpaceGB <1-20>] [-Verbose]
        # These are a per-farm settings, not per WSS Usage service application, as there can only be one per farm.
        Try
        {
            If (!([string]::IsNullOrEmpty($usageLogDir)))
            {
                EnsureFolder $usageLogDir
                $oldUsageLogDir = $(Get-SPUsageService).UsageLogDir
                $oldUsageLogDir = $oldUsageLogDir -replace ("%CommonProgramFiles%","$env:CommonProgramFiles")
            }
            Else # Assume default value if none was specified in the XML input file
            {
                $usageLogDir = "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\LOGS"
            }
            # UsageLogMaxSpaceGB must be between 1 and 20.
            If (($usageLogMaxSpaceGB -lt 1) -or ([string]::IsNullOrEmpty($usageLogMaxSpaceGB))) {$usageLogMaxSpaceGB = 5} # Default value
            If ($usageLogMaxSpaceGB -gt 20) {$usageLogMaxSpaceGB = 20} # Maximum value
            # UsageLogCutTime must be between 1 and 1440
            If (($usageLogCutTime -lt 1) -or ([string]::IsNullOrEmpty($usageLogCutTime))) {$usageLogCutTime = 30} # Default value
            If ($usageLogCutTime -gt 1440) {$usageLogCutTime = 1440} # Maximum value
            # Set-SPUsageService's LoggingEnabled is 0 for disabled, and 1 for enabled
            $loggingEnabled = 1
            Set-SPUsageService -LoggingEnabled $loggingEnabled -UsageLogLocation "$usageLogDir" -UsageLogMaxSpaceGB $usageLogMaxSpaceGB -UsageLogCutTime $usageLogCutTime | Out-Null
            # Only move log files if the old & new locations are different, and if the old location actually had a value
            If (($usageLogDir -ne $oldUsageLogDir) -and (!([string]::IsNullOrEmpty($oldUsageLogDir))))
            {
                log " - Moving any contents in old location $oldUsageLogDir to $usageLogDir..."
                ForEach ($item in $(Get-ChildItem -Path $oldUsageLogDir) | Where-Object {$_.Name -like "*.usage"})
                {
                    Move-Item -Path $oldUsageLogDir\$item -Destination $usageLogDir -Force -ErrorAction SilentlyContinue
                }
            }
            # Finally, enable NTFS compression on the usage log location to save disk space
            If ($usageLogConfig.Compress -eq $true)
            {
                CompressFolder $usageLogDir
            }
        }
        Catch
        {
            Throw " - Error configuring usage logging. $($_.Exception.Message)"
        }
        log " - Done configuring usage logging."
    }
    Else
    {
        log " - No usage service; skipping usage logging config."
    }
    WriteLine
}

#EndRegion

#Region Create Web Analytics Service Application
# Thanks and credit to Jesper Nygaard Schi?tt (jesper@schioett.dk) per http://autospinstaller.codeplex.com/Thread/View.aspx?ThreadId=237578 !

Function CreateWebAnalyticsApp([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.WebAnalyticsService -eq $true) -and ($env:spVer -eq "14"))
    {
        WriteLine
        Try
        {
            $dbServer = $xmlinput.Configuration.ServiceApps.WebAnalyticsService.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($dbServer))
            {
                $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $applicationPool = Get-HostedServicesAppPool $xmlinput
            $dbPrefix = Get-DBPrefix $xmlinput
            $webAnalyticsReportingDB = $dbPrefix+$xmlinput.Configuration.ServiceApps.WebAnalyticsService.Database.ReportingDB
            $webAnalyticsStagingDB = $dbPrefix+$xmlinput.Configuration.ServiceApps.WebAnalyticsService.Database.StagingDB
            $webAnalyticsServiceName = $xmlinput.Configuration.ServiceApps.WebAnalyticsService.Name
            $getWebAnalyticsServiceApplication = Get-SPWebAnalyticsServiceApplication $webAnalyticsServiceName -ea SilentlyContinue
            log " - Provisioning $webAnalyticsServiceName..."
            # Start Analytics service instances
            log " - Checking Analytics Service instances..."
            $analyticsWebServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.WebAnalytics.Administration.WebAnalyticsWebServiceInstance"}
            $analyticsWebServiceInstance = $analyticsWebServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find Analytics Web Service instance" }
            log " - Starting local Analytics Web Service instance..."
            $analyticsWebServiceInstance.Provision()
            $analyticsDataProcessingInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.WebAnalytics.Administration.WebAnalyticsServiceInstance"}
            $analyticsDataProcessingInstance = $analyticsDataProcessingInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find Analytics Data Processing Service instance" }
            UpdateProcessIdentity $analyticsDataProcessingInstance
            $analyticsDataProcessingInstance.Update()
            log " - Starting local Analytics Data Processing Service instance..."
            $analyticsDataProcessingInstance.Provision()
            If ($getWebAnalyticsServiceApplication -eq $null)
            {
                $stagerSubscription = "<StagingDatabases><StagingDatabase ServerName='$dbServer' DatabaseName='$webAnalyticsStagingDB'/></StagingDatabases>"
                $warehouseSubscription = "<ReportingDatabases><ReportingDatabase ServerName='$dbServer' DatabaseName='$webAnalyticsReportingDB'/></ReportingDatabases>"
                log " - Creating $webAnalyticsServiceName..."
                $serviceApplication = New-SPWebAnalyticsServiceApplication -Name $webAnalyticsServiceName -ReportingDataRetention 20 -SamplingRate 100 -ListOfReportingDatabases $warehouseSubscription -ListOfStagingDatabases $stagerSubscription -ApplicationPool $applicationPool
                # Create Web Analytics Service Application Proxy
                log " - Creating $webAnalyticsServiceName Proxy..."
                $newWebAnalyticsServiceApplicationProxy = New-SPWebAnalyticsServiceApplicationProxy  -Name $webAnalyticsServiceName -ServiceApplication $serviceApplication.Name
            }
            Else {log " - Web Analytics Service Application already provisioned."}
        }
        Catch
        {

            Throw " - Error Provisioning Web Analytics Service Application. $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Create Secure Store Service Application
Function CreateSecureStoreServiceApp
{
    # Secure Store Service Application will be provisioned even if it's been marked false, if any of these service apps have been requested, as it's a dependency.
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.SecureStoreService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.VisioService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.PerformancePointService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.ServiceApps.BusinessDataConnectivity -eq $true) -or `
        ((ShouldIProvision $xmlinput.Configuration.OfficeWebApps.ExcelService -eq $true) -and ($xmlinput.Configuration.OfficeWebApps.Install -eq $true)))
    {
        WriteLine
        Try
        {
            If (!($farmPassphrase) -or ($farmPassphrase -eq ""))
            {
                $farmPassphrase = GetFarmPassPhrase $xmlinput
            }
            $secureStoreServiceAppName = $xmlinput.Configuration.ServiceApps.SecureStoreService.Name
            $secureStoreServiceAppProxyName = $xmlinput.Configuration.ServiceApps.SecureStoreService.ProxyName
            If ($secureStoreServiceAppName -eq $null) {$secureStoreServiceAppName = "Secure Store Service"}
            If ($secureStoreServiceAppProxyName -eq $null) {$secureStoreServiceAppProxyName = $secureStoreServiceAppName}
            $dbServer = $xmlinput.Configuration.ServiceApps.SecureStoreService.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($dbServer))
            {
                $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $dbPrefix = Get-DBPrefix $xmlinput
            $secureStoreDB = $dbPrefix+$xmlinput.Configuration.ServiceApps.SecureStoreService.Database.Name
            log " - Provisioning Secure Store Service Application..."
            $applicationPool = Get-HostedServicesAppPool $xmlinput
            # Get the service instance
            $secureStoreServiceInstances = Get-SPServiceInstance | ? {$_.GetType().Equals([Microsoft.Office.SecureStoreService.Server.SecureStoreServiceInstance])}
            $secureStoreServiceInstance = $secureStoreServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find Secure Store service instance" }
            # Start Service instance
            If ($secureStoreServiceInstance.Status -eq "Disabled")
            {
                log " - Starting Secure Store Service Instance..."
                $secureStoreServiceInstance.Provision()
                If (-not $?) { Throw " - Failed to start Secure Store service instance" }
                # Wait
                log " - Waiting for Secure Store service..." 
                While ($secureStoreServiceInstance.Status -ne "Online")
                {
                    log "." 
                    Start-Sleep 1
                    $secureStoreServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.SecureStoreService.Server.SecureStoreServiceInstance"}
                    $secureStoreServiceInstance = $secureStoreServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                }
                log $($secureStoreServiceInstance.Status)
            }
            # Create Service Application
            $getSPSecureStoreServiceApplication = Get-SPServiceApplication | ? {$_.GetType().Equals([Microsoft.Office.SecureStoreService.Server.SecureStoreServiceApplication])}
            If ($getSPSecureStoreServiceApplication -eq $null)
            {
                log " - Creating Secure Store Service Application..."
                New-SPSecureStoreServiceApplication -Name $secureStoreServiceAppName -PartitionMode:$false -Sharing:$false -DatabaseServer $dbServer -DatabaseName $secureStoreDB -ApplicationPool $($applicationPool.Name) -AuditingEnabled:$true -AuditLogMaxSize 30 | Out-Null
                log " - Creating Secure Store Service Application Proxy..."
                Get-SPServiceApplication | ? {$_.GetType().Equals([Microsoft.Office.SecureStoreService.Server.SecureStoreServiceApplication])} | New-SPSecureStoreServiceApplicationProxy -Name $secureStoreServiceAppProxyName -DefaultProxyGroup | Out-Null
                log " - Done creating Secure Store Service Application."
            }
            Else {log " - Secure Store Service Application already provisioned."}

            $secureStore = Get-SPServiceApplicationProxy | Where {$_.GetType().Equals([Microsoft.Office.SecureStoreService.Server.SecureStoreServiceApplicationProxy])}
            Start-Sleep 5
            log " - Creating the Master Key..."
            Update-SPSecureStoreMasterKey -ServiceApplicationProxy $secureStore.Id -Passphrase $farmPassphrase
            Start-Sleep 5

            log " - Creating the Application Key..."
            Update-SPSecureStoreApplicationServerKey -ServiceApplicationProxy $secureStore.Id -Passphrase $farmPassphrase -ErrorAction SilentlyContinue
            Start-Sleep 5
            If (!$?)
            {
                # Try again...
                log " - Creating the Application Key (2nd attempt)..."
                Update-SPSecureStoreApplicationServerKey -ServiceApplicationProxy $secureStore.Id -Passphrase $farmPassphrase -ErrorAction SilentlyContinue
            }
        }
        Catch
        {
            Throw " - Error provisioning secure store application. $($_.Exception.Message)"
        }
        log " - Done creating/configuring Secure Store Service Application."
        WriteLine
    }
}
#EndRegion

#Region Start Search Query and Site Settings Service
Function StartSearchQueryAndSiteSettingsService
{
    If (ShouldIProvision $xmlinput.Configuration.Farm.Services.SearchQueryAndSiteSettingsService -eq $true)
    {
        WriteLine
        Try
        {
            # Get the service instance
            $searchQueryAndSiteSettingsServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Search.Administration.SearchQueryAndSiteSettingsServiceInstance"}
            $searchQueryAndSiteSettingsService = $searchQueryAndSiteSettingsServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find Search Query and Site Settings service instance" }
            # Start Service instance
            log " - Starting Search Query and Site Settings Service Instance..."
            If($searchQueryAndSiteSettingsService.Status -eq "Disabled")
            {
                $searchQueryAndSiteSettingsService.Provision()
                If (-not $?) { Throw " - Failed to start Search Query and Site Settings service instance" }
                # Wait
                log " - Waiting for Search Query and Site Settings service..." 
                While ($searchQueryAndSiteSettingsService.Status -ne "Online")
                {
                    log "." 
                    Start-Sleep 1
                    $searchQueryAndSiteSettingsServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Search.Administration.SearchQueryAndSiteSettingsServiceInstance"}
                    $searchQueryAndSiteSettingsService = $searchQueryAndSiteSettingsServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                }
                log $($searchQueryAndSiteSettingsService.Status)
            }
            Else {log " - Search Query and Site Settings Service already started."}
        }
        Catch
        {
            Throw " - Error provisioning Search Query and Site Settings Service. $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Configure Claims to Windows Token Service
Function ConfigureClaimsToWindowsTokenService
{
    # C2WTS is required by Excel Services, Visio Services and PerformancePoint Services; if any of these are being provisioned we should start it.
    If ((ShouldIProvision $xmlinput.Configuration.Farm.Services.ClaimsToWindowsTokenService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.VisioService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.PerformancePointService -eq $true) -or `
        ((ShouldIProvision $xmlinput.Configuration.OfficeWebApps.ExcelService -eq $true) -and ($xmlinput.Configuration.OfficeWebApps.Install -eq $true)))
    {
        WriteLine
        # Ensure Claims to Windows Token Service is started
        $claimsServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Administration.Claims.SPWindowsTokenServiceInstance"}
        $claimsService = $claimsServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
        If ($claimsService.Status -ne "Online")
        {
            Try
            {
                log " - Starting $($claimsService.DisplayName)..."
                if ($xmlinput.Configuration.Farm.Services.ClaimsToWindowsTokenService.UpdateAccount -eq $true)
                {
                    UpdateProcessIdentity $claimsService
                    $claimsService.Update()
                    # Add C2WTS account (currently the generic service account) to local admins
                    $builtinAdminGroup = Get-AdministratorsGroup
                    $adminGroup = ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group")
                    # This syntax comes from Ying Li (http://myitforum.com/cs2/blogs/yli628/archive/2007/08/30/powershell-script-to-add-remove-a-domain-user-to-the-local-administrators-group-on-a-remote-machine.aspx)
                    $localAdmins = $adminGroup.psbase.invoke("Members") | ForEach-Object {$_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)}
                    $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
                    $managedAccountGen = Get-SPManagedAccount | Where-Object {$_.UserName -eq $($spservice.username)}
                    $managedAccountDomain,$managedAccountUser = $managedAccountGen.UserName -split "\\"
                    If (!($localAdmins -contains $managedAccountUser))
                    {
                        log " - Adding $($managedAccountGen.Username) to local Administrators..."
                        ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Add("WinNT://$managedAccountDomain/$managedAccountUser")
                    }
                }
                $claimsService.Provision()
                If (-not $?) {throw " - Failed to start $($claimsService.DisplayName)"}
            }
            Catch
            {
                Throw " - An error occurred starting $($claimsService.DisplayName)"
            }
            #Wait
            log " - Waiting for $($claimsService.DisplayName)..." 
            While ($claimsService.Status -ne "Online")
            {
                log "." 
                sleep 1
                $claimsServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.Administration.Claims.SPWindowsTokenServiceInstance"}
                $claimsService = $claimsServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            }
            log $($claimsService.Status)
        }
        Else
        {
            log " - $($claimsService.DisplayName) already started."
        }
        log " - Setting C2WTS to depend on Cryptographic Services..."
        Start-Process -FilePath "$env:windir\System32\sc.exe" -ArgumentList "config c2wts depend= CryptSvc" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        WriteLine
    }
}
#EndRegion

#Region Stop Specified Service Instance
# ===================================================================================
# Func: StopServiceInstance
# Desc: Disables a specified service instance (e.g. on dedicated App servers or WFEs)
# ===================================================================================
Function StopServiceInstance ($service)
{
    WriteLine
    $serviceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq $service -and $_.Name -ne "WSS_Administration"} # Need to filter out WSS_Administration because the Central Administration service instance shares the same Type as the Foundation Web Application Service
    $serviceInstance = $serviceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
    log " - Stopping $($serviceInstance.TypeName)..."
    if ($serviceInstance.Status -eq "Online")
    {
        $serviceInstance.Unprovision()
        If (-not $?) {Throw " - Failed to stop $($serviceInstance.TypeName)" }
        # Wait
        log " - Waiting for $($serviceInstance.TypeName) to stop..." 
        While ($serviceInstance.Status -ne "Disabled")
        {
            log "." 
            Start-Sleep 1
            $serviceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq $service}
            $serviceInstance = $serviceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
        }
        log $($serviceInstance.Status -replace "Disabled","Stopped")
    }
    Else {log " - Already stopped."}
    WriteLine
}
#EndRegion

#Region Configure Workflow Timer Service
# ===================================================================================
# Func: ConfigureWorkflowTimerService
# Desc: Configures the Microsoft SharePoint Foundation Workflow Timer Service
# ===================================================================================
Function ConfigureWorkflowTimerService
{
    # Ensure the node exists in the XML first as we don't want to inadvertently disable the service if it wasn't explicitly specified
    if (($xmlinput.Configuration.Farm.Services.SelectSingleNode("WorkflowTimer")) -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.WorkflowTimer -eq $true))
    {
        StopServiceInstance "Microsoft.SharePoint.Workflow.SPWorkflowTimerServiceInstance"
    }
}
#EndRegion

#Region Configure Foundation Search
# ====================================================================================
# Func: ConfigureFoundationSearch
# Desc: Updates the service account for SPSearch4 (SharePoint Foundation (Help) Search)
# ====================================================================================

Function ConfigureFoundationSearch ([xml]$xmlinput)
# Does not actually provision Foundation Search as of yet, just updates the service account it would run under to mitigate Health Analyzer warnings
{
    Get-MajorVersionNumber $xmlinput
    # Make sure a credential deployment job doesn't already exist, and that we are running SP2010
    if ((!(Get-SPTimerJob -Identity "windows-service-credentials-SPSearch4")) -and ($env:spVer -eq "14"))
    {
        WriteLine
        Try
        {
            $foundationSearchService = (Get-SPFarm).Services | where {$_.Name -eq "SPSearch4"}
            $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
            UpdateProcessIdentity $foundationSearchService
        }
        Catch
        {
            Throw " - An error occurred updating the service account for SPSearch4. $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Configure SPTraceV4 (Logging)
# ====================================================================================
# Func: ConfigureTracing
# Desc: Updates the service account for SPTraceV4 (SharePoint Foundation (Help) Search)
# ====================================================================================

Function ConfigureTracing ([xml]$xmlinput)
{
    # Make sure a credential deployment job doesn't already exist
    if (!(Get-SPTimerJob -Identity "windows-service-credentials-SPTraceV4"))
    {
        WriteLine
        $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
        $spTraceV4 = (Get-SPFarm).Services | where {$_.Name -eq "SPTraceV4"}
        $appPoolAcctDomain,$appPoolAcctUser = $spservice.username -Split "\\"
        log " - Applying service account $($spservice.username) to service SPTraceV4..."
        #Add to Performance Monitor Users group
        log " - Adding $($spservice.username) to local Performance Monitor Users group..."
        Try
        {
            ([ADSI]"WinNT://$env:COMPUTERNAME/Performance Monitor Users,group").Add("WinNT://$appPoolAcctDomain/$appPoolAcctUser")
            If (-not $?) {Throw}
        }
        Catch
        {
            log " - $($spservice.username) is already a member of Performance Monitor Users."
        }
        #Add all managed accounts to Performance Log Users group
        foreach ($managedAccount in (Get-SPManagedAccount))
        {
            $appPoolAcctDomain,$appPoolAcctUser = $managedAccount.UserName -Split "\\"
            log " - Adding $($managedAccount.UserName) to local Performance Log Users group..."
            Try
            {
                ([ADSI]"WinNT://$env:COMPUTERNAME/Performance Log Users,group").Add("WinNT://$appPoolAcctDomain/$appPoolAcctUser")
                If (-not $?) {Throw}
            }
            Catch
            {
                log "  - $($managedAccount.UserName) is already a member of Performance Log Users."
            }
        }
        Try
        {
            UpdateProcessIdentity $spTraceV4
        }
        Catch
        {
            Throw " - An error occurred updating the service account for service SPTraceV4. $($_.Exception.Message)"
        }
        # Restart SPTraceV4 service so changes to group memberships above can take effect
        log " - Restarting service SPTraceV4..."
        Restart-Service -Name "SPTraceV4" -Force
        WriteLine
    }
    else
    {
        log "Timer job `"windows-service-credentials-SPTraceV4`" already exists."
        log "Check that $($spservice.username) is a member of the Performance Log Users and Performance Monitor Users local groups once install completes."
    }
}
#EndRegion

#Region Configure Distributed Cache Service
# ====================================================================================
# Func: ConfigureDistributedCacheService
# Desc: Updates the service account for AppFabricCachingService AKA Distributed Caching Service
# Info: http://technet.microsoft.com/en-us/library/jj219613.aspx
# ====================================================================================

Function ConfigureDistributedCacheService ([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    # Make sure a credential deployment job doesn't already exist, and that we are running SP2013
    if ((!(Get-SPTimerJob -Identity "windows-service-credentials-AppFabricCachingService")) -and ($env:spVer -eq "15"))
    {
        WriteLine
        $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
        $distributedCachingSvc = (Get-SPFarm).Services | where {$_.Name -eq "AppFabricCachingService"}
        # Check if we should disable the Distributed Cache service on the local server
        # Ensure the node exists in the XML first as we don't want to inadvertently disable the service if it wasn't explicitly specified
        $serviceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.DistributedCaching.Utilities.SPDistributedCacheServiceInstance"}
        $serviceInstance = $serviceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
        if (($xmlinput.Configuration.Farm.Services.SelectSingleNode("DistributedCache")) -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.DistributedCache -eq $true))
        {
            log " - Stopping the Distributed Cache service..." 
            if ($serviceInstance.Status -eq "Online")
            {
                Stop-SPDistributedCacheServiceInstance -Graceful
                Remove-SPDistributedCacheServiceInstance
                log "Done."
            }
            else {log "Already stopped."}
        }
        # Otherwise, make sure it's started, and set it to run under a different account
        else
        {
            # Ensure the local Distributed Cache services is actually running
            if ($serviceInstance.Status -ne "Online")
            {
                log " - Starting the Distributed Cache service..." 
                Add-SPDistributedCacheServiceInstance
                log "Done."
            }
            $appPoolAcctDomain,$appPoolAcctUser = $spservice.username -Split "\\"
            log " - Applying service account $($spservice.username) to service AppFabricCachingService..."
            $managedAccountGen = Get-SPManagedAccount | Where-Object {$_.UserName -eq $($spservice.username)}
            Try
            {
                UpdateProcessIdentity $distributedCachingSvc
            }
            Catch
            {
                throw "An error occurred updating the service account for service AppFabricCachingService. $($_.Exception.Message)"
            }
        }
        WriteLine
    }
}
#EndRegion

#Region Provision Enterprise Search
# Original script for SharePoint 2010 beta2 by Gary Lapointe ()
#
# Modified by Søren Laurits Nielsen (soerennielsen.wordpress.com):
#
# Modified to fix some errors since some cmdlets have changed a bit since beta 2 and added support for "ShareName" for
# the query component. It is required for non DC computers.
#
# Modified to support "localhost" moniker in config file.
#
# Note: Accounts, Shares and directories specified in the config file must be setup beforehand.

function CreateEnterpriseSearchServiceApp([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    $searchServiceAccount = Get-SPManagedAccountXML $xmlinput -CommonName "SearchService"
    # Check if the Search Service account username has been specified before we try to convert its password to a secure string
    if (!([string]::IsNullOrEmpty($searchServiceAccount.Username)))
    {
        $secSearchServicePassword = ConvertTo-SecureString -String $searchServiceAccount.Password -AsPlainText -Force
    }
    else
    {
        log " - Managed account credentials for Search Service have not been specified."
    }
    # We now do a check that both Search is being requested for provisioning and that we are not running the Foundation SKU
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.EnterpriseSearchService -eq $true) -and (Get-Command -Name New-SPEnterpriseSearchServiceApplication -ErrorAction SilentlyContinue) -and ($xmlinput.Configuration.Install.SKU -ne "Foundation"))
    {
        WriteLine
        log " - Provisioning Enterprise Search..."
        # SLN: Added support for local host
        $svcConfig = $xmlinput.Configuration.ServiceApps.EnterpriseSearchService
        $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
        $portalURL = $portalWebApp.URL
        $portalPort = $portalWebApp.Port
        if ($xmlinput.Configuration.ServiceApps.UserProfileServiceApp.Provision -ne $false) # We didn't use ShouldIProvision here as we want to know if UPS is being provisioned in this farm, not just on this server
        {
            $mySiteWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "MySiteHost"}
            # If we have asked to create a MySite Host web app, use that as the MySite host location
            if ($mySiteWebApp)
            {
                $mySiteURL = $mySiteWebApp.URL
                $mySitePort = $mySiteWebApp.Port
                $mySiteHostLocation = $mySiteURL+":"+$mySitePort
            }
            else # Use the value provided in the $userProfile node
            {
                $mySiteHostLocation = $xmlinput.Configuration.ServiceApps.UserProfileServiceApp.MySiteHostLocation
            }
            # Strip out any protocol values
            $mySiteHostHeaderAndPort,$null = $mySiteHostLocation -replace "http://","" -replace "https://","" -split "/"
        }

        $dataDir = $xmlinput.Configuration.Install.DataDir
        $dataDir = $dataDir.TrimEnd("\")
        # Set it to the default value if it's not specified in $xmlinput
        if ([string]::IsNullOrEmpty($dataDir)) {$dataDir = "$env:ProgramFiles\Microsoft Office Servers\$env:spVer.0\Data"}

        $searchSvc = Get-SPEnterpriseSearchServiceInstance -Local
        If ($searchSvc -eq $null) {
            Throw "  - Unable to retrieve search service."
        }
        if ([string]::IsNullOrEmpty($svcConfig.CustomIndexLocation))
        {
            # Use the default location
            $indexLocation = "$dataDir\Office Server\Applications"
        }
        else
        {
            $indexLocation = $svcConfig.CustomIndexLocation
            $indexLocation = $indexLocation.TrimEnd("\")
            # If the requested index location is not the default, make sure the new location exists so we can use it later in the script
            if ($indexLocation -ne "$dataDir\Office Server\Applications")
            {
                log " - Checking requested IndexLocation path..."
                EnsureFolder $svcConfig.CustomIndexLocation
            }
        }
        log "  - Configuring search service..." 
        Get-SPEnterpriseSearchService | Set-SPEnterpriseSearchService  `
          -ContactEmail $svcConfig.ContactEmail -ConnectionTimeout $svcConfig.ConnectionTimeout `
          -AcknowledgementTimeout $svcConfig.AcknowledgementTimeout -ProxyType $svcConfig.ProxyType `
          -IgnoreSSLWarnings $svcConfig.IgnoreSSLWarnings -InternetIdentity $svcConfig.InternetIdentity -PerformanceLevel $svcConfig.PerformanceLevel `
          -ServiceAccount $searchServiceAccount.Username -ServicePassword $secSearchServicePassword
        If ($?) {log "Done."}


        If ($env:spVer -eq "14") # SharePoint 2010 steps
        {
            $svcConfig.EnterpriseSearchServiceApplications.EnterpriseSearchServiceApplication | ForEach-Object {
                $appConfig = $_
                $dbPrefix = Get-DBPrefix $xmlinput
                If (!([string]::IsNullOrEmpty($appConfig.Database.DBServer)))
                {
                    $dbServer = $appConfig.Database.DBServer
                }
                Else
                {
                    $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
                }
                $secContentAccessAcctPWD = ConvertTo-SecureString -String $appConfig.ContentAccessAccountPassword -AsPlainText -Force
                # Try and get the application pool if it already exists
                $pool = Get-ApplicationPool $appConfig.ApplicationPool
                $adminPool = Get-ApplicationPool $appConfig.AdminComponent.ApplicationPool
                $searchApp = Get-SPEnterpriseSearchServiceApplication -Identity $appConfig.Name -ErrorAction SilentlyContinue
                If ($searchApp -eq $null)
                {
                    log " - Creating $($appConfig.Name)..."
                    $searchApp = New-SPEnterpriseSearchServiceApplication -Name $appConfig.Name `
                        -DatabaseServer $dbServer `
                        -DatabaseName $($dbPrefix+$appConfig.Database.Name) `
                        -FailoverDatabaseServer $appConfig.FailoverDatabaseServer `
                        -ApplicationPool $pool `
                        -AdminApplicationPool $adminPool `
                        -Partitioned:([bool]::Parse($appConfig.Partitioned)) `
                        -SearchApplicationType $appConfig.SearchServiceApplicationType
                }
                Else
                {
                    log " - Enterprise search service application already exists, skipping creation."
                }

                # Add link to resources list
                AddResourcesLink "Search Administration" ("searchadministration.aspx?appid=" +  $searchApp.Id)

                # If the index location isn't already set to either the default location or our custom-specified location, set the default location for the search service instance
                if ($indexLocation -ne "$dataDir\Office Server\Applications" -or $indexLocation -ne $searchSvc.DefaultIndexLocation)
                {
                    log "  - Setting default index location on search service instance..." 
                    $searchSvc | Set-SPEnterpriseSearchServiceInstance -DefaultIndexLocation $indexLocation -ErrorAction SilentlyContinue
                    if ($?) {log "OK."}
                }

                # Finally using ShouldIProvision here like everywhere else in the script...
                $installCrawlSvc = ShouldIProvision $appConfig.CrawlComponent
                $installQuerySvc = ShouldIProvision $appConfig.QueryComponent
                $installAdminComponent = ShouldIProvision $appConfig.AdminComponent
                $installSyncSvc = ShouldIProvision $appConfig.SearchQueryAndSiteSettingsComponent

                If ($searchSvc.Status -ne "Online" -and ($installCrawlSvc -or $installQuerySvc)) {
                    $searchSvc | Start-SPEnterpriseSearchServiceInstance
                }

                If ($installAdminComponent) {
                    log " - Setting administration component..."
                    Set-SPEnterpriseSearchAdministrationComponent -SearchApplication $searchApp -SearchServiceInstance $searchSvc

                    $adminCmpnt = $searchApp | Get-SPEnterpriseSearchAdministrationComponent
                    If ($adminCmpnt.Initialized -eq $false)
                    {
                        log " - Waiting for administration component initialization..." 
                        While ($adminCmpnt.Initialized -ne $true)
                        {
                            log "." 
                            Start-Sleep 1
                            $adminCmpnt = $searchApp | Get-SPEnterpriseSearchAdministrationComponent
                        }
                        log $($adminCmpnt.Initialized -replace "True","Done.")
                    }
                    Else {log " - Administration component already initialized."}
                }
                # Update the default Content Access Account
                Update-SearchContentAccessAccount $($appconfig.Name) $searchApp $($appConfig.ContentAccessAccount) $secContentAccessAcctPWD


                $crawlTopology = Get-SPEnterpriseSearchCrawlTopology -SearchApplication $searchApp | where {$_.CrawlComponents.Count -gt 0 -or $_.State -eq "Inactive"}

                If ($crawlTopology -eq $null) {
                    log " - Creating new crawl topology..."
                    $crawlTopology = $searchApp | New-SPEnterpriseSearchCrawlTopology
                } Else {
                    log " - A crawl topology with crawl components already exists, skipping crawl topology creation."
                }

                If ($installCrawlSvc) {
                    $crawlComponent = $crawlTopology.CrawlComponents | where {MatchComputerName $_.ServerName $env:COMPUTERNAME}
                    If ($crawlTopology.CrawlComponents.Count -eq 0 -or $crawlComponent -eq $null) {
                        $crawlStore = $searchApp.CrawlStores | where {$_.Name -eq "$($dbPrefix+$appConfig.Database.Name)_CrawlStore"}
                        log " - Creating new crawl component..."
                        $crawlComponent = New-SPEnterpriseSearchCrawlComponent -SearchServiceInstance $searchSvc -SearchApplication $searchApp -CrawlTopology $crawlTopology -CrawlDatabase $crawlStore.Id.ToString() -IndexLocation $indexLocation
                    } Else {
                        log " - Crawl component already exist, skipping crawl component creation."
                    }
                }

                $queryTopologies = Get-SPEnterpriseSearchQueryTopology -SearchApplication $searchApp | where {$_.QueryComponents.Count -gt 0 -or $_.State -eq "Inactive"}
                If ($queryTopologies.Count -lt 1) {
                    log " - Creating new query topology..."
                    $queryTopology = $searchApp | New-SPEnterpriseSearchQueryTopology -Partitions $appConfig.Partitions
                } Else {
                    log " - A query topology already exists, skipping query topology creation."
                    If ($queryTopologies.Count -gt 1)
                    {
                        # Try to select the query topology that has components
                        $queryTopology = $queryTopologies | Where-Object {$_.QueryComponents.Count -gt 0} | Select-Object -First 1
                        if (!$queryTopology)
                        {
                            # Just select the first query topology since none appear to have query components
                            $queryTopology = $queryTopologies | Select-Object -First 1
                        }
                    }
                    Else
                    {
                        # Just set it to $queryTopologies since there is only one
                        $queryTopology = $queryTopologies
                    }
                }

                If ($installQuerySvc) {
                    $queryComponent = $queryTopology.QueryComponents | where {MatchComputerName $_.ServerName $env:COMPUTERNAME}
                    If ($queryComponent -eq $null) {
                        $partition = ($queryTopology | Get-SPEnterpriseSearchIndexPartition)
                        log " - Creating new query component..."
                        $queryComponent = New-SPEnterpriseSearchQueryComponent -IndexPartition $partition -QueryTopology $queryTopology -SearchServiceInstance $searchSvc -ShareName $svcConfig.ShareName -IndexLocation $indexLocation
                        log " - Setting index partition and property store database..."
                        $propertyStore = $searchApp.PropertyStores | where {$_.Name -eq "$($dbPrefix+$appConfig.Database.Name)_PropertyStore"}
                        $partition | Set-SPEnterpriseSearchIndexPartition -PropertyDatabase $propertyStore.Id.ToString()
                    } Else {
                        log " - Query component already exists, skipping query component creation."
                    }
                }

                If ($installSyncSvc) {
                    # SLN: Updated to new syntax
                    $searchQueryAndSiteSettingsServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Search.Administration.SearchQueryAndSiteSettingsServiceInstance"}
                    $searchQueryAndSiteSettingsService = $searchQueryAndSiteSettingsServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                    If (-not $?) { Throw " - Failed to find Search Query and Site Settings service instance" }
                    # Start Service instance
                    log " - Starting Search Query and Site Settings Service Instance..."
                    If ($searchQueryAndSiteSettingsService.Status -eq "Disabled")
                    {
                        $searchQueryAndSiteSettingsService.Provision()
                        If (-not $?) { Throw " - Failed to start Search Query and Site Settings service instance" }
                        # Wait
                        log " - Waiting for Search Query and Site Settings service..." 
                        While ($searchQueryAndSiteSettingsService.Status -ne "Online")
                        {
                            log "." 
                            Start-Sleep 1
                            $searchQueryAndSiteSettingsServices = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Server.Search.Administration.SearchQueryAndSiteSettingsServiceInstance"}
                            $searchQueryAndSiteSettingsService = $searchQueryAndSiteSettingsServices | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                        }
                        log $($searchQueryAndSiteSettingsService.Status)
                    }
                    Else {log " - Search Query and Site Settings Service already started."}
                    }

                # Don't activate until we've added all components
                $allCrawlServersDone = $true
                # Put any comma- or space-delimited servers we find in the "Provision" attribute into an array
                [array]$crawlServersToProvision = $appConfig.CrawlComponent.Provision -split "," -split " "
                $crawlServersToProvision | ForEach-Object {
                    $crawlServer = $_
                    $top = $crawlTopology.CrawlComponents | where {$_.ServerName -eq $crawlServer}
                    If ($top -eq $null) { $allCrawlServersDone = $false }
                }

                If ($allCrawlServersDone -and $crawlTopology.State -ne "Active") {
                    log " - Setting new crawl topology to active..."
                    $crawlTopology | Set-SPEnterpriseSearchCrawlTopology -Active -Confirm:$false
                    log " - Waiting for Crawl Components..." 
                    while ($true)
                    {
                        $ct = Get-SPEnterpriseSearchCrawlTopology -Identity $crawlTopology -SearchApplication $searchApp
                        $state = $ct.CrawlComponents | where {$_.State -ne "Ready"}
                        If ($ct.State -eq "Active" -and $state -eq $null)
                        {
                            break
                        }
                        log "." 
                        Start-Sleep 1
                    }
                    log $($crawlTopology.State)

                    # Need to delete the original crawl topology that was created by default
                    $searchApp | Get-SPEnterpriseSearchCrawlTopology | where {$_.State -eq "Inactive"} | Remove-SPEnterpriseSearchCrawlTopology -Confirm:$false
                }

                $allQueryServersDone = $true
                # Put any comma- or space-delimited servers we find in the "Provision" attribute into an array
                [array]$queryServersToProvision = $appConfig.QueryComponent.Provision -split "," -split " "
                $queryServersToProvision | ForEach-Object {
                    $queryServer = $_
                    $top = $queryTopology.QueryComponents | where {$_.ServerName -eq $queryServer}
                    If ($top -eq $null) { $allQueryServersDone = $false }
                }

                # Make sure we have a crawl component added and started before trying to enable the query component
                If ($allCrawlServersDone -and $allQueryServersDone -and $queryTopology.State -ne "Active") {
                    log " - Setting query topology as active..."
                    $queryTopology | Set-SPEnterpriseSearchQueryTopology -Active -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable err
                    log " - Waiting for Query Components..." 
                    while ($true)
                    {
                        $qt = Get-SPEnterpriseSearchQueryTopology -Identity $queryTopology -SearchApplication $searchApp
                        $state = $qt.QueryComponents | where {$_.State -ne "Ready"}
                        If ($qt.State -eq "Active" -and $state -eq $null)
                        {
                            break
                        }
                        log "." 
                        Start-Sleep 1
                    }
                    log $($queryTopology.State)

                    # Need to delete the original query topology that was created by default
                    $origQueryTopology = $searchApp | Get-SPEnterpriseSearchQueryTopology | where {$_.QueryComponents.Count -eq 0}
                    If ($origQueryTopology.State -eq "Inactive")
                    {
                        log " - Removing original (default) query topology..."
                        $origQueryTopology | Remove-SPEnterpriseSearchQueryTopology -Confirm:$false
                    }
                }

                $proxy = Get-SPEnterpriseSearchServiceApplicationProxy -Identity $appConfig.Proxy.Name -ErrorAction SilentlyContinue
                If ($proxy -eq $null) {
                    log " - Creating enterprise search service application proxy..."
                    $proxy = New-SPEnterpriseSearchServiceApplicationProxy -Name $appConfig.Proxy.Name -SearchApplication $searchApp -Partitioned:([bool]::Parse($appConfig.Proxy.Partitioned))
                } Else {
                    log " - Enterprise search service application proxy already exists, skipping creation."
                }
                If ($proxy.Status -ne "Online") {
                    $proxy.Status = "Online"
                    $proxy.Update()
                }
                $proxy | Set-ProxyGroupsMembership $appConfig.Proxy.ProxyGroup
            }
            WriteLine
        }
        ElseIf ($env:spVer -eq "15") # SharePoint 2013 steps
        {
            $svcConfig.EnterpriseSearchServiceApplications.EnterpriseSearchServiceApplication | ForEach-Object {
                $appConfig = $_
                $dbPrefix = Get-DBPrefix $xmlinput
                If (!([string]::IsNullOrEmpty($appConfig.Database.DBServer)))
                {
                    $dbServer = $appConfig.Database.DBServer
                }
                Else
                {
                    $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
                }
                $secContentAccessAcctPWD = ConvertTo-SecureString -String $appConfig.ContentAccessAccountPassword -AsPlainText -Force

                # Finally using ShouldIProvision here like everywhere else in the script...
                $installCrawlComponent = ShouldIProvision $appConfig.CrawlComponent
                $installQueryComponent = ShouldIProvision $appConfig.QueryComponent
                $installAdminComponent = ShouldIProvision $appConfig.AdminComponent
                $installSyncSvc = ShouldIProvision $appConfig.SearchQueryAndSiteSettingsComponent
                $installAnalyticsProcessingComponent = ShouldIProvision $appConfig.AnalyticsProcessingComponent
                $installContentProcessingComponent = ShouldIProvision $appConfig.ContentProcessingComponent
                $installIndexComponent = ShouldIProvision $appConfig.IndexComponent
                
                $pool = Get-ApplicationPool $appConfig.ApplicationPool
                $adminPool = Get-ApplicationPool $appConfig.AdminComponent.ApplicationPool
                $appPoolUserName = $searchServiceAccount.Username

                $saAppPool = Get-SPServiceApplicationPool -Identity $pool -ErrorAction SilentlyContinue
                if($saAppPool -eq $null)
                {
                    log "  - Creating Service Application Pool..."

                    $appPoolAccount = Get-SPManagedAccount -Identity $appPoolUserName -ErrorAction SilentlyContinue
                    if($appPoolAccount -eq $null)
                    {
                        log "  - Please supply the password for the Service Account..."
                        $appPoolCred = Get-Credential $appPoolUserName
                        $appPoolAccount = New-SPManagedAccount -Credential $appPoolCred -ErrorAction SilentlyContinue
                    }

                    $appPoolAccount = Get-SPManagedAccount -Identity $appPoolUserName -ErrorAction SilentlyContinue

                    if($appPoolAccount -eq $null)
                    {
                        Throw "  - Cannot create or find the managed account $appPoolUserName, please ensure the account exists."
                    }

                    New-SPServiceApplicationPool -Name $pool -Account $appPoolAccount -ErrorAction SilentlyContinue | Out-Null
                }

                # From http://mmman.itgroove.net/2012/12/search-host-controller-service-in-starting-state-sharepoint-2013-8/
                # And http://blog.thewulph.com/?p=374
                log "  - Fixing registry permissions for Search Host Controller Service..." 
                $acl = Get-Acl HKLM:\System\CurrentControlSet\Control\ComputerName
                $person = [System.Security.Principal.NTAccount] "WSS_WPG" # Trimmed down from the original "Users"
                $access = [System.Security.AccessControl.RegistryRights]::FullControl
                $inheritance = [System.Security.AccessControl.InheritanceFlags] "ContainerInherit, ObjectInherit"
                $propagation = [System.Security.AccessControl.PropagationFlags]::None
                $type = [System.Security.AccessControl.AccessControlType]::Allow
                $rule = New-Object System.Security.AccessControl.RegistryAccessRule($person, $access, $inheritance, $propagation, $type)
                $acl.AddAccessRule($rule)
                Set-Acl HKLM:\System\CurrentControlSet\Control\ComputerName $acl
                log "OK."

                log "  - Checking Search Service Instance..." 
                If ($searchSvc.Status -eq "Disabled")
                {
                    log "Starting..." 
                    $searchSvc | Start-SPEnterpriseSearchServiceInstance
                    If (!$?) {Throw "  - Could not start the Search Service Instance."}
                    # Wait
                    $searchSvc = Get-SPEnterpriseSearchServiceInstance -Local
                    While ($searchSvc.Status -ne "Online")
                    {
                        log "." 
                        Start-Sleep 1
                        $searchSvc = Get-SPEnterpriseSearchServiceInstance -Local
                    }
                    log $($searchSvc.Status)
                }
                Else {log "Already $($searchSvc.Status)."}

                if ($installSyncSvc)
                {
                    log "  - Checking Search Query and Site Settings Service Instance..." 
                    $searchQueryAndSiteSettingsService = Get-SPEnterpriseSearchQueryAndSiteSettingsServiceInstance -Local
                    If ($searchQueryAndSiteSettingsService.Status -eq "Disabled")
                    {
                        log "Starting..." 
                        $searchQueryAndSiteSettingsService | Start-SPEnterpriseSearchQueryAndSiteSettingsServiceInstance
                        If (!$?) {Throw "  - Could not start the Search Query and Site Settings Service Instance."}
                        log $($searchQueryAndSiteSettingsService.Status)
                    }
                    Else {log "Already $($searchQueryAndSiteSettingsService.Status)."}
                }

                log "  - Checking Search Service Application..." 
                $searchApp = Get-SPEnterpriseSearchServiceApplication -Identity $appConfig.Name -ErrorAction SilentlyContinue
                If ($searchApp -eq $null)
                {
                    log "Creating $($appConfig.Name)..." 
                    $searchApp = New-SPEnterpriseSearchServiceApplication -Name $appConfig.Name `
                        -DatabaseServer $dbServer `
                        -DatabaseName $($dbPrefix+$appConfig.Database.Name) `
                        -FailoverDatabaseServer $appConfig.FailoverDatabaseServer `
                        -ApplicationPool $pool `
                        -AdminApplicationPool $adminPool `
                        -Partitioned:([bool]::Parse($appConfig.Partitioned))
                    If (!$?) {Throw "  - An error occurred creating the $($appConfig.Name) application."}
                    log "Done."
                }
                Else {log "Already exists."}

                # Update the default Content Access Account
                Update-SearchContentAccessAccount $($appConfig.Name) $searchApp $($appConfig.ContentAccessAccount) $secContentAccessAcctPWD

                # If the index location isn't already set to either the default location or our custom-specified location, set the default location for the search service instance
                if ($indexLocation -ne "$dataDir\Office Server\Applications" -or $indexLocation -ne $searchSvc.DefaultIndexLocation)
                {
                    log "  - Setting default index location on search service instance..." 
                    $searchSvc | Set-SPEnterpriseSearchServiceInstance -DefaultIndexLocation $indexLocation -ErrorAction SilentlyContinue
                    if ($?) {log "OK."}
                }

                # Look for a topology that has components, or is still Inactive, because that's probably our $clone
                $clone = $searchApp.Topologies | Where {$_.ComponentCount -gt 0 -and $_.State -eq "Inactive"} | Select-Object -First 1
                if (!$clone)
                {
                    # Clone the active topology
                    log "  - Cloning the active search topology..." 
                    $clone = $searchApp.ActiveTopology.Clone()
                    log "OK."
                }
                else
                {
                    log "  - Using existing cloned search topology."
                    # Since this clone probably doesn't have all its components added yet, we probably want to keep it if it isn't activated after this pass
                    $keepClone = $true
                }
                $activateTopology = $false
                # Check if each search component is already assigned to the current server, then check that it's actually being requested for the current server, then create it as required.
                log "  - Checking admin component..." 
                $adminComponents = $clone.GetComponents() | Where-Object {$_.Name -like "AdminComponent*"}
                If ($installAdminComponent)
                {
                    if (!($adminComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        log "Creating..." 
                        New-SPEnterpriseSearchAdminComponent –SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            log "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {log "Already exists on this server."}
                    $adminComponentReady = $true
                }
                else {log "Not requested for this server."}
                if ($adminComponents) {log "  - Admin component(s) already exist(s) in the farm."; $adminComponentReady = $true}

                log "  - Checking content processing component..." 
                $contentProcessingComponents = $clone.GetComponents() | Where-Object {$_.Name -like "ContentProcessingComponent*"}
                if ($installContentProcessingComponent)
                {
                    if (!($contentProcessingComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        log "Creating..." 
                        New-SPEnterpriseSearchContentProcessingComponent –SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            log "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {log "Already exists on this server."}
                    $contentProcessingComponentReady = $true
                }
                else {log "Not requested for this server."}
                if ($contentProcessingComponents) {log "  - Content processing component(s) already exist(s) in the farm."; $contentProcessingComponentReady = $true}

                log "  - Checking analytics processing component..." 
                $analyticsProcessingComponents = $clone.GetComponents() | Where-Object {$_.Name -like "AnalyticsProcessingComponent*"}
                if ($installAnalyticsProcessingComponent)
                {
                    if (!($analyticsProcessingComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        log "Creating..." 
                        New-SPEnterpriseSearchAnalyticsProcessingComponent –SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            log "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {log "Already exists on this server."}
                    $analyticsProcessingComponentReady = $true
                }
                else {log "Not requested for this server."}
                if ($analyticsProcessingComponents) {log "  - Analytics processing component(s) already exist(s) in the farm."; $analyticsProcessingComponentReady = $true}

                log "  - Checking crawl component..." 
                $crawlComponents = $clone.GetComponents() | Where-Object {$_.Name -like "CrawlComponent*"}
                if ($installCrawlComponent)
                {
                    if (!($crawlComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        log "Creating..." 
                        New-SPEnterpriseSearchCrawlComponent –SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            log "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {log "Already exists on this server."}
                    $crawlComponentReady = $true
                }
                else {log "Not requested for this server."}
                if ($crawlComponents) {log "  - Crawl component(s) already exist(s) in the farm."; $crawlComponentReady = $true}

                log "  - Checking index component..." 
                $indexingComponents = $clone.GetComponents() | Where-Object {$_.Name -like "IndexComponent*"}
                if ($installIndexComponent)
                {
                    if (!($indexingComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        log "Creating..." 
                        # Specify the RootDirectory parameter only if it's different than the default path
                        if ($indexLocation -ne "$dataDir\Office Server\Applications")
                        {$rootDirectorySwitch = @{RootDirectory = $indexLocation}}
                        else {$rootDirectorySwitch = @{}}
                        New-SPEnterpriseSearchIndexComponent –SearchTopology $clone -SearchServiceInstance $searchSvc @rootDirectorySwitch | Out-Null
                        If ($?)
                        {
                            log "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {log "Already exists on this server."}
                    $indexComponentReady = $true
                }
                else {log "Not requested for this server."}
                if ($indexingComponents) {log "  - Index component(s) already exist(s) in the farm."; $indexComponentReady = $true}

                log "  - Checking query processing component..." 
                $queryComponents = $clone.GetComponents() | Where-Object {$_.Name -like "QueryProcessingComponent*"}
                if ($installQueryComponent)
                {
                    if (!($queryComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        log "Creating..." 
                        New-SPEnterpriseSearchQueryProcessingComponent –SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            log "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {log "Already exists on this server."}
                    $queryComponentReady = $true
                }
                else {log "Not requested for this server."}
                if ($queryComponents) {log "  - Query component(s) already exist(s) in the farm."; $queryComponentReady = $true}

                $searchApp | Get-SPEnterpriseSearchAdministrationComponent | Set-SPEnterpriseSearchAdministrationComponent -SearchServiceInstance $searchSvc

                if ($adminComponentReady -and $contentProcessingComponentReady -and $analyticsProcessingComponentReady -and $indexComponentReady -and $crawlComponentReady -and $queryComponentReady) {$activateTopology = $true}
                # Check if any new search components were added (or if we have a clone with more components than the current active topology) and if we're ready to activate the topology
                if ($newComponentsCreated -or ($clone.ComponentCount -gt $searchApp.ActiveTopology.ComponentCount))
                {
                    if ($activateTopology)
                    {
                        log "  - Activating Search Topology..." 
                        $clone.Activate()
                        If ($?)
                        {
                            log "OK."
                            # Clean up original or previous unsuccessfully-provisioned search topologies
                            $inactiveTopologies = $searchApp.Topologies | Where {$_.State -eq "Inactive"}
                            if ($inactiveTopologies -ne $null)
                            {
                                log "  - Removing old, inactive search topologies:"
                                foreach ($inactiveTopology in $inactiveTopologies)
                                {
                                    log "   -"$inactiveTopology.TopologyId.ToString()
                                    $inactiveTopology.Delete()
                                }
                            }
                        }
                    }
                    else
                    {
                        log "  - Not activating topology yet as there seem to be components still pending."
                    }
                }
                elseif ($keepClone -ne $true) # Delete the newly-cloned topology since nothing was done
                # TODO: Check that the search topology is truly complete and there are no more servers to install
                {
                    log "  - Deleting unneeded cloned topology..."
                    $clone.Delete()
                }
                # Clean up any empty, inactive topologies
                $emptyTopologies = $searchApp.Topologies | Where {$_.ComponentCount -eq 0 -and $_.State -eq "Inactive"}
                if ($emptyTopologies -ne $null)
                {
                    log "  - Removing empty and inactive search topologies:"
                    foreach ($emptyTopology in $emptyTopologies)
                    {
                        log "  -"$emptyTopology.TopologyId.ToString()
                        $emptyTopology.Delete()
                    }
                }
                log "  - Checking search service application proxy..." 
                If (!(Get-SPEnterpriseSearchServiceApplicationProxy -Identity $appConfig.Proxy.Name -ErrorAction SilentlyContinue))
                {
                    log "Creating..." 
                    $searchAppProxy = New-SPEnterpriseSearchServiceApplicationProxy -Name $appConfig.Proxy.Name -SearchApplication $appConfig.Name
                    If ($?) {log "OK."}
                }
                Else {log "Already exists."}

                # Check the Search Host Controller Service for a known issue ("stuck on starting")
                log "  - Checking for stuck Search Host Controller Service (known issue)..."
                $searchHostServices = Get-SPServiceInstance | ? {$_.TypeName -eq "Search Host Controller Service"}
                foreach ($sh in $searchHostServices)
                {
                    log "   - Server: $($sh.Parent.Address)..." 
                    if ($sh.Status -eq "Provisioning")
                    {
                        log "Re-provisioning..." 
                        $sh.Unprovision()
                        $sh.Provision($true)
                        log "Done."
                    }
                    else {log "OK."}
                }

                # Add link to resources list
                AddResourcesLink $appConfig.Name ("searchadministration.aspx?appid=" +  $searchApp.Id)

                function SetSearchCenterUrl ($searchCenterURL, $searchApp)
                {
                    Start-Sleep 10 # Wait for stuff to catch up so we don't get a concurrency error
                    $searchApp.SearchCenterUrl = $searchCenterURL
                    $searchApp.Update()
                }

                If (!([string]::IsNullOrEmpty($appConfig.SearchCenterUrl)))
                {
                    # Set the SP2013 Search Center URL per http://blogs.technet.com/b/speschka/archive/2012/10/29/how-to-configure-the-global-search-center-url-for-sharepoint-2013-using-powershell.aspx
                    log "  - Setting the Global Search Center URL to $($appConfig.SearchCenterURL)..." 
                    while ($done -ne $true)
                    {
                        try
                        {
                            # Get the #searchApp object again to prevent conflicts
                            $searchApp = Get-SPEnterpriseSearchServiceApplication -Identity $appConfig.Name
                            SetSearchCenterUrl $appConfig.SearchCenterURL.TrimEnd("/") $searchApp
                            if ($?)
                            {
                                $done = $true
                                log "OK."
                            }
                        }
                        catch
                        {
                            log $_
                            if ($_ -like "*update conflict*")
                            {
                                log "  - An update conflict occurred, retrying..."
                            }
                            else {log $_; $done = $true}
                        }
                    }
                }
                Else {log "  - SearchCenterUrl was not specified, skipping."}
                log " - Search Service Application successfully provisioned."

                WriteLine
            }
        }

        # SLN: Create the network share (will report an error if exist)
        # default to primitives
        $pathToShare = """" + $svcConfig.ShareName + "=" + $indexLocation + """"
        # The path to be shared should exist if the Enterprise Search App creation succeeded earlier
        EnsureFolder $indexLocation
        log " - Creating network share $pathToShare"
        Start-Process -FilePath net.exe -ArgumentList "share $pathToShare `"/GRANT:WSS_WPG,CHANGE`"" -NoNewWindow -Wait -ErrorAction SilentlyContinue

        # Set the crawl start addresses (including the elusive sps3:// URL required for People Search, if My Sites are provisioned)
        # Updated to include all web apps and host-named site collections, not just main Portal and MySites host
        ForEach ($webAppConfig in $xmlinput.Configuration.WebApplications.WebApplication)
        {
            if ([string]::IsNullOrEmpty($crawlStartAddresses))
            {
                $crawlStartAddresses = $($webAppConfig.url)+":"+$($webAppConfig.Port)
            }
            else
            {
                $crawlStartAddresses += ","+$($webAppConfig.url)+":"+$($webAppConfig.Port)
            }
        }

        If ($mySiteHostHeaderAndPort)
        {
        	# Need to set the correct sps (People Search) URL protocol in case the web app that hosts My Sites is SSL-bound
        	If ($mySiteHostLocation -like "https*") {$peopleSearchProtocol = "sps3s://"}
        	Else {$peopleSearchProtocol = "sps3://"}
        	$crawlStartAddresses += ","+$peopleSearchProtocol+$mySiteHostHeaderAndPort
        }
        log " - Setting up crawl addresses for default content source..." 
        Get-SPEnterpriseSearchServiceApplication | Get-SPEnterpriseSearchCrawlContentSource | Set-SPEnterpriseSearchCrawlContentSource -StartAddresses $crawlStartAddresses
        If ($?) {log "OK."}
        if ($env:spVer -eq "15") # Invoke-WebRequest requires PowerShell 3.0 but if we're installing SP2013 and we've gotten this far, we must have v3.0
        {
            # Issue a request to the Farm Search Administration page to avoid a Health Analyzer warning about 'Missing Server Side Dependencies'
            $ca = Get-SPWebApplication -IncludeCentralAdministration | ? {$_.IsAdministrationWebApplication}
            $centralAdminUrl = $ca.Url
            if ($ca.Url -like "http://*" -or $ca.Url -like "*$($env:COMPUTERNAME)*") # If Central Admin uses SSL, only attempt the web request if we're on the same server as Central Admin, otherwise it may throw a certificate error due to our self-signed cert
            {
                try
                {
                    log " - Requesting searchfarmdashboard.aspx (resolves Health Analyzer error)..."
                    $null = Invoke-WebRequest -Uri $centralAdminUrl"searchfarmdashboard.aspx" -UseDefaultCredentials -DisableKeepAlive -UseBasicParsing -ErrorAction SilentlyContinue
                }
                catch {}
            }
        }
        WriteLine
    }
    Else
    {
        WriteLine
        # Set the service account to something other than Local System to avoid Health Analyzer warnings
        If (!([string]::IsNullOrEmpty($searchServiceAccount.Username)) -and !([string]::IsNullOrEmpty($secSearchServicePassword)))
        {
            # Use the values for Search Service account and password, if they've been defined
            $username = $searchServiceAccount.Username
            $password = $secSearchServicePassword
        }
        Else
        {
            $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
            $username = $spservice.username
            $password = ConvertTo-SecureString "$($spservice.password)" -AsPlaintext -Force
        }
        log " - Applying service account $username to Search Service..."
        Get-SPEnterpriseSearchService | Set-SPEnterpriseSearchService -ServiceAccount $username -ServicePassword $password
        If (!$?) {log " - An error occurred setting the Search Service account!"}
        WriteLine
    }
}

function Update-SearchContentAccessAccount ($saName, $sa, $caa, $caapwd)
{
    try
    {
        log "  - Setting content access account for $saName..."
        $sa | Set-SPEnterpriseSearchServiceApplication -DefaultContentAccessAccountName $caa -DefaultContentAccessAccountPassword $caapwd -ErrorVariable err
    }
    catch
    {
        if ($err -like "*update conflict*")
        {
            log "An update conflict error occured, trying again."
            Update-SearchContentAccessAccount $saName, $sa, $caa, $caapwd
            $sa | Set-SPEnterpriseSearchServiceApplication -DefaultContentAccessAccountName $caa -DefaultContentAccessAccountPassword $caapwd -ErrorVariable err
        }
        else
        {
            throw $_
        }
    }
    finally {Clear-Variable err}
}

function Set-ProxyGroupsMembership([System.Xml.XmlElement[]]$groups, [Microsoft.SharePoint.Administration.SPServiceApplicationProxy[]]$inputObject)
{
    begin {}
    process {
        $proxy = $_

        # Clear any existing proxy group assignments
        Get-SPServiceApplicationProxyGroup | where {$_.Proxies -contains $proxy} | ForEach-Object {
            $proxyGroupName = $_.Name
            If ([string]::IsNullOrEmpty($proxyGroupName)) { $proxyGroupName = "Default" }
            $group = $null
            [bool]$matchFound = $false
            ForEach ($g in $groups) {
                $group = $g.Name
                If ($group -eq $proxyGroupName) {
                    $matchFound = $true
                    break
                }
            }
            If (!$matchFound) {
                log " - Removing ""$($proxy.DisplayName)"" from ""$proxyGroupName"""
                $_ | Remove-SPServiceApplicationProxyGroupMember -Member $proxy -Confirm:$false -ErrorAction SilentlyContinue
            }
        }

        ForEach ($g in $groups) {
            $group = $g.Name

            $pg = $null
            If ($group -eq "Default" -or [string]::IsNullOrEmpty($group)) {
                $pg = [Microsoft.SharePoint.Administration.SPServiceApplicationProxyGroup]::Default
            } Else {
                $pg = Get-SPServiceApplicationProxyGroup $group -ErrorAction SilentlyContinue -ErrorVariable err
                If ($pg -eq $null) {
                    $pg = New-SPServiceApplicationProxyGroup -Name $name
                }
            }

            $pg = $pg | where {$_.Proxies -notcontains $proxy}
            If ($pg -ne $null) {
                log " - Adding ""$($proxy.DisplayName)"" to ""$($pg.DisplayName)"""
                $pg | Add-SPServiceApplicationProxyGroupMember -Member $proxy
            }
        }
    }
    end {}
}

Function Get-ApplicationPool([System.Xml.XmlElement]$appPoolConfig) {
    # Try and get the application pool if it already exists
    # SLN: Updated names
    $pool = Get-SPServiceApplicationPool -Identity $appPoolConfig.Name -ErrorVariable err -ErrorAction SilentlyContinue
    If ($err) {
        # The application pool does not exist so create.
        log "  - Getting $($searchServiceAccount.Username) account for application pool..."
        $managedAccountSearch = (Get-SPManagedAccount -Identity $searchServiceAccount.Username -ErrorVariable err -ErrorAction SilentlyContinue)
        If ($err) {
            If (!([string]::IsNullOrEmpty($searchServiceAccount.Password)))
            {
                $appPoolConfigPWD = (ConvertTo-SecureString $searchServiceAccount.Password -AsPlainText -force)
                $accountCred = New-Object System.Management.Automation.PsCredential $searchServiceAccount.Username,$appPoolConfigPWD
            }
            Else
            {
                $accountCred = Get-Credential $searchServiceAccount.Username
            }
            $managedAccountSearch = New-SPManagedAccount -Credential $accountCred
        }
        log "  - Creating $($appPoolConfig.Name)..."
        $pool = New-SPServiceApplicationPool -Name $($appPoolConfig.Name) -Account $managedAccountSearch
    }
    Return $pool
}

#EndRegion

#Region Create Business Data Catalog Service Application
# ===================================================================================
# Func: CreateBusinessDataConnectivityServiceApp
# Desc: Business Data Catalog Service Application
# From: http://autospinstaller.codeplex.com/discussions/246532 (user bunbunaz)
# ===================================================================================
Function CreateBusinessDataConnectivityServiceApp([xml]$xmlinput)
{
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.BusinessDataConnectivity -eq $true) -and (Get-Command -Name New-SPBusinessDataCatalogServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        Try
        {
            $dbServer = $xmlinput.Configuration.ServiceApps.BusinessDataConnectivity.Database.DBServer
            # If we haven't specified a DB Server then just use the default used by the Farm
            If ([string]::IsNullOrEmpty($dbServer))
            {
                $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
            }
            $bdcAppName = $xmlinput.Configuration.ServiceApps.BusinessDataConnectivity.Name
            $dbPrefix = Get-DBPrefix $xmlinput
            $bdcDataDB = $dbPrefix+$($xmlinput.Configuration.ServiceApps.BusinessDataConnectivity.Database.Name)
            $bdcAppProxyName = $xmlinput.Configuration.ServiceApps.BusinessDataConnectivity.ProxyName
            log " - Provisioning $bdcAppName"
            $applicationPool = Get-HostedServicesAppPool $xmlinput
            log " - Checking local service instance..."
            # Get the service instance
            $bdcServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.BusinessData.SharedService.BdcServiceInstance"}
            $bdcServiceInstance = $bdcServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
            If (-not $?) { Throw " - Failed to find the service instance" }
            # Start Service instances
            If($bdcServiceInstance.Status -eq "Disabled")
            {
                log " - Starting $($bdcServiceInstance.TypeName)..."
                $bdcServiceInstance.Provision()
                If (-not $?) { Throw " - Failed to start $($bdcServiceInstance.TypeName)" }
                # Wait
                log " - Waiting for $($bdcServiceInstance.TypeName)..." 
                While ($bdcServiceInstance.Status -ne "Online")
                {
                    log "." 
                    Start-Sleep 1
                    $bdcServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.BusinessData.SharedService.BdcServiceInstance"}
                    $bdcServiceInstance = $bdcServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                }
                log ($bdcServiceInstance.Status)
            }
            Else
            {
                log " - $($bdcServiceInstance.TypeName) already started."
            }
            # Create a Business Data Catalog Service Application
            If ((Get-SPServiceApplication | ? {$_.GetType().ToString() -eq "Microsoft.SharePoint.BusinessData.SharedService.BdcServiceApplication"}) -eq $null)
            {
                # Create Service App
                log " - Creating $bdcAppName..."
                $bdcDataServiceApp = New-SPBusinessDataCatalogServiceApplication -Name $bdcAppName -ApplicationPool $applicationPool -DatabaseServer $dbServer -DatabaseName $bdcDataDB
                If (-not $?) { Throw " - Failed to create $bdcAppName" }
            }
            Else
            {
                log " - $bdcAppName already provisioned."
            }
            log " - Done creating $bdcAppName."
        }
        Catch
        {
            Throw " - Error provisioning Business Data Connectivity application. $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Create Word Automation Service
Function CreateWordAutomationServiceApp ([xml]$xmlinput)
{
    $serviceConfig = $xmlinput.Configuration.ServiceApps.WordAutomationService
    $dbServer = $serviceConfig.Database.DBServer
    # If we haven't specified a DB Server then just use the default used by the Farm
    If ([string]::IsNullOrEmpty($dbServer))
    {
        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
    }
    $dbPrefix = Get-DBPrefix $xmlinput
    $serviceDB = $dbPrefix+$($serviceConfig.Database.Name)
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Get-Command -Name New-SPWordConversionServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        $serviceInstanceType = "Microsoft.Office.Word.Server.Service.WordServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                        -ServiceNewCmdlet "New-SPWordConversionServiceApplication -DatabaseServer $dbServer -DatabaseName $serviceDB -Default" `
                                        -ServiceProxyNewCmdlet "New-SPWordConversionServiceApplicationProxy" # Fake cmdlet, but the CreateGenericServiceApplication function expects something
        # Run the Word Automation Timer Job immediately; otherwise we will have a Health Analyzer error condition until the job runs as scheduled
        If (Get-SPServiceApplication | ? {$_.DisplayName -eq $($serviceConfig.Name)})
        {
            Get-SPTimerJob | ? {$_.GetType().ToString() -eq "Microsoft.Office.Word.Server.Service.QueueJob"} | ForEach-Object {$_.RunNow()}
        }
        WriteLine
    }
}
#EndRegion

#Region Enterprise Service Apps

#Region Create Excel Service
Function CreateExcelServiceApp ([xml]$xmlinput)
{
    $officeServerPremium = $xmlinput.Configuration.Install.SKU -replace "Enterprise","1" -replace "Standard","0"
    If (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices -eq $true)
    {
        WriteLine
        if ($officeServerPremium -eq "1")
        {
            Try
            {
                $excelAppName = $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices.Name
                $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
                $portalURL = $portalWebApp.URL
                $portalPort = $portalWebApp.Port
                log " - Provisioning $excelAppName..."
                $applicationPool = Get-HostedServicesAppPool $xmlinput
                log " - Checking local service instance..."
                # Get the service instance
                $excelServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Excel.Server.MossHost.ExcelServerWebServiceInstance"}
                $excelServiceInstance = $excelServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                If (-not $?) { Throw " - Failed to find the service instance" }
                # Start Service instances
                If($excelServiceInstance.Status -eq "Disabled")
                {
                    log " - Starting $($excelServiceInstance.TypeName)..."
                    $excelServiceInstance.Provision()
                    If (-not $?) { Throw " - Failed to start $($excelServiceInstance.TypeName) instance" }
                    # Wait
                    log " - Waiting for $($excelServiceInstance.TypeName)..." 
                    While ($excelServiceInstance.Status -ne "Online")
                    {
                        log "." 
                        Start-Sleep 1
                        $excelServiceInstances = Get-SPServiceInstance | ? {$_.GetType().ToString() -eq "Microsoft.Office.Excel.Server.MossHost.ExcelServerWebServiceInstance"}
                        $excelServiceInstance = $excelServiceInstances | ? {MatchComputerName $_.Server.Address $env:COMPUTERNAME}
                    }
                    log ($excelServiceInstance.Status)
                }
                Else
                {
                    log " - $($excelServiceInstance.TypeName) already started."
                }
                # Create an Excel Service Application
                If ((Get-SPServiceApplication | ? {$_.GetType().ToString() -eq "Microsoft.Office.Excel.Server.MossHost.ExcelServerWebServiceApplication"}) -eq $null)
                {
                    # Create Service App
                    log " - Creating $excelAppName..."
                    # Check if our new cmdlets are available yet,  if not, re-load the SharePoint PS Snapin
                    If (!(Get-Command New-SPExcelServiceApplication -ErrorAction SilentlyContinue))
                    {
                        log " - Re-importing SP PowerShell Snapin to enable new cmdlets..."
                        Remove-PSSnapin Microsoft.SharePoint.PowerShell
                        Load-SharePoint-PowerShell
                    }
                    $excelServiceApp = New-SPExcelServiceApplication -name $excelAppName -ApplicationPool $($applicationPool.Name) -Default
                    If (-not $?) { Throw " - Failed to create $excelAppName" }
                    log " - Configuring service app settings..."
                    Set-SPExcelFileLocation -Identity "http://" -LocationType SharePoint -IncludeChildren -Address $portalURL`:$portalPort -ExcelServiceApplication $excelAppName -ExternalDataAllowed 2 -WorkbookSizeMax 10 | Out-Null
                    $caUrl = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\$env:spVer.0\WSS").GetValue("CentralAdministrationURL")
                    New-SPExcelFileLocation -LocationType SharePoint -IncludeChildren -Address $caUrl -ExcelServiceApplication $excelAppName -ExternalDataAllowed 2 -WorkbookSizeMax 10 | Out-Null

                    # Configure unattended accounts, based on:
                    # http://blog.falchionconsulting.com/index.php/2010/10/service-accounts-and-managed-service-accounts-in-sharepoint-2010/
                    If (($xmlinput.Configuration.EnterpriseServiceApps.ExcelServices.UnattendedIDUser) -and ($xmlinput.Configuration.EnterpriseServiceApps.ExcelServices.UnattendedIDPassword))
                    {
                        log " - Setting unattended account credentials..."

                        # Reget application to prevent update conflict error message
                        $excelServiceApp = Get-SPExcelServiceApplication

                        # Get account credentials
                        $excelAcct = $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices.UnattendedIDUser
                        $excelAcctPWD = $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices.UnattendedIDPassword
                        If (!($excelAcct) -or $excelAcct -eq "" -or !($excelAcctPWD) -or $excelAcctPWD -eq "")
                        {
                            # MK: added throw
                            # log  " - Prompting for Excel Unattended Account:"
                            # $unattendedAccount = $host.ui.PromptForCredential("Excel Setup", "Enter Excel Unattended Account Credentials:", "$excelAcct", "NetBiosUserName" )
                            throw "ERROR: Excel Unattended Account is missing"
                        }
                        Else
                        {
                            $secPassword = ConvertTo-SecureString "$excelAcctPWD" -AsPlaintext -Force
                            $unattendedAccount = New-Object System.Management.Automation.PsCredential $excelAcct,$secPassword
                        }

                        # Set the group claim and admin principals
                        $groupClaim = New-SPClaimsPrincipal -Identity "nt authority\authenticated users" -IdentityType WindowsSamAccountName
                        $adminPrincipal = New-SPClaimsPrincipal -Identity "$($env:userdomain)\$($env:username)" -IdentityType WindowsSamAccountName

                        # Set the field values
                        $secureUserName = ConvertTo-SecureString $unattendedAccount.UserName -AsPlainText -Force
                        $securePassword = $unattendedAccount.Password
                        $credentialValues = $secureUserName, $securePassword

                        # Set the Target App Name and create the Target App
                        $name = "$($excelServiceApp.ID)-ExcelUnattendedAccount"
                        log " - Creating Secure Store Target Application $name..."
                        $secureStoreTargetApp = New-SPSecureStoreTargetApplication -Name $name `
                            -FriendlyName "Excel Services Unattended Account Target App" `
                            -ApplicationType Group `
                            -TimeoutInMinutes 3

                        # Set the account fields
                        $usernameField = New-SPSecureStoreApplicationField -Name "User Name" -Type WindowsUserName -Masked:$false
                        $passwordField = New-SPSecureStoreApplicationField -Name "Password" -Type WindowsPassword -Masked:$false
                        $fields = $usernameField, $passwordField

                        # Get the service context
                        $subId = [Microsoft.SharePoint.SPSiteSubscriptionIdentifier]::Default
                        $context = [Microsoft.SharePoint.SPServiceContext]::GetContext($excelServiceApp.ServiceApplicationProxyGroup, $subId)

                        # Check to see if the Secure Store App already exists
                        $secureStoreApp = Get-SPSecureStoreApplication -ServiceContext $context -Name $name -ErrorAction SilentlyContinue
                        If ($secureStoreApp -eq $null) {
                            # Doesn't exist so create.
                            log " - Creating Secure Store Application..."
                            $secureStoreApp = New-SPSecureStoreApplication -ServiceContext $context `
                                -TargetApplication $secureStoreTargetApp `
                                -Administrator $adminPrincipal `
                                -CredentialsOwnerGroup $groupClaim `
                                -Fields $fields
                        }
                        # Update the field values
                        log " - Updating Secure Store Group Credential Mapping..."
                        Update-SPSecureStoreGroupCredentialMapping -Identity $secureStoreApp -Values $credentialValues

                        # Set the unattended service account application ID
                        Set-SPExcelServiceApplication -Identity $excelServiceApp -UnattendedAccountApplicationId $name
                    }
                    Else
                    {
                        log " - Unattended account credentials not supplied in configuration file - skipping."
                    }
                }
                Else
                {
                    log " - $excelAppName already provisioned."
                }
                log " - Done creating $excelAppName."
            }
            Catch
            {
                log " - Error provisioning Excel Service Application. $($_.Exception.Message)"
            }
    }
        else
        {
            log "You have specified a non-Enterprise SKU in `"$(Split-Path -Path $inputFile -Leaf)`". However, SharePoint requires the Enterprise SKU and corresponding PIDKey to provision Excel Services."
        }
        WriteLine
    }
}
#EndRegion

#Region Create Visio Graphics Service
Function CreateVisioServiceApp ([xml]$xmlinput)
{
    $officeServerPremium = $xmlinput.Configuration.Install.SKU -replace "Enterprise","1" -replace "Standard","0"
    $serviceConfig = $xmlinput.Configuration.EnterpriseServiceApps.VisioService
    If (ShouldIProvision $serviceConfig -eq $true)
    {
        WriteLine
        if ($officeServerPremium -eq "1")
        {
            $serviceInstanceType = "Microsoft.Office.Visio.Server.Administration.VisioGraphicsServiceInstance"
            CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                            -ServiceInstanceType $serviceInstanceType `
                                            -ServiceName $serviceConfig.Name `
                                            -ServiceProxyName $serviceConfig.ProxyName `
                                            -ServiceGetCmdlet "Get-SPVisioServiceApplication" `
                                            -ServiceProxyGetCmdlet "Get-SPVisioServiceApplicationProxy" `
                                            -ServiceNewCmdlet "New-SPVisioServiceApplication" `
                                            -ServiceProxyNewCmdlet "New-SPVisioServiceApplicationProxy"

            If (Get-Command -Name Get-SPVisioServiceApplication -ErrorAction SilentlyContinue)
            {
                # http://blog.falchionconsulting.com/index.php/2010/10/service-accounts-and-managed-service-accounts-in-sharepoint-2010/
                If ($serviceConfig.UnattendedIDUser -and $serviceConfig.UnattendedIDPassword)
                {
                    log " - Setting unattended account credentials..."

                    $serviceApplication = Get-SPServiceApplication -name $serviceConfig.Name

                    # Get account credentials
                    $visioAcct = $xmlinput.Configuration.EnterpriseServiceApps.VisioService.UnattendedIDUser
                    $visioAcctPWD = $xmlinput.Configuration.EnterpriseServiceApps.VisioService.UnattendedIDPassword
                    If (!($visioAcct) -or $visioAcct -eq "" -or !($visioAcctPWD) -or $visioAcctPWD -eq "")
                    {
                        # log  " - Prompting for Visio Unattended Account:"
                        # $unattendedAccount = $host.ui.PromptForCredential("Visio Setup", "Enter Visio Unattended Account Credentials:", "$visioAcct", "NetBiosUserName" )
                        # MK: added throw
                        throw "ERROR: Visio Unattended Account is missing"
                    }
                    Else
                    {
                        $secPassword = ConvertTo-SecureString "$visioAcctPWD" -AsPlaintext -Force
                        $unattendedAccount = New-Object System.Management.Automation.PsCredential $visioAcct,$secPassword
                    }

                    # Set the group claim and admin principals
                    $groupClaim = New-SPClaimsPrincipal -Identity "nt authority\authenticated users" -IdentityType WindowsSamAccountName
                    $adminPrincipal = New-SPClaimsPrincipal -Identity "$($env:userdomain)\$($env:username)" -IdentityType WindowsSamAccountName

                    # Set the field values
                    $secureUserName = ConvertTo-SecureString $unattendedAccount.UserName -AsPlainText -Force
                    $securePassword = $unattendedAccount.Password
                    $credentialValues = $secureUserName, $securePassword

                    # Set the Target App Name and create the Target App
                    $name = "$($serviceApplication.ID)-VisioUnattendedAccount"
                    log " - Creating Secure Store Target Application $name..."
                    $secureStoreTargetApp = New-SPSecureStoreTargetApplication -Name $name `
                        -FriendlyName "Visio Services Unattended Account Target App" `
                        -ApplicationType Group `
                        -TimeoutInMinutes 3

                    # Set the account fields
                    $usernameField = New-SPSecureStoreApplicationField -Name "User Name" -Type WindowsUserName -Masked:$false
                    $passwordField = New-SPSecureStoreApplicationField -Name "Password" -Type WindowsPassword -Masked:$false
                    $fields = $usernameField, $passwordField

                    # Get the service context
                    $subId = [Microsoft.SharePoint.SPSiteSubscriptionIdentifier]::Default
                    $context = [Microsoft.SharePoint.SPServiceContext]::GetContext($serviceApplication.ServiceApplicationProxyGroup, $subId)

                    # Check to see if the Secure Store App already exists
                    $secureStoreApp = Get-SPSecureStoreApplication -ServiceContext $context -Name $name -ErrorAction SilentlyContinue
                    If (!($secureStoreApp))
                    {
                        # Doesn't exist so create.
                        log " - Creating Secure Store Application..."
                        $secureStoreApp = New-SPSecureStoreApplication -ServiceContext $context `
                            -TargetApplication $secureStoreTargetApp `
                            -Administrator $adminPrincipal `
                            -CredentialsOwnerGroup $groupClaim `
                            -Fields $fields
                    }
                    # Update the field values
                    log " - Updating Secure Store Group Credential Mapping..."
                    Update-SPSecureStoreGroupCredentialMapping -Identity $secureStoreApp -Values $credentialValues

                    # Set the unattended service account application ID
                    log " - Setting Application ID for Visio Service..."
                    $serviceApplication | Set-SPVisioExternalData -UnattendedServiceAccountApplicationID $name
                }
                Else
                {
                    log " - Unattended account credentials not supplied in configuration file - skipping."
                }
            }
        }
        else
        {
            log "You have specified a non-Enterprise SKU in `"$(Split-Path -Path $inputFile -Leaf)`". However, SharePoint requires the Enterprise SKU and corresponding PIDKey to provision Visio Services."
        }
        WriteLine
    }

}
#EndRegion

#Region Create PerformancePoint Service
Function CreatePerformancePointServiceApp ([xml]$xmlinput)
{
    $officeServerPremium = $xmlinput.Configuration.Install.SKU -replace "Enterprise","1" -replace "Standard","0"
    $serviceConfig = $xmlinput.Configuration.EnterpriseServiceApps.PerformancePointService
    If (ShouldIProvision $serviceConfig -eq $true)
    {
        WriteLine
        if ($officeServerPremium -eq "1")
        {
            $dbServer = $serviceConfig.Database.DBServer
    	    # If we haven't specified a DB Server then just use the default used by the Farm
    	    If ([string]::IsNullOrEmpty($dbServer))
    	    {
    	        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
    	    }
            $dbPrefix = Get-DBPrefix $xmlinput
    	    $serviceDB = $dbPrefix+$serviceConfig.Database.Name
            $serviceInstanceType = "Microsoft.PerformancePoint.Scorecards.BIMonitoringServiceInstance"
            CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                            -ServiceInstanceType $serviceInstanceType `
                                            -ServiceName $serviceConfig.Name `
                                            -ServiceProxyName $serviceConfig.ProxyName `
                                            -ServiceGetCmdlet "Get-SPPerformancePointServiceApplication" `
                                            -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                            -ServiceNewCmdlet "New-SPPerformancePointServiceApplication" `
                                            -ServiceProxyNewCmdlet "New-SPPerformancePointServiceApplicationProxy"

            $application = Get-SPPerformancePointServiceApplication | ? {$_.Name -eq $serviceConfig.Name}
            If ($application)
            {
                $farmAcct = $xmlinput.Configuration.Farm.Account.Username
                log " - Granting $farmAcct rights to database $serviceDB..."
                Get-SPDatabase | Where {$_.Name -eq $serviceDB} | Add-SPShellAdmin -UserName $farmAcct
                log " - Setting PerformancePoint Data Source Unattended Service Account..."
                $performancePointAcct = $serviceConfig.UnattendedIDUser
                $performancePointAcctPWD = $serviceConfig.UnattendedIDPassword
                If (!($performancePointAcct) -or $performancePointAcct -eq "" -or !($performancePointAcctPWD) -or $performancePointAcctPWD -eq "")
                {
                    # log  " - Prompting for PerformancePoint Unattended Service Account:"
                    # $performancePointCredential = $host.ui.PromptForCredential("PerformancePoint Setup", "Enter PerformancePoint Unattended Account Credentials:", "$performancePointAcct", "NetBiosUserName" )
                    # MK: added throw
                    throw "ERROR: PerformancePoint Unattended Account is missing"
                }
                Else
                {
                    $secPassword = ConvertTo-SecureString "$performancePointAcctPWD" -AsPlaintext -Force
                    $performancePointCredential = New-Object System.Management.Automation.PsCredential $performancePointAcct,$secPassword
                }
                $application | Set-SPPerformancePointSecureDataValues -DataSourceUnattendedServiceAccount $performancePointCredential

                If (!(CheckFor2010SP1)) # Only need this if our environment isn't up to Service Pack 1 for SharePoint 2010
                {
                    # Rename the performance point service application database
                    log " - Renaming Performance Point Service Application Database"
                    $settingsDB = $application.SettingsDatabase
                    $newDB = $serviceDB
                    $sqlServer = ($settingsDB -split "\\\\")[0]
                    $oldDB = ($settingsDB -split "\\\\")[1]
                    If (!($newDB -eq $oldDB)) # Check if it's already been renamed, in case we're running the script again
                    {
                        log " - Renaming Performance Point Service Application Database"
                        RenameDatabase -sqlServer $sqlServer -oldName $oldDB -newName $newDB
                        Set-SPPerformancePointServiceApplication  -Identity $serviceConfig.Name -SettingsDatabase $newDB | Out-Null
                    }
                    Else
                    {
                    log " - Database already named: $newDB"
                    }
                }
            }
        }
        else
        {
            log " You have specified a non-Enterprise SKU in `"$(Split-Path -Path $inputFile -Leaf)`". However, SharePoint requires the Enterprise SKU and corresponding PIDKey to provision PerformancePoint Services."
        }
        WriteLine
    }
}
#EndRegion

#Region Create Access 2010 Service
Function CreateAccess2010ServiceApp ([xml]$xmlinput)
{
    $officeServerPremium = $xmlinput.Configuration.Install.SKU -replace "Enterprise","1" -replace "Standard","0"
    $serviceConfig = $xmlinput.Configuration.EnterpriseServiceApps.AccessService
    If (ShouldIProvision $serviceConfig -eq $true)
    {
        WriteLine
        if ($officeServerPremium -eq "1")
        {
            $serviceInstanceType = "Microsoft.Office.Access.Server.MossHost.AccessServerWebServiceInstance"
            CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                            -ServiceInstanceType $serviceInstanceType `
                                            -ServiceName $serviceConfig.Name `
                                            -ServiceProxyName $serviceConfig.ProxyName `
                                            -ServiceGetCmdlet "Get-SPAccessServiceApplication" `
                                            -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                            -ServiceNewCmdlet "New-SPAccessServiceApplication -Default" `
                                            -ServiceProxyNewCmdlet "New-SPAccessServiceApplicationProxy" # Fake cmdlet (and not needed for Access Services), but the CreateGenericServiceApplication function expects something
        }
        else
        {
            log "You have specified a non-Enterprise SKU in `"$(Split-Path -Path $inputFile -Leaf)`". However, SharePoint requires the Enterprise SKU and corresponding PIDKey to provision Access Services 2010."
        }
        WriteLine
    }
}
#EndRegion

#EndRegion

#Region Create Office Web Apps
Function CreateExcelOWAServiceApp ([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    $serviceConfig = $xmlinput.Configuration.OfficeWebApps.ExcelService
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Test-Path "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\TEMPLATE\FEATURES\OfficeWebApps\feature.xml"))
    {
        WriteLine
        $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
        $portalURL = $portalWebApp.URL
        $portalPort = $portalWebApp.Port
        $serviceInstanceType = "Microsoft.Office.Excel.Server.MossHost.ExcelServerWebServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPExcelServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                        -ServiceNewCmdlet "New-SPExcelServiceApplication -Default" `
                                        -ServiceProxyNewCmdlet "New-SPExcelServiceApplicationProxy" # Fake cmdlet (and not needed for Excel Services), but the CreateGenericServiceApplication function expects something

        If (Get-SPExcelServiceApplication)
        {
            log " - Setting Excel Services Trusted File Location..."
            Set-SPExcelFileLocation -Identity "http://" -LocationType SharePoint -IncludeChildren -Address $portalURL`:$portalPort -ExcelServiceApplication $($serviceConfig.Name) -ExternalDataAllowed 2 -WorkbookSizeMax 10
        }
        WriteLine
    }
}

Function CreatePowerPointOWAServiceApp ([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    $serviceConfig = $xmlinput.Configuration.OfficeWebApps.PowerPointService
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Test-Path "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\TEMPLATE\FEATURES\OfficeWebApps\feature.xml"))
    {
        WriteLine
        If ($env:spVer -eq "14") {$serviceInstanceType = "Microsoft.Office.Server.PowerPoint.SharePoint.Administration.PowerPointWebServiceInstance"}
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPPowerPointServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPPowerPointServiceApplicationProxy" `
                                        -ServiceNewCmdlet "New-SPPowerPointServiceApplication" `
                                        -ServiceProxyNewCmdlet "New-SPPowerPointServiceApplicationProxy"
        WriteLine
    }
}

Function CreateWordViewingOWAServiceApp ([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    $serviceConfig = $xmlinput.Configuration.OfficeWebApps.WordViewingService
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Test-Path "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\TEMPLATE\FEATURES\OfficeWebApps\feature.xml"))
    {
        WriteLine
        $serviceInstanceType = "Microsoft.Office.Web.Environment.Sharepoint.ConversionServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                        -ServiceNewCmdlet "New-SPWordViewingServiceApplication" `
                                        -ServiceProxyNewCmdlet "New-SPWordViewingServiceApplicationProxy"
        WriteLine
    }
}
#EndRegion

#Region SharePoint 2013 Service Apps
#Region Create App Domain
Function CreateAppManagementServiceApp ([xml]$xmlinput)
{
    $serviceConfig = $xmlinput.Configuration.ServiceApps.AppManagementService
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Get-Command -Name New-SPAppManagementServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        $dbPrefix = Get-DBPrefix $xmlinput
	    $serviceDB = $dbPrefix+$serviceConfig.Database.Name
	    $dbServer = $serviceConfig.Database.DBServer
	    # If we haven't specified a DB Server then just use the default used by the Farm
	    If ([string]::IsNullOrEmpty($dbServer))
	    {
	        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
	    }
        $serviceInstanceType = "Microsoft.SharePoint.AppManagement.AppManagementServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
									    -ServiceNewCmdlet "New-SPAppManagementServiceApplication -DatabaseServer $dbServer -DatabaseName $serviceDB" `
                                        -ServiceProxyNewCmdlet "New-SPAppManagementServiceApplicationProxy"

		# Configure your app domain and location
		log " - Setting App Domain `"$($serviceConfig.AppDomain)`"..."
	    Set-SPAppDomain -AppDomain $serviceConfig.AppDomain
        WriteLine
    }
}

Function CreateSubscriptionSettingsServiceApp ([xml]$xmlinput)
{
    $serviceConfig = $xmlinput.Configuration.ServiceApps.SubscriptionSettingsService
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Get-Command -Name New-SPSubscriptionSettingsServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        $dbPrefix = Get-DBPrefix $xmlinput
	    $serviceDB = $dbPrefix+$serviceConfig.Database.Name
	    $dbServer = $serviceConfig.Database.DBServer
	    # If we haven't specified a DB Server then just use the default used by the Farm
	    If ([string]::IsNullOrEmpty($dbServer))
	    {
	        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
	    }
        $serviceInstanceType = "Microsoft.SharePoint.SPSubscriptionSettingsServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
									    -ServiceNewCmdlet "New-SPSubscriptionSettingsServiceApplication -DatabaseServer $dbServer -DatabaseName $serviceDB" `
                                        -ServiceProxyNewCmdlet "New-SPSubscriptionSettingsServiceApplicationProxy"

		log " - Setting Site Subscription name `"$($serviceConfig.AppSiteSubscriptionName)`"..."
	    Set-SPAppSiteSubscriptionName -Name $serviceConfig.AppSiteSubscriptionName -Confirm:$false
        WriteLine
    }
}
#EndRegion

#Region Create Access Services (2013)
Function CreateAccessServicesApp ([xml]$xmlinput)
{
    $officeServerPremium = $xmlinput.Configuration.Install.SKU -replace "Enterprise","1" -replace "Standard","0"
    $dbServer = $serviceConfig.Database.DBServer
    # If we haven't specified a DB Server then just use the default used by the Farm
    If ([string]::IsNullOrEmpty($dbServer))
    {
        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
    }
    $dbPrefix = Get-DBPrefix $xmlinput
    $serviceDB = $dbPrefix+$($serviceConfig.Database.Name)
    $serviceConfig = $xmlinput.Configuration.EnterpriseServiceApps.AccessServices
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Get-Command -Name New-SPAccessServicesApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        if ($officeServerPremium -eq "1")
        {
            $serviceInstanceType = "Microsoft.Office.Access.Services.MossHost.AccessServicesWebServiceInstance"
            CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                            -ServiceInstanceType $serviceInstanceType `
                                            -ServiceName $serviceConfig.Name `
                                            -ServiceProxyName $serviceConfig.ProxyName `
                                            -ServiceGetCmdlet "Get-SPAccessServicesApplication" `
                                            -ServiceProxyGetCmdlet "Get-SPServicesApplicationProxy" `
                                            -ServiceNewCmdlet "New-SPAccessServicesApplication -DatabaseServer $dbServer -Default" `
                                            -ServiceProxyNewCmdlet "New-SPAccessServicesApplicationProxy"
        }
        else
        {
            log "You have specified a non-Enterprise SKU in `"$(Split-Path -Path $inputFile -Leaf)`". However, SharePoint requires the Enterprise SKU and corresponding PIDKey to provision Access Services 2010."
        }
        WriteLine
    }
}

#EndRegion

#Region PowerPoint Conversion Service
Function CreatePowerPointConversionServiceApp ([xml]$xmlinput)
{
    $serviceConfig = $xmlinput.Configuration.ServiceApps.PowerPointConversionService
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Get-Command -Name New-SPPowerPointConversionServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        $serviceInstanceType = "Microsoft.Office.Server.PowerPoint.Administration.PowerPointConversionServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                        -ServiceNewCmdlet "New-SPPowerPointConversionServiceApplication" `
                                        -ServiceProxyNewCmdlet "New-SPPowerPointConversionServiceApplicationProxy"
        WriteLine
    }
}
#EndRegion

#Region Create Machine Translation Service
Function CreateMachineTranslationServiceApp ([xml]$xmlinput)
{
    $serviceConfig = $xmlinput.Configuration.ServiceApps.MachineTranslationService
    $dbServer = $serviceConfig.Database.DBServer
    # If we haven't specified a DB Server then just use the default used by the Farm
    If ([string]::IsNullOrEmpty($dbServer))
    {
        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
    }
    $dbPrefix = Get-DBPrefix $xmlinput
    $translationDatabase = $dbPrefix+$($serviceConfig.Database.Name)
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Get-Command -Name New-SPTranslationServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        $serviceInstanceType = "Microsoft.Office.TranslationServices.TranslationServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                        -ServiceNewCmdlet "New-SPTranslationServiceApplication -DatabaseServer $dbServer -DatabaseName $translationDatabase -Default" `
                                        -ServiceProxyNewCmdlet "New-SPTranslationServiceApplicationProxy"
        WriteLine
    }
}
#EndRegion

#Region Create Work Management Service
Function CreateWorkManagementServiceApp ([xml]$xmlinput)
{
    $serviceConfig = $xmlinput.Configuration.ServiceApps.WorkManagementService
    If ((ShouldIProvision $serviceConfig -eq $true) -and (Get-Command -Name New-SPWorkManagementServiceApplication -ErrorAction SilentlyContinue))
    {
        WriteLine
        $serviceInstanceType = "Microsoft.Office.Server.WorkManagement.WorkManagementServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
                                        -ServiceNewCmdlet "New-SPWorkManagementServiceApplication" `
                                        -ServiceProxyNewCmdlet "New-SPWorkManagementServiceApplicationProxy"
        WriteLine
    }
}
#EndRegion
#EndRegion

#Region Create Project Server Service Application
Function CreateProjectServerServiceApp ([xml]$xmlinput)
{
    $serviceConfig = $xmlinput.Configuration.ProjectServer.ServiceApp
    If ((ShouldIProvision $serviceConfig -eq $true) -and ($xmlinput.Configuration.ProjectServer.Install -eq $true) -and (Get-Command -Name New-SPProjectServiceApplication -ErrorAction SilentlyContinue)) # We need to check that Project Server has been requested for install, not just if the service app should be provisioned
    {
        WriteLine
        $dbPrefix = Get-DBPrefix $xmlinput
	    $serviceDB = $dbPrefix+$serviceConfig.Database.Name
	    $dbServer = $serviceConfig.Database.DBServer
	    # If we haven't specified a DB Server then just use the default used by the Farm
	    If ([string]::IsNullOrEmpty($dbServer))
	    {
	        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
	    }
        $serviceInstanceType = "Microsoft.Office.Project.Server.Administration.PsiServiceInstance"
        CreateGenericServiceApplication -ServiceConfig $serviceConfig `
                                        -ServiceInstanceType $serviceInstanceType `
                                        -ServiceName $serviceConfig.Name `
                                        -ServiceProxyName $serviceConfig.ProxyName `
                                        -ServiceGetCmdlet "Get-SPServiceApplication" `
                                        -ServiceProxyGetCmdlet "Get-SPServiceApplicationProxy" `
									    -ServiceNewCmdlet "New-SPProjectServiceApplication -Proxy:`$true" `
                                        -ServiceProxyNewCmdlet "New-SPProjectServiceApplicationProxy" # We won't be using the proxy cmdlet though for Project Server

        # Update process account for Project services
        $projectServices = @("Microsoft.Office.Project.Server.Administration.ProjectEventService", "Microsoft.Office.Project.Server.Administration.ProjectCalcService", "Microsoft.Office.Project.Server.Administration.ProjectQueueService")
        foreach ($projectService in $projectServices)
        {
            $projectServiceInstances = (Get-SPFarm).Services | ? {$_.GetType().ToString() -eq $projectService}
            foreach ($projectServiceInstance in $projectServiceInstances)
            {
                UpdateProcessIdentity $projectServiceInstance
            }
        }
        # Create a Project Server DB
        $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
        log " - Creating Project Server database `"$serviceDB`"..." 
        if (!(Get-SPDatabase | Where-Object {$_.Name -eq $serviceDB}))
        {
            ##New-SPProjectDatabase -Name $serviceDB -WebApplication (Get-SPWebApplication | Where-Object {$_.Name -eq $portalWebApp.Name}) -DatabaseServer $dbServer | Out-Null
            New-SPProjectDatabase -Name $serviceDB -ServiceApplication (Get-SPServiceApplication | Where-Object {$_.Name -eq $serviceConfig.Name}) -DatabaseServer $dbServer | Out-Null
            if ($?) {log "Done."}
            else
            {
                log "."
                throw {"Error creating the Project Server database."}
            }
        }
        else
        {
            log "Already exits."
        }
        # Create a Project Server Web Instance
        $projectManagedPath = $xmlinput.Configuration.ProjectServer.ServiceApp.ManagedPath
        New-SPManagedPath -RelativeURL $xmlinput.Configuration.ProjectServer.ServiceApp.ManagedPath -WebApplication (Get-SPWebApplication | Where-Object {$_.Name -eq $portalWebApp.Name}) -Explicit:$true -ErrorAction SilentlyContinue | Out-Null
        log " - Creating Project Server site collection at `"$projectManagedPath`"..." 
        $projectSiteUrl = $portalWebApp.Url+":"+$portalWebApp.Port+"/"+$projectManagedPath
        if (!(Get-SPSite -Identity $projectSiteUrl -ErrorAction SilentlyContinue))
        {
            $projectSite = New-SPSite -Url $projectSiteUrl  -OwnerAlias $env:USERDOMAIN\$env:USERNAME -Template "PROJECTSITE#0"
            if ($?) {log "Done."}
            else
            {
                log "."
                throw {"Error creating the Project Server site collection."}
            }
        }
        else
        {
            log "Already exits."
        }
        log " - Creating Project Server web instance at `"$projectSiteUrl`"..." 
        if (!(Get-SPProjectWebInstance -Url $projectSiteUrl -ErrorAction SilentlyContinue))
        {
            Mount-SPProjectWebInstance -DatabaseName $serviceDB -SiteCollection $projectSite
            if ($?) {log "Done."}
            else
            {
                log "."
                throw {"Error creating the Project Server web instance."}
            }
        }
        else
        {
            log "Already exits."
        }
        WriteLine
    }
}
#EndRegion

#Region Configure Outgoing Email
# This is from http://autospinstaller.codeplex.com/discussions/228507?ProjectName=autospinstaller courtesy of rybocf
Function ConfigureOutgoingEmail
{
    If ($($xmlinput.Configuration.Farm.Services.OutgoingEmail.Configure) -eq $true)
    {
        WriteLine
        Try
        {
            $SMTPServer = $xmlinput.Configuration.Farm.Services.OutgoingEmail.SMTPServer
            $emailAddress = $xmlinput.Configuration.Farm.Services.OutgoingEmail.EmailAddress
            $replyToEmail = $xmlinput.Configuration.Farm.Services.OutgoingEmail.ReplyToEmail
            log " - Configuring Outgoing Email..."
            $loadasm = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint")
            $spGlobalAdmin = New-Object Microsoft.SharePoint.Administration.SPGlobalAdmin
            $spGlobalAdmin.UpdateMailSettings($SMTPServer, $emailAddress, $replyToEmail, 65001)
        }
        Catch
        {
            throw "ERROR: $($_.Exception.Message)"
        }
        WriteLine
    }
}
#EndRegion

#Region Configure Incoming Email
Function ConfigureIncomingEmail
{
    # Ensure the node exists in the XML first as we don't want to inadvertently disable the service if it wasn't explicitly specified
    if (($xmlinput.Configuration.Farm.Services.SelectSingleNode("IncomingEmail")) -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.IncomingEmail -eq $true))
    {
        StopServiceInstance "Microsoft.SharePoint.Administration.SPIncomingEmailServiceInstance"
    }
}
#EndRegion

#Region Configure Foundation Web Application Service
Function ConfigureFoundationWebApplicationService
{
    # Ensure the node exists in the XML first as we don't want to inadvertently disable the service if it wasn't explicitly specified
    if (($xmlinput.Configuration.Farm.Services.SelectSingleNode("FoundationWebApplication")) -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.FoundationWebApplication -eq $true))
    {
        StopServiceInstance "Microsoft.SharePoint.Administration.SPWebServiceInstance"
    }
}
#EndRegion

#Region Configure Adobe PDF Indexing and Display
# ====================================================================================
# Func: Configure-PDFSearchAndIcon
# Desc: Downloads and installs the PDF iFilter, registers the PDF search file type and document icon for display in SharePoint
# From: Adapted/combined from @brianlala's additions, @tonifrankola's http://www.sharepointusecases.com/index.php/2011/02/automate-pdf-configuration-for-sharepoint-2010-via-powershell/
# And : Paul Hickman's Patch 9609 at http://autospinstaller.codeplex.com/SourceControl/list/patches
# ====================================================================================

Function Configure-PDFSearchAndIcon
{
    WriteLine
    Get-MajorVersionNumber $xmlinput
    log " - Configuring PDF file search, display and handling..."
    $sharePointRoot = "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer"
    $sourceFileLocations = @("$bits\$spYear\PDF\","$bits\PDF\","$bits\AdobePDF\","$((Get-Item $env:TEMP).FullName)\")
    # Only install/configure iFilter if specified, and we are running SP2010 (as SP2013 includes one)
    If ((ShouldIProvision $xmlinput.Configuration.AdobePDF.iFilter -eq $true) -and ($env:spVer -eq "14"))
    {
        $pdfIfilterUrl = "http://download.adobe.com/pub/adobe/acrobat/win/9.x/PDFiFilter64installer.zip"
        log " - Configuring PDF file iFilter and indexing..."
        # Look for the installer or the installer zip in the possible locations
        ForEach ($sourceFileLocation in $sourceFileLocations)
        {
            If (Get-Item $($sourceFileLocation+"PDFFilter64installer.msi") -ErrorAction SilentlyContinue)
            {
                log " - PDF iFilter installer found in $sourceFileLocation."
                $iFilterInstaller = $sourceFileLocation+"PDFFilter64installer.msi"
                Break
            }
            ElseIf (Get-Item $($sourceFileLocation+"PDFiFilter64installer.zip") -ErrorAction SilentlyContinue)
            {
                log " - PDF iFilter installer zip file found in $sourceFileLocation."
                $zipLocation = $sourceFileLocation
                $sourceFile = $sourceFileLocation+"PDFiFilter64installer.zip"
                Break
            }
        }
        # If the MSI hasn't been extracted from the zip yet then extract it
        If (!($iFilterInstaller))
        {
            # If the zip file isn't present then download it first
            If (!($sourceFile))
            {
                log " - PDF iFilter installer or zip not found, downloading..."
                If (Confirm-LocalSession)
                {
                    $zipLocation = (Get-Item $env:TEMP).FullName
                    $destinationFile = $zipLocation+"\PDFiFilter64installer.zip"
                    Import-Module BitsTransfer | Out-Null
                    Start-BitsTransfer -Source $pdfIfilterUrl -Destination $destinationFile -DisplayName "Downloading Adobe PDF iFilter..." -Priority Foreground -Description "From $pdfIfilterUrl..." -ErrorVariable err
                    If ($err) 
                    {
                        log "Could not download Adobe PDF iFilter!"; 
                        # MK: commented
                        # Pause "exit";
                        break
                    }
                    $sourceFile = $destinationFile
                }
                Else {log "The remote use of BITS is not supported. Please pre-download the PDF install files and try again."}
            }
            log " - Extracting Adobe PDF iFilter installer..."
            $shell = New-Object -ComObject Shell.Application
            $iFilterZip = $shell.Namespace($sourceFile)
            $location = $shell.Namespace($zipLocation)
            $location.Copyhere($iFilterZip.items())
            $iFilterInstaller = $zipLocation+"\PDFFilter64installer.msi"
        }
        Try
        {
            log " - Installing Adobe PDF iFilter..."
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$iFilterInstaller`" /passive /norestart" -NoNewWindow -Wait
        }
        Catch {$_}
        If ((Get-PsSnapin |?{$_.Name -eq "Microsoft.SharePoint.PowerShell"})-eq $null)
        {
            log " - Loading SharePoint PowerShell Snapin..."
            Add-PsSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue | Out-Null
        }
        log " - Setting PDF search crawl extension..."
        $searchApplications = Get-SPEnterpriseSearchServiceApplication
        If ($searchApplications)
        {
            ForEach ($searchApplication in $searchApplications)
            {
                Try
                {
                    Get-SPEnterpriseSearchCrawlExtension -SearchApplication $searchApplication -Identity "pdf" -ErrorAction Stop | Out-Null
                    log " - PDF file extension already set for $($searchApplication.DisplayName)."
                }
                Catch
                {
                    New-SPEnterpriseSearchCrawlExtension -SearchApplication $searchApplication -Name "pdf" | Out-Null
                    log " - PDF extension for $($searchApplication.DisplayName) now set."
                }
            }
        }
        Else {log "No search applications found."}
        log " - Updating registry..."
        If ((Get-Item -Path Registry::"HKLM\SOFTWARE\Microsoft\Office Server\$env:spVer.0\Search\Setup\Filters\.pdf" -ErrorAction SilentlyContinue) -eq $null)
        {
            $item = New-Item -Path Registry::"HKLM\SOFTWARE\Microsoft\Office Server\$env:spVer.0\Search\Setup\Filters\.pdf"
            $item | New-ItemProperty -Name Extension -PropertyType String -Value "pdf" | Out-Null
            $item | New-ItemProperty -Name FileTypeBucket -PropertyType DWord -Value 1 | Out-Null
            $item | New-ItemProperty -Name MimeTypes -PropertyType String -Value "application/pdf" | Out-Null
        }
        If ((Get-Item -Path Registry::"HKLM\SOFTWARE\Microsoft\Office Server\$env:spVer.0\Search\Setup\ContentIndexCommon\Filters\Extension\.pdf" -ErrorAction SilentlyContinue) -eq $null)
        {
            $registryItem = New-Item -Path Registry::"HKLM\SOFTWARE\Microsoft\Office Server\$env:spVer.0\Search\Setup\ContentIndexCommon\Filters\Extension\.pdf"
            $registryItem | New-ItemProperty -Name "(default)" -PropertyType String -Value "{E8978DA6-047F-4E3D-9C78-CDBE46041603}" | Out-Null
        }
        $spSearchService = "OSearch"+$env:spVer # Substitute the correct SharePoint version into the service name so we can handle SP2013 as well as SP2010
        If ((Get-Service $spSearchService).Status -eq "Running")
        {
            log " - Restarting SharePoint Search Service..."
            Restart-Service $spSearchService
        }
        log " - Done configuring PDF iFilter and indexing."
    }
    # Only configure PDF icon if we are running SP2010 (as SP2013 includes one)
    If (($xmlinput.Configuration.AdobePDF.Icon.Configure -eq $true) -and ($env:spVer -eq "14"))
    {
        $pdfIconUrl = "http://www.adobe.com/images/pdficon_small.png"
        $docIconFolderPath = "$sharePointRoot\TEMPLATE\XML"
        $docIconFilePath = "$docIconFolderPath\DOCICON.XML"
        log " - Configuring PDF Icon..."
        $pdfIcon = "pdficon_small.png"
        If (!(Get-Item $sharePointRoot\Template\Images\$pdfIcon -ErrorAction SilentlyContinue))
        {
            ForEach ($sourceFileLocation in $sourceFileLocations)
            {
                # Check each possible source file location for the PDF icon
                $copyIcon = Copy-Item -Path $sourceFileLocation\$pdfIcon -Destination $sharePointRoot\Template\Images\$pdfIcon -PassThru -ErrorAction SilentlyContinue
                If ($copyIcon)
                {
                    log " - PDF icon found at $sourceFileLocation\$pdfIcon"
                    Break
                }
            }
            If (!($copyIcon))
            {
                log " - `"$pdfIcon`" not found; downloading it now..."
                If (Confirm-LocalSession)
                {
                    Import-Module BitsTransfer | Out-Null
                    Start-BitsTransfer -Source $pdfIconUrl -Destination "$sharePointRoot\Template\Images\$pdfIcon" -DisplayName "Downloading PDF Icon..." -Priority Foreground -Description "From $pdfIconUrl..." -ErrorVariable err
                    If ($err) 
                    {
                        log "Could not download PDF Icon!"; 
                        # MK: commented
                        # Pause "exit";
                        break
                    }
                }
                Else {log "The remote use of BITS is not supported. Please pre-download the PDF icon and try again."}
            }
            If (Get-Item $sharePointRoot\Template\Images\$pdfIcon) {log " - PDF icon copied successfully."}
            Else {Throw}
        }
        $xml = New-Object XML
        $xml.Load($docIconFilePath)
        If ($xml.SelectSingleNode("//Mapping[@Key='pdf']") -eq $null)
        {
            Try
            {
                log " - Creating backup of DOCICON.XML file..."
                $backupFile = "$docIconFolderPath\DOCICON_Backup.xml"
                Copy-Item $docIconFilePath $backupFile
                log " - Writing new DOCICON.XML..."
                $pdf = $xml.CreateElement("Mapping")
                $pdf.SetAttribute("Key","pdf")
                $pdf.SetAttribute("Value",$pdfIcon)
                $pdf.SetAttribute("EditText","Adobe Acrobat or Reader X")
                $pdf.SetAttribute("OpenControl","AdobeAcrobat.OpenDocuments")
                $xml.DocIcons.ByExtension.AppendChild($pdf) | Out-Null
                $xml.Save($docIconFilePath)
                log " - Restarting IIS..."
                iisreset
            }
            Catch 
            {
                $_; 
                #Pause "exit"; 
                #Break
                # MK: added throw
                throw "ERROR: $($_.Exception.Message)"
            }
        }
    }
    If ($xmlinput.Configuration.AdobePDF.MIMEType.Configure -eq $true)
    {
        # Add the PDF MIME type to each web app so PDFs can be directly viewed/opened without saving locally first
        # More granular and generally preferable to setting the whole web app to "Permissive" file handling
        $mimeType = "application/pdf"
        log " - Adding PDF MIME type `"$mimeType`" web apps..."
        ForEach ($webAppConfig in $xmlinput.Configuration.WebApplications.WebApplication)
        {
            $webAppUrl = $($webAppConfig.url)+":"+$($webAppConfig.Port)
            $webApp = Get-SPWebApplication -Identity $webAppUrl
            If ($webApp.AllowedInlineDownloadedMimeTypes -notcontains $mimeType)
            {
                log "  - "$webAppUrl": Adding "`"$mimeType"`"..." 
                $webApp.AllowedInlineDownloadedMimeTypes.Add($mimeType)
                $webApp.Update()
                log "OK."
            }
            Else
            {
                log "  - "$webAppUrl": "`"$mimeType"`" already added."
            }
        }
    }
    log " - Done configuring PDF indexing and icon display."
    WriteLine
}
#EndRegion

#Region Install Forefront
# ====================================================================================
# Func: InstallForeFront
# Desc: Installs ForeFront Protection 2010 for SharePoint Sites
# ====================================================================================
Function InstallForeFront
{
    If (ShouldIProvision $xmlinput.Configuration.ForeFront -eq $true)
    {
        WriteLine
        If (Test-Path "$env:PROGRAMFILES\Microsoft ForeFront Protection for SharePoint\Launcher.exe")
        {
            log " - ForeFront binaries appear to be already installed - skipping install."
        }
        Else
        {
            # Install ForeFront
            If (Test-Path "$bits\$spYear\Forefront\setup.exe")
            {
                log " - Installing ForeFront binaries..."
                Try
                {
                    Start-Process "$bits\$spYear\Forefront\setup.exe" -ArgumentList "/a `"$configFileForeFront`" /p" -Wait
                    If (-not $?) {Throw}
                    log " - Done installing ForeFront."
                }
                Catch
                {
                    Throw " - Error $LASTEXITCODE occurred running $bits\$spYear\ForeFront\setup.exe"
                }
            }
            Else
            {
                Throw " - ForeFront installer not found in $bits\$spYear\ForeFront folder"
            }
        }
        WriteLine
    }
}
#EndRegion

#Region Remote Functions
Function Get-FarmServers ([xml]$xmlinput)
{
    $servers = $null
    $farmServers = @()
    # Look for server name references in the XML
    ForEach ($node in $xmlinput.SelectNodes("//*[@Provision]|//*[@Install]|//*[CrawlComponent]|//*[QueryComponent]|//*[SearchQueryAndSiteSettingsComponent]|//*[AdminComponent]|//*[IndexComponent]|//*[ContentProcessingComponent]|//*[AnalyticsProcessingComponent]|//*[@Start]"))
    {
        # Try to set the server name from the various elements/attributes
        $servers = @(GetFromNode $node "Provision")
        If ([string]::IsNullOrEmpty($servers)) { $servers = @(GetFromNode $node "Install") }
        If ([string]::IsNullOrEmpty($servers)) { $servers = @(GetFromNode $node "Start") }
        ## No longer required now that we are using ShouldIProvision to get Search Service component server names
<#        If ([string]::IsNullOrEmpty($servers))
        {
            foreach ($serverElement in $node.CrawlComponent.Server) {$crawlServers += @($serverElement.GetAttribute("Name"))}
            foreach ($serverElement in $node.QueryComponent.Server) {$queryServers += @($serverElement.GetAttribute("Name"))}
            foreach ($serverElement in $node.SearchQueryAndSiteSettingsServers.Server) {$siteQueryAndSSServers += @($serverElement.GetAttribute("Name"))}
            foreach ($serverElement in $node.AdminComponent.Server) {$adminServers += @($serverElement.GetAttribute("Name"))}
            foreach ($serverElement in $node.IndexComponent.Server) {$IndexComponent += @($serverElement.GetAttribute("Name"))}
            foreach ($serverElement in $node.ContentProcessingComponent.Server) {$ContentProcessingComponent += @($serverElement.GetAttribute("Name"))}
            foreach ($serverElement in $node.AnalyticsProcessingComponent.Server) {$AnalyticsProcessingComponent += @($serverElement.GetAttribute("Name"))}
            $servers = $crawlServers+$queryServers+$siteQueryAndSSServers+$adminServers+$IndexComponent+$ContentProcessingComponent+$AnalyticsProcessingComponent
        }
#>
        # Accomodate and clean up comma and/or space-separated server names
        # First get rid of any recurring spaces or commas
        While ($servers -match "  ")
        {
            $servers = $servers -replace "  ", " "
        }
        While ($servers -match ",,")
        {
            $servers = $servers -replace ",,", ","
        }
        $servers = $servers -split "," -split " "
        # Remove any "true", "false" or zero-length values as we only want server names
        If ($servers -eq "true" -or $servers -eq "false" -or [string]::IsNullOrEmpty($servers))
        {
            $servers = $null
        }
        else
        {
            # Add any server(s) we found to our $farmServers array
            $farmServers = @($farmServers+$servers)
        }
    }

    # Remove any blanks and duplicates
    $farmServers = $farmServers | Where-Object {$_ -ne ""} | Select-Object -Unique
    Return $farmServers
}

Function Enable-CredSSP ($remoteFarmServers)
{
    ForEach ($server in $remoteFarmServers) {log " - Enabling WSManCredSSP for `"$server`""}
    Enable-WSManCredSSP -Role Client -Force -DelegateComputer $remoteFarmServers | Out-Null
    If (!$?) 
    {
        #Pause "exit"; 
        # MK: added throw
        throw "ERROR: $($_.Exception.Message)"
    }
}

Function Test-ServerConnection ($server)
{
    log " - Testing connection (via Ping) to `"$server`"..." 
    $canConnect = Test-Connection -ComputerName $server -Count 1 -Quiet
    If ($canConnect) {log $($canConnect.ToString() -replace "True","Success.")}
    If (!$canConnect)
    {
        log $($canConnect.ToString() -replace "False","Failed.")
        log " - Check that `"$server`":"
        log "  - Is online"
        log "  - Has the required Windows Firewall exceptions set (or turned off)"
        log "  - Has a valid DNS entry for $server.$($env:USERDNSDOMAIN)"
    }
}

Function Enable-RemoteSession ($server, $password)
{
    If ($password) {$credential = New-Object System.Management.Automation.PsCredential $env:USERDOMAIN\$env:USERNAME,$(ConvertTo-SecureString $password)}
    If (!$credential) {$credential = $host.ui.PromptForCredential("AutoSPInstaller - Remote Install", "Re-Enter Credentials for Remote Authentication:", "$env:USERDOMAIN\$env:USERNAME", "NetBiosUserName")}
    $username = $credential.Username
    $password = ConvertTo-PlainText $credential.Password
    $configureTargetScript = "$env:dp0\AutoSPInstallerConfigureRemoteTarget.ps1"
    $psExec = $env:dp0+"\PsExec.exe"
    If (!(Get-Item ($psExec) -ErrorAction SilentlyContinue))
    {
        log " - PsExec.exe not found; downloading..."
        $psExecUrl = "http://live.sysinternals.com/PsExec.exe"
        Import-Module BitsTransfer | Out-Null
        Start-BitsTransfer -Source $psExecUrl -Destination $psExec -DisplayName "Downloading Sysinternals PsExec..." -Priority Foreground -Description "From $psExecUrl..." -ErrorVariable err
        If ($err) 
        {
            log "Could not download PsExec!"; 
            # MK: commented
            # Pause "exit";
            break
        }
        $sourceFile = $destinationFile
    }
    log " - Updating PowerShell execution policy on `"$server`" via PsExec..."
    Start-Process -FilePath "$psExec" `
                  -ArgumentList "/acceptEula \\$server -h powershell.exe -Command `"Set-ExecutionPolicy Bypass -Force ; Stop-Process -Id `$PID`"" `
                  -Wait -NoNewWindow
    # Another way to exit powershell when running over PsExec from http://www.leeholmes.com/blog/2007/10/02/using-powershell-and-PsExec-to-invoke-expressions-on-remote-computers/
    # PsExec \\server cmd /c "echo . | powershell {command}"
    log " - Enabling PowerShell remoting on `"$server`" via PsExec..."
    Start-Process -FilePath "$psExec" `
                  -ArgumentList "/acceptEula \\$server -u $username -p $password -h powershell.exe -Command `"$configureTargetScript`"" `
                  -Wait -NoNewWindow
}

Function Install-NetFramework ($server, $password)
{
	If ($password) {$credential = New-Object System.Management.Automation.PsCredential $env:USERDOMAIN\$env:USERNAME,$(ConvertTo-SecureString $password)}
    If (!$credential) {$credential = $host.ui.PromptForCredential("AutoSPInstaller - Remote Install", "Re-Enter Credentials for Remote Authentication:", "$env:USERDOMAIN\$env:USERNAME", "NetBiosUserName")}
    If ($session.Name -ne "AutoSPInstallerSession-$server")
    {
        log " - Starting remote session to $server..."
        $session = New-PSSession -Name "AutoSPInstallerSession-$server" -Authentication Credssp -Credential $credential -ComputerName $server
    }
    $remoteQueryOS = Invoke-Command -ScriptBlock {Get-WmiObject Win32_OperatingSystem} -Session $session
	If (!($remoteQueryOS.Version.Contains("6.2")) -and !($remoteQueryOS.Version.Contains("6.3"))) # Only perform the stuff below if we aren't on Windows 2012 or 2012 R2
	{
	    log " - Pre-installing .Net Framework feature on $server..."
	    Invoke-Command -ScriptBlock {Import-Module ServerManager | Out-Null
	                                # Get the current progress preference
	                                $pref = $ProgressPreference
	                                # Hide the progress bar since it tends to not disappear
	                                $ProgressPreference = "SilentlyContinue"
	                                Import-Module ServerManager
	                                If (!(Get-WindowsFeature -Name NET-Framework).Installed) {Add-WindowsFeature -Name NET-Framework | Out-Null}
	                                # Restore progress preference
	                                $ProgressPreference = $pref} -Session $session
	}
}

Function Install-WindowsIdentityFoundation ($server, $password)
{
    # This step is required due to a known issue with the PrerequisiteInstaller.exe over a remote session;
    # Specifically, because Windows Update Standalone Installer (wusa.exe) blows up with error code 5
    # With a fully-patched Windows 2008 R2 server though, the rest of the prerequisites seem OK; so this function only deals with KB974405 (Windows Identity Foundation).
    # Thanks to Ravikanth Chaganti (@ravikanth) for describing the issue, and working around it so effectively: http://www.ravichaganti.com/blog/?p=1888
    If ($password) {$credential = New-Object System.Management.Automation.PsCredential $env:USERDOMAIN\$env:USERNAME,$(ConvertTo-SecureString $password)}
    If (!$credential) {$credential = $host.ui.PromptForCredential("AutoSPInstaller - Remote Install", "Re-Enter Credentials for Remote Authentication:", "$env:USERDOMAIN\$env:USERNAME", "NetBiosUserName")}
    If ($session.Name -ne "AutoSPInstallerSession-$server")
    {
        log " - Starting remote session to $server..."
        $session = New-PSSession -Name "AutoSPInstallerSession-$server" -Authentication Credssp -Credential $credential -ComputerName $server
    }
    $remoteQueryOS = Invoke-Command -ScriptBlock {Get-WmiObject Win32_OperatingSystem} -Session $session
	If (!($remoteQueryOS.Version.Contains("6.2")) -and !($remoteQueryOS.Version.Contains("6.3"))) # Only perform the stuff below if we aren't on Windows 2012 or 2012 R2
	{
	    log " - Checking for KB974405 (Windows Identity Foundation)..." 
	    $wifHotfixInstalled = Invoke-Command -ScriptBlock {Get-HotFix -Id KB974405 -ErrorAction SilentlyContinue} -Session $session
	    If ($wifHotfixInstalled)
	    {
	        log "already installed."
	    }
	    Else
	    {
	        log "needed."
	        $username = $credential.UserName
	        $password = ConvertTo-PlainText $credential.Password
	        If ($remoteQueryOS.Version.Contains("6.1"))
	        {
	            $wifHotfix = "Windows6.1-KB974405-x64.msu"
	        }
	        ElseIf ($remoteQueryOS.Version.Contains("6.0"))
	        {
	            $wifHotfix = "Windows6.0-KB974405-x64.msu"
	        }
	        Else {log "Could not detect OS of `"$server`", or unsupported OS."}
	        If (!(Get-Item $env:SPbits\PrerequisiteInstallerFiles\$wifHotfix -ErrorAction SilentlyContinue))
	        {
	            log " - Windows Identity Foundation KB974405 not found in $env:SPbits\PrerequisiteInstallerFiles"
	            log " - Attempting to download..."
	            $wifURL = "http://download.microsoft.com/download/D/7/2/D72FD747-69B6-40B7-875B-C2B40A6B2BDD/$wifHotfix"
	            Import-Module BitsTransfer | Out-Null
	            Start-BitsTransfer -Source $wifURL -Destination "$env:SPbits\PrerequisiteInstallerFiles\$wifHotfix" -DisplayName "Downloading `'$wifHotfix`' to $env:SPbits\PrerequisiteInstallerFiles" -Priority Foreground -Description "From $wifURL..." -ErrorVariable err
	            if ($err) 
                {
                    Throw " - Could not download from $wifURL!"; 
                    # MK: commented
                    # Pause "exit";
                    break
                }
	        }
	        $psExec = $env:dp0+"\PsExec.exe"
	        If (!(Get-Item ($psExec) -ErrorAction SilentlyContinue))
	        {
	            log " - PsExec.exe not found; downloading..."
	            $psExecUrl = "http://live.sysinternals.com/PsExec.exe"
	            Import-Module BitsTransfer | Out-Null
	            Start-BitsTransfer -Source $psExecUrl -Destination $psExec -DisplayName "Downloading Sysinternals PsExec..." -Priority Foreground -Description "From $psExecUrl..." -ErrorVariable err
	            If ($err) 
                {
                    log "Could not download PsExec!"; 
                    # MK: commented
                    # Pause "exit";
                    break
                }
	            $sourceFile = $destinationFile
	        }
	        log " - Pre-installing Windows Identity Foundation on `"$server`" via PsExec..."
	        Start-Process -FilePath "$psExec" `
	                      -ArgumentList "/acceptEula \\$server -u $username -p $password -h wusa.exe `"$env:SPbits\PrerequisiteInstallerFiles\$wifHotfix`" /quiet /norestart" `
	                      -Wait -NoNewWindow
	    }
	}
}

Function Start-RemoteInstaller ($server, $password, $inputFile)
{
    If ($password) {$credential = New-Object System.Management.Automation.PsCredential $env:USERDOMAIN\$env:USERNAME,$(ConvertTo-SecureString $password)}
    If (!$credential) {$credential = $host.ui.PromptForCredential("AutoSPInstaller - Remote Install", "Re-Enter Credentials for Remote Authentication:", "$env:USERDOMAIN\$env:USERNAME", "NetBiosUserName")}
    If ($session.Name -ne "AutoSPInstallerSession-$server")
    {
        log " - Starting remote session to $server..."
        $session = New-PSSession -Name "AutoSPInstallerSession-$server" -Authentication Credssp -Credential $credential -ComputerName $server
    }
    Get-MajorVersionNumber $xmlinput
    # Create a hash table with major version to product year mappings
    $spYears = @{"14" = "2010"; "15" = "2013"}
    $spYear = $spYears.$env:spVer
    # Set some remote variables that we will need...
    Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name dp0 -Value $value} -ArgumentList $env:dp0 -Session $session
    Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name InputFile -Value $value} -ArgumentList $inputFile -Session $session
    Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name spVer -Value $value} -ArgumentList $env:spVer -Session $session
    # Crude way of checking if SharePoint is already installed
    $spInstalledOnRemote = Invoke-Command -ScriptBlock {Test-Path "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$spVer\BIN\stsadm.exe"} -Session $session
    log " - SharePoint $spYear binaries are"($spInstalledOnRemote -replace "True","already" -replace "False","not yet") "installed on $server."
    log " - Launching AutoSPInstaller..."
    Invoke-Command -ScriptBlock {& "$dp0\AutoSPInstallerMain.ps1" "$inputFile"} -Session $session
    log " - Removing session `"$($session.Name)...`""
    Remove-PSSession $session
}

# ====================================================================================
# Func: Confirm-LocalSession
# Desc: Returns $false if we are running over a PS remote session, $true otherwise
# From: Brian Lalancette, 2012
# ====================================================================================

Function Confirm-LocalSession
{
    # Another way
    # If ((Get-Process -Id $PID).ProcessName -eq "wsmprovhost") {Return $false}
    If ($Host.Name -eq "ServerRemoteHost") {Return $false}
    Else {Return $true}
}

#EndRegion

#Region Miscellaneous/Utility Functions
#Region Load Snapins
# ===================================================================================
# Func: Load SharePoint PowerShell Snapin
# Desc: Load SharePoint PowerShell Snapin
# ===================================================================================
Function Load-SharePoint-PowerShell
{
    If ((Get-PsSnapin |?{$_.Name -eq "Microsoft.SharePoint.PowerShell"})-eq $null)
    {
        WriteLine
        log " - Loading SharePoint PowerShell Snapin..."
        # Added the line below to match what the SharePoint.ps1 file implements (normally called via the SharePoint Management Shell Start Menu shortcut)
        If (Confirm-LocalSession) {$Host.Runspace.ThreadOptions = "ReuseThread"}
        Add-PsSnapin Microsoft.SharePoint.PowerShell -ErrorAction Stop | Out-Null
        WriteLine
    }
}
# ====================================================================================
# Func: ImportWebAdministration
# Desc: Load IIS WebAdministration Snapin/Module
# From: Inspired by http://stackoverflow.com/questions/1924217/powershell-load-webadministration-in-ps1-script-on-both-iis-7-and-iis-7-5
# ====================================================================================
Function ImportWebAdministration
{
    $queryOS = Gwmi Win32_OperatingSystem
    $queryOS = $queryOS.Version
    Try
    {
        If ($queryOS.Contains("6.0")) # Win2008
        {
            If (!(Get-PSSnapin WebAdministration -ErrorAction SilentlyContinue))
            {
                If (!(Test-Path $env:ProgramFiles\IIS\PowerShellSnapin\IIsConsole.psc1))
                {
                    Start-Process -Wait -NoNewWindow -FilePath msiexec.exe -ArgumentList "/i `"$env:SPbits\PrerequisiteInstallerFiles\iis7psprov_x64.msi`" /passive /promptrestart"
                }
                Add-PSSnapin WebAdministration
            }
        }
        Else # Win2008R2 or Win2012
        {
            Import-Module WebAdministration
        }
    }
    Catch
    {
        Throw " - Could not load IIS Administration module."

    }
}
#EndRegion

#Region ConvertTo-PlainText
# ===================================================================================
# Func: ConvertTo-PlainText
# Desc: Convert string to secure phrase
#       Used (for example) to get the Farm Account password into plain text as input to provision the User Profile Sync Service
#       From http://www.vistax64.com/powershell/159190-read-host-assecurestring-problem.html
# ===================================================================================
Function ConvertTo-PlainText( [security.securestring]$secure )
{
    $marshal = [Runtime.InteropServices.Marshal]
    $marshal::PtrToStringAuto( $marshal::SecureStringToBSTR($secure) )
}
#EndRegion

#Region ShouldIProvision
# ===================================================================================
# Func: ShouldIProvision
# Desc: Returns TRUE if the item whose configuration node is passed in should be provisioned.
#       on this machine.
#       This function supports wildcard computernames.   Computernames specified in the
#       AutoSpInstallerInput.xml may contain either a single * character
#	    to do a wildcard match or may contain one or more # characters to match an integer.
#       Using wildcard computer names is not compatible with remote installation.
#
#	Examples:   WFE* would match computers named WFE-foo, WFEbar, etc.
#				WFE## would match WFE01, WFE02, but not WFE1
# ===================================================================================
Function ShouldIProvision([System.Xml.XmlNode] $node)
{
    If (!$node) {Return $false} # In case the node doesn't exist in the XML file
    # Allow for comma- or space-delimited list of server names in Provision or Start attribute
    If ($node.GetAttribute("Provision")) {$v = $node.GetAttribute("Provision").Replace(","," ")}
    ElseIf ($node.GetAttribute("Start")) {$v = $node.GetAttribute("Start").Replace(","," ")}
    ElseIf ($node.GetAttribute("Install")) {$v = $node.GetAttribute("Install").Replace(","," ")}
    If ($v -eq $true) { Return $true; }
    Return MatchComputerName $v $env:COMPUTERNAME
}
#EndRegion

#Region SQL Stuff
# ====================================================================================
# Func: Add-SQLAlias
# Desc: Creates a local SQL alias (like using cliconfg.exe) so the real SQL server/name doesn't get hard-coded in SharePoint
#       if local database server is being used, then use Shared Memory protocol
# From: Bill Brockbank, SharePoint MVP (billb@navantis.com)
# ====================================================================================

Function Add-SQLAlias()
{
    <#
    .Synopsis
        Add a new SQL server Alias
    .Description
        Adds a new SQL server Alias with the provided parameters.
    .Example
                Add-SQLAlias -AliasName "SharePointDB" -SQLInstance $env:COMPUTERNAME
    .Example
                Add-SQLAlias -AliasName "SharePointDB" -SQLInstance $env:COMPUTERNAME -Port '1433'
    .Parameter AliasName
        The new alias Name.
    .Parameter SQLInstance
                The SQL server Name os Instance Name
    .Parameter Port
        Port number of SQL server instance. This is an optional parameter.
    #>
    [CmdletBinding(DefaultParameterSetName="BuildPath+SetupInfo")]
    param
    (
        [Parameter(Mandatory=$false, ParameterSetName="BuildPath+SetupInfo")][ValidateNotNullOrEmpty()]
        [String]$aliasName = "SharePointDB",

        [Parameter(Mandatory=$false, ParameterSetName="BuildPath+SetupInfo")][ValidateNotNullOrEmpty()]
        [String]$SQLInstance = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false, ParameterSetName="BuildPath+SetupInfo")][ValidateNotNullOrEmpty()]
        [String]$port = ""
    )

	If ((MatchComputerName $SQLInstance $env:COMPUTERNAME) -or ($SQLInstance.StartsWith($env:ComputerName +"\"))) {
		$protocol = "dbmslpcn" # Shared Memory
	}
	else {
		$protocol = "DBMSSOCN" # TCP/IP
	}

    $serverAliasConnection="$protocol,$SQLInstance"
    If ($port -ne "")
    {
         $serverAliasConnection += ",$port"
    }
    $notExist = $true
    $client = Get-Item 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client' -ErrorAction SilentlyContinue
    # Create the key in case it doesn't yet exist
    If (!$client) {$client = New-Item 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client' -Force}
    $client.GetSubKeyNames() | ForEach-Object -Process { If ( $_ -eq 'ConnectTo') { $notExist=$false }}
    If ($notExist)
    {
        $data = New-Item 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo'
    }
    # Add Alias
    $data = New-ItemProperty HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo -Name $aliasName -Value $serverAliasConnection -PropertyType "String" -Force -ErrorAction SilentlyContinue
}

# ====================================================================================
# Func: CheckSQLAccess
# Desc: Checks if the install account has the correct SQL database access and permissions
# By:   Sameer Dhoot (http://sharemypoint.in/about/sameerdhoot/)
# From: http://sharemypoint.in/2011/04/18/powershell-script-to-check-sql-server-connectivity-version-custering-status-user-permissions/
# Adapted for use in AutoSPInstaller by @brianlala
# ====================================================================================
Function CheckSQLAccess
{
    WriteLine
    # Look for references to DB Servers, Aliases, etc. in the XML
    ForEach ($node in $xmlinput.SelectNodes("//*[DBServer]|//*[@DatabaseServer]|//*[@FailoverDatabaseServer]"))
    {
        $dbServer = (GetFromNode $node "DBServer")
        If ($node.DatabaseServer) {$dbServer = GetFromNode $node "DatabaseServer"}
        # If the DBServer has been specified, and we've asked to set up an alias, create one
        If (!([string]::IsNullOrEmpty($dbServer)) -and ($node.DBAlias.Create -eq $true))
        {
            $dbInstance = GetFromNode $node.DBAlias "DBInstance"
            $dbPort = GetFromNode $node.DBAlias "DBPort"
            # If no DBInstance has been specified, but Create="$true", set the Alias to the server value
            If (($dbInstance -eq $null) -and ($dbInstance -ne "")) {$dbInstance = $dbServer}
            If (($dbPort -ne $null) -and ($dbPort -ne ""))
            {
                log " - Creating SQL alias `"$dbServer,$dbPort`"..."
                Add-SQLAlias -AliasName $dbServer -SQLInstance $dbInstance -Port $dbPort
            }
            Else # Create the alias without specifying the port (use default)
            {
                log " - Creating SQL alias `"$dbServer`"..."
                Add-SQLAlias -AliasName $dbServer -SQLInstance $dbInstance
            }
        }
        $dbServers += @($dbServer)
    }

    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
    $serverRolesToCheck = "dbcreator","securityadmin"
    # If we are provisioning PerformancePoint but aren't running SharePoint 2010 Service Pack 1 yet, we need sysadmin in order to run the RenameDatabase function
    # We also evidently need sysadmin in order to configure MaxDOP on the SQL instance if we are installing SharePoint 2013
    If (($xmlinput.Configuration.EnterpriseServiceApps.PerformancePointService) -and (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.PerformancePointService -eq $true) -and (!(CheckFor2010SP1)))
    {
        $serverRolesToCheck += "sysadmin"
    }

    ForEach ($sqlServer in ($dbServers | Select-Object -Unique))
    {
        If ($sqlServer) # Only check the SQL instance if it has a value
        {
            $objSQLConnection = New-Object System.Data.SqlClient.SqlConnection
            $objSQLCommand = New-Object System.Data.SqlClient.SqlCommand
            Try
            {
                $objSQLConnection.ConnectionString = "Server=$sqlServer;Integrated Security=SSPI;"
                log " - Testing access to SQL server/instance/alias:" $sqlServer
                log " - Trying to connect to `"$sqlServer`"..." 
                $objSQLConnection.Open() | Out-Null
                log "Success"
                $strCmdSvrDetails = "SELECT SERVERPROPERTY('productversion') as Version"
                $strCmdSvrDetails += ",SERVERPROPERTY('IsClustered') as Clustering"
                $objSQLCommand.CommandText = $strCmdSvrDetails
                $objSQLCommand.Connection = $objSQLConnection
                $objSQLDataReader = $objSQLCommand.ExecuteReader()
                If ($objSQLDataReader.Read())
                {
                    log (" - SQL Server version is: {0}" -f $objSQLDataReader.GetValue(0))
                    $SQLVersion = $objSQLDataReader.GetValue(0)
                    [int]$SQLMajorVersion,[int]$SQLMinorVersion,[int]$SQLBuild,$null = $SQLVersion -split "\."
                    # SharePoint needs minimum SQL 2008 10.0.2714.0 or SQL 2005 9.0.4220.0 per http://support.microsoft.com/kb/976215
                    If ((($SQLMajorVersion -eq 10) -and ($SQLMinorVersion -lt 5) -and ($SQLBuild -lt 2714)) -or (($SQLMajorVersion -eq 9) -and ($SQLBuild -lt 4220)))
                    {
                        Throw " - Unsupported SQL version!"
                    }
                    If ($objSQLDataReader.GetValue(1) -eq 1)
                    {
                        log " - This instance of SQL Server is clustered"
                    }
                    Else
                    {
                        log " - This instance of SQL Server is not clustered"
                    }
                }
                $objSQLDataReader.Close()
                ForEach($serverRole in $serverRolesToCheck)
                {
                    $objSQLCommand.CommandText = "SELECT IS_SRVROLEMEMBER('$serverRole')"
                    $objSQLCommand.Connection = $objSQLConnection
                    log " - Check if $currentUser has $serverRole server role..." 
                    $objSQLDataReader = $objSQLCommand.ExecuteReader()
                    If ($objSQLDataReader.Read() -and $objSQLDataReader.GetValue(0) -eq 1)
                    {
                        log "Pass"
                    }
                    ElseIf($objSQLDataReader.GetValue(0) -eq 0)
                    {
                        Throw " - $currentUser does not have `'$serverRole`' role!"
                    }
                    Else
                    {
                        log "Invalid Role"
                    }
                    $objSQLDataReader.Close()
                }
                $objSQLConnection.Close()
            }
            Catch
            {
                log " - Fail"
                $errText = $error[0].ToString()
                If ($errText.Contains("network-related"))
                {
                    #log "Connection Error. Check server name, port, firewall."
                    #log " - This may be expected if e.g. SQL server isn't installed yet, and you are just installing SharePoint binaries for now."
                    # Pause "continue without checking SQL Server connection, or Ctrl-C to exit" "y"
                    # MK: replace pause with throw
                    Throw "ERROR: SQL Connection Error. Check server name, port, firewall."
                }
                ElseIf ($errText.Contains("Login failed"))
                {
                    Throw " - Not able to login. SQL Server login not created."
                }
                ElseIf ($errText.Contains("Unsupported SQL version"))
                {
                    Throw " - SharePoint 2010 requires SQL 2005 SP3+CU3, SQL 2008 SP1+CU2, or SQL 2008 R2."
                }
                Else
                {
                    If (!([string]::IsNullOrEmpty($serverRole)))
                    {
                        Throw " - $currentUser does not have `'$serverRole`' role!"
                    }
                    Else {Throw " - $errText"}
                }
            }
        }
    }
    WriteLine
}

# ====================================================================================
# Func: RenameDatabase()
# Desc: Renames a SQL database and the database files
# ====================================================================================
Function RenameDatabase([string]$sqlServer,[string]$oldName,[string]$newName)
{
    $objSQLConnection = New-Object System.Data.SqlClient.SqlConnection
    $objSQLCommand = New-Object System.Data.SqlClient.SqlCommand
    $objSQLConnection.ConnectionString = "Server=$sqlServer;Integrated Security=SSPI;"
    $objSQLConnection.Open() | Out-Null
    $strCmdSvrDetails = @"
EXEC ('
declare @oldname nvarchar(4000)
declare @newname nvarchar(4000)
set @oldname=''$oldName''
set @newname=''$newName''
EXEC sp_configure ''show advanced options'', 1
RECONFIGURE
create table #opt ( name sysname, minimum int, maximum int,config_value int, run_value int)
insert into #opt exec sp_configure ''xp_cmdshell''
DECLARE @oldcmdshell int
SELECT @oldcmdshell = config_value FROM #opt
EXEC sp_configure ''xp_cmdshell'', 1
RECONFIGURE
declare @datapath nvarchar(4000)
declare @logpath nvarchar(4000)
declare @dataname nvarchar(4000)
declare @logname nvarchar(4000)
select @datapath = replace(physical_name,@oldname + ''.mdf'',''''), @dataname=Name from master.sys.master_files where type=0 and database_id = DB_ID(@oldname)
select @logpath = replace(physical_name,@oldname + ''_log.ldf'',''''), @logname=Name from master.sys.master_files where type=1 and database_id = DB_ID(@oldname)
EXEC (''ALTER DATABASE ['' + @oldname + ''] SET SINGLE_USER WITH ROLLBACK IMMEDIATE'')
EXEC (''ALTER DATABASE ['' + @oldname + ''] MODIFY NAME = ['' + @newname + '']'')
EXEC (''ALTER DATABASE ['' + @newname + ''] MODIFY FILE (
    NAME=N'''''' + @dataname + '''''',
    NEWNAME=N'''''' + @newname + '''''',
    FILENAME=N'''''' + @datapath + @newname + ''.mdf'''')'')
EXEC (''ALTER DATABASE ['' + @newname + ''] MODIFY FILE (
    NAME=N'''''' + @logname + '''''',
    NEWNAME=N'''''' + @newname + ''_log'''',
    FILENAME=N'''''' + @logpath + @newname + ''_log.ldf'''')'')
EXEC (''ALTER DATABASE ['' + @newname + ''] SET OFFLINE'')
EXEC (''EXEC xp_cmdshell ''''RENAME "'' + @datapath + @dataname + ''.mdf", "'' + @newname + ''.mdf"'''''')
EXEC (''EXEC xp_cmdshell ''''RENAME "'' + @logpath + @logname + ''.ldf", "'' + @newname + ''_log.ldf"'''''')
EXEC (''ALTER DATABASE ['' + @newname + ''] SET ONLINE'')
EXEC (''ALTER DATABASE ['' + @newname + ''] SET MULTI_USER WITH ROLLBACK IMMEDIATE'')
EXEC sp_configure ''xp_cmdshell'',@oldcmdshell
RECONFIGURE
drop table #opt
')
"@

    $objSQLCommand.CommandText = $strCmdSvrDetails
    $objSQLCommand.Connection = $objSQLConnection
    $objSQLCommand.ExecuteNonQuery()
    $objSQLConnection.Close()
}
#EndRegion

#Region Run-HealthAnalyzerJobs
# ====================================================================================
# Func: Run-HealthAnalyzerJobs
# Desc: Runs all Health Analyzer Timer Jobs Immediately
# From: http://www.sharepointconfig.com/2011/01/instant-sharepoint-health-analysis/
# ====================================================================================
Function Run-HealthAnalyzerJobs
{
    $healthJobs = Get-SPTimerJob | Where {$_.Name -match "health-analysis-job"}
    log " - Running all Health Analyzer jobs..."
    ForEach ($job in $healthJobs)
    {
        $job.RunNow()
    }
}
#EndRegion

#Region InstallSMTP
# ====================================================================================
# Func: InstallSMTP
# Desc: Installs the SMTP Server Windows feature
# ====================================================================================
Function InstallSMTP([xml]$xmlinput)
{
    If (ShouldIProvision $xmlinput.Configuration.Farm.Services.SMTP -eq $true)
    {
        WriteLine
        log " - Installing SMTP Server feature..."
        $queryOS = Gwmi Win32_OperatingSystem
        $queryOS = $queryOS.Version
        If ($queryOS.Contains("6.0")) # Win2008
        {
            Start-Process -FilePath servermanagercmd.exe -ArgumentList "-install smtp-server" -Wait -NoNewWindow
        }
        Else # Win2008 or Win2012
        {
            # Get the current progress preference
            $pref = $ProgressPreference
            # Hide the progress bar since it tends to not disappear
            $ProgressPreference = "SilentlyContinue"
            Import-Module ServerManager
            Add-WindowsFeature -Name SMTP-Server | Out-Null
            # Restore progress preference
            $ProgressPreference = $pref
            If (!$?) {Throw " - Failed to install SMTP Server!"}
            else
            {
                # Need to set the newly-installed service to Automatic since it is set to Manual by default (per https://autospinstaller.codeplex.com/workitem/19744)
                log "  - Setting SMTP service startup type to Automatic..."
                Set-Service SMTPSVC -StartupType Automatic -ErrorAction SilentlyContinue
            }
        }
        log " - Done."
        WriteLine
    }
}
#EndRegion

#Region FixTaxonomyPickerBug
# ====================================================================================
# Func: FixTaxonomyPickerBug
# Desc: Renames the TaxonomyPicker.ascx file which doesn't seem to be used anyhow
# Desc: Goes one step further than the fix suggested in http://support.microsoft.com/kb/2481844 (which doesn't work at all)
# ====================================================================================
Function FixTaxonomyPickerBug
{
    $taxonomyPicker = "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\TEMPLATE\CONTROLTEMPLATES\TaxonomyPicker.ascx"
    If (Test-Path $taxonomyPicker)
    {
        WriteLine
        log " - Renaming TaxonomyPicker.ascx..."
        Move-Item -Path $taxonomyPicker -Destination $taxonomyPicker".buggy" -Force
        log " - Done."
        WriteLine
    }
}
#EndRegion

#Region Miscellaneous Checks
# ====================================================================================
# Func: CheckFor2010SP1
# Desc: Returns $true if the SharePoint 2010 farm build number or SharePoint DLL is at Service Pack 1 (6029) or greater (or if slipstreamed SP1 is detected); otherwise returns $false
# Desc: Helps to determine whether certain new/updated cmdlets are available
# ====================================================================================
Function CheckFor2010SP1
{
    If (Get-Command Get-SPFarm -ErrorAction SilentlyContinue)
    {
        # Try to get the version of the farm first
        $build = (Get-SPFarm).BuildVersion.Build
        If (!($build)) # Get the ProductVersion of a SharePoint DLL instead, since the farm doesn't seem to exist yet
        {
            $spProdVer = (Get-Command $env:CommonProgramFiles"\Microsoft Shared\Web Server Extensions\$env:spVer\isapi\microsoft.sharepoint.portal.dll").FileVersionInfo.ProductVersion
            $null,$null,[int]$build,$null = $spProdVer -split "\."
        }
        If ($build -ge 6029 -or $env:spVer -eq "15") # SP2010 SP1, or SP2013
        {
            Return $true
        }
    }
    # SharePoint probably isn't installed yet, so try to see if we have slipstreamed SP1 in the \Updates folder at least...
    ElseIf (Get-Item "$env:SPbits\Updates\oserversp1-x-none.msp" -ErrorAction SilentlyContinue)
    {
        Return $true
    }
    Else
    {
        Return $false
    }
}

# ====================================================================================
# Func: CheckFor2013SP1
# Desc: Returns $true if the SharePoint 2013 farm build number or SharePoint prerequisiteinstaller.exe is at Service Pack 1 (4569 or 4567, respectively) or greater; otherwise returns $false
# ====================================================================================
Function CheckFor2013SP1
{
    if ($env:spVer -eq "15")
    {
        If (Get-Command Get-SPFarm -ErrorAction SilentlyContinue)
        {
            # Try to get the version of the farm first
            $build = (Get-SPFarm).BuildVersion.Build
            If (!($build)) # Get the ProductVersion of a SharePoint DLL instead, since the farm doesn't seem to exist yet
            {
                $spProdVer = (Get-Command $env:CommonProgramFiles"\Microsoft Shared\Web Server Extensions\$env:spVer\isapi\microsoft.sharepoint.portal.dll").FileVersionInfo.ProductVersion
                $null,$null,[int]$build,$null = $spProdVer -split "\."
            }
            If ($build -ge 4569) # SP2013 SP1
            {
                Return $true
            }
        }
        # SharePoint probably isn't installed yet, so try to determine version of prerequisiteinstaller.exe...
        ElseIf (Get-Item "$env:SPbits\prerequisiteinstaller.exe" -ErrorAction SilentlyContinue)
        {
            $preReqInstallerVer = (Get-Command "$env:SPbits\prerequisiteinstaller.exe").FileVersionInfo.ProductVersion
            $null,$null,[int]$build,$null = $preReqInstallerVer -split "\."
            If ($build -ge 4567) # SP2013 SP1
            {
                Return $true
            }
        }
        Else
        {
            Return $false
        }
    }
    else
    {
        Return $false
    }
}

# ====================================================================================
# Func: CheckIfUpgradeNeeded
# Desc: Returns $true if the server or farm requires an upgrade (i.e. requires PSConfig or the corresponding PowerShell commands to be run)
# ====================================================================================
Function CheckIfUpgradeNeeded
{
    $setupType = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\$env:spVer.0\WSS\").GetValue("SetupType")
    If ($setupType -ne "CLEAN_INSTALL") # For example, if the value is "B2B_UPGRADE"
    {
        Return $true
    }
    Else
    {
        Return $false
    }
}

Function Get-SharePointInstall
{
    # Crude way of checking if SharePoint is already installed
    If (Test-Path "$env:CommonProgramFiles\Microsoft Shared\Web Server Extensions\$env:spVer\BIN\stsadm.exe")
    {
        return $true
    }
    Else {return $false}
}

# ===================================================================================
# Func: MatchComputerName
# Desc: Returns TRUE if the $computerName specified matches one of the items in $computersList.
#		Supports wildcard matching (# for a a number, * for any non whitepace character)
# ===================================================================================
Function MatchComputerName($computersList, $computerName)
{
	If ($computersList -like "*$computerName*") { Return $true; }
    foreach ($v in $computersList) {
      If ($v.Contains("*") -or $v.Contains("#")) {
            # wildcard processing
            foreach ($item in -split $v) {
                $item = $item -replace "#", "[\d]"
                $item = $item -replace "\*", "[\S]*"
                if ($computerName -match $item) {return $true;}
            }
        }
    }
}
Function GetFromNode([System.Xml.XmlElement]$node, [string] $item)
{
    $value = $node.GetAttribute($item)
    If ($value -eq "")
    {
        $child = $node.SelectSingleNode($item);
        If ($child -ne $null)
        {
            Return $child.InnerText;
        }
    }
    Return $value;
}

#EndRegion

#Region Manage HOSTS & URLs
# ====================================================================================
# Func: AddToHOSTS
# Desc: This writes URLs to the server's local hosts file and points them to the server itself
# From: Check http://toddklindt.com/loopback for more information
# Copyright Todd Klindt 2011
# Originally published to http://www.toddklindt.com/blog
# ====================================================================================
Function AddToHOSTS ($hosts)
{
    log " - Adding HOSTS file entries for local resolution..."
    # Make backup copy of the Hosts file with today's date
    $hostsfile = "$env:windir\System32\drivers\etc\HOSTS"
    $date = Get-Date -UFormat "%y%m%d%H%M%S"
    $filecopy = $hostsfile + '.' + $date + '.copy'
    log "  - Backing up HOSTS file to:"
    log "  - $filecopy"
    Copy-Item $hostsfile -Destination $filecopy

    if (!$hosts) # No hosts were passed as arguments, so look at the AAMs in the farm
    {
        # Get a list of the AAMs and weed out the duplicates
        $hosts = Get-SPAlternateURL | ForEach-Object {$_.incomingurl.replace("https://","").replace("http://","")} | where-Object { $_.tostring() -notlike "*:*" } | Select-Object -Unique
    }

    # Get the contents of the Hosts file
    $file = Get-Content $hostsfile
    $file = $file | Out-String

    # Write the AAMs to the hosts file, UNLESS they already exist, are "localhost" or happen to match the local computer name.
    ForEach ($hostname in $hosts)
    {
        # Get rid of any path information that may have snuck in here
        $hostname,$null = $hostname -split "/" -replace ("localhost", $env:COMPUTERNAME)
        if (($file -match " $hostname") -or ($file -match "`t$hostname")) # Added check for a space or tab character before the hostname for better exact matching, also used -match for case-insensitivity
        {log "  - HOSTS file entry for `"$hostname`" already exists - skipping."}
        elseif ($hostname -eq "$env:Computername" -or $hostname -eq "$env:Computername.$env:USERDNSDOMAIN")
        {log "  - HOSTS file entry for `"$hostname`" matches local computer name - skipping."}
        else
        {
            log "  - Adding HOSTS file entry for `"$hostname`"..."
            Add-Content -Path $hostsfile -Value "`r"
            Add-Content -Path $hostsfile -value "127.0.0.1 `t $hostname`t# Added by AutoSPInstaller to locally resolve SharePoint URLs back to this server"
            $keepHOSTSCopy = $true
        }
    }
    If (!$keepHOSTSCopy)
    {
        log "  - Deleting HOSTS backup file since no changes were made..."
        Remove-Item $filecopy
    }
    log " - Done with HOSTS file."
}
# ====================================================================================
# Func: Add-LocalIntranetURL
# Desc: Adds a URL to the local Intranet zone (Internet Control Panel) to allow pass-through authentication in Internet Explorer (avoid prompts)
# ====================================================================================
Function Add-LocalIntranetURL ($url)
{
    If (($url -like "*.*") -and (($webApp.AddURLToLocalIntranetZone) -eq $true))
    {
        # Strip out any protocol value
        $url = $url -replace "http://","" -replace "https://",""
        $splitURL = $url -split "\."
        # Thanks to CodePlex user Eulenspiegel for the updates $urlDomain syntax (https://autospinstaller.codeplex.com/workitem/20486)
        $urlDomain = $url.Substring($splitURL[0].Length + 1)
        log " - Adding *.$urlDomain to local Intranet security zone..."
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Name $urlDomain -ItemType Leaf -Force | Out-Null
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$urlDomain" -Name '*' -value "1" -PropertyType dword -Force | Out-Null
    }
}
#EndRegion

#Region File System Functions
# ====================================================================================
# Func: CompressFolder
# Desc: Enables NTFS compression for a given folder
# From: Based on concepts & code found at http://www.humanstuff.com/2010/6/24/how-to-compress-a-file-using-powershell
# ====================================================================================
Function CompressFolder ($folder)
{
    # Replace \ with \\ for WMI
    $wmiPath = $folder.Replace("\","\\")
    $wmiDirectory = Get-WmiObject -Class "Win32_Directory" -Namespace "root\cimv2" -ComputerName $env:COMPUTERNAME -Filter "Name='$wmiPath'"
    # Check if folder is already compressed
    If (!($wmiDirectory.Compressed))
    {
        log " - Compressing $folder and subfolders..."
        $compress = $wmiDirectory.CompressEx("","True")
    }
    Else {log " - $folder is already compressed."}
}

# ====================================================================================
# Func: EnsureFolder
# Desc: Checks for the existence and validity of a given path, and attempts to create if it doesn't exist.
# From: Modified from patch 9833 at http://autospinstaller.codeplex.com/SourceControl/list/patches by user timiun
# ====================================================================================
Function EnsureFolder ($path)
{
        If (!(Test-Path -Path $path -PathType Container))
        {
            log " - $path doesn't exist; creating..."
            Try
            {
                New-Item -Path $path -ItemType Directory | Out-Null
            }
            Catch
            {
                log "$($_.Exception.Message)"
                Throw " - Could not create folder $path!"
            }
        }
}
#EndRegion

#Region Trivial Functions
# ===================================================================================
# Func: Pause
# Desc: Wait for user to press a key - normally used after an error has occured or input is required
# ===================================================================================
Function Pause($action, $key)
{
    # From http://www.microsoft.com/technet/scriptcenter/resources/pstips/jan08/pstip0118.mspx
    if ($key -eq "any" -or ([string]::IsNullOrEmpty($key)))
    {
        $actionString = "Press any key to $action..."
        if (-not $unattended)
        {
            log $actionString
            $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        else
        {
            log "Skipping pause due to -unattended switch: $actionString"
        }
    }
    else
    {
        $actionString = "Enter `"$key`" to $action"
        $continue = Read-Host -Prompt $actionString
        if ($continue -ne $key) {pause $action $key}

    }
}

# ====================================================================================
# Func: WriteLine
# Desc: Writes a nice line of dashes across the screen
# ====================================================================================
Function WriteLine
{
    log "--------------------------------------------------------------"
}

# ====================================================================================
# Func: Show-Progress
# Desc: Shows a row of dots to let us know that $process is still running
# From: Brian Lalancette, 2012
# ====================================================================================
Function Show-Progress ($process, $color, $interval)
{
    While (Get-Process -Name $process -ErrorAction SilentlyContinue)
    {
        log "."
        Start-Sleep $interval
    }
    log "Done."
}

# ====================================================================================
# Func: Get-DBPrefix
# Desc: Returns the database prefix for the farm
# From: Brian Lalancette, 2014
# ====================================================================================
Function Get-DBPrefix ([xml]$xmlinput)
{
    $dbPrefix = $xmlinput.Configuration.Farm.Database.DBPrefix
    If (($dbPrefix -ne "") -and ($dbPrefix -ne $null)) {$dbPrefix += "_"}
    If ($dbPrefix -like "*localhost*") {$dbPrefix = $dbPrefix -replace "localhost","$env:COMPUTERNAME"}
    return $dbPrefix
}
#EndRegion

#Region Security-Related
# ====================================================================================
# Func: Get-AdministratorsGroup
# Desc: Returns the actual (localized) name of the built-in Administrators group
# From: Proposed by Codeplex user Sheppounet at http://autospinstaller.codeplex.com/discussions/265749
# ====================================================================================
Function Get-AdministratorsGroup
{
    If(!$builtinAdminGroup)
    {
        $builtinAdminGroup = (Get-WmiObject -Class Win32_Group -computername $env:COMPUTERNAME -Filter "SID='S-1-5-32-544' AND LocalAccount='True'" -errorAction "Stop").Name
    }
    Return $builtinAdminGroup
}

# ====================================================================================
# Func: Set-UserAccountControl
# Desc: Enables or disables User Account Control (UAC), using a 1 or a 0 (respectively) passed as a parameter
# From: Brian Lalancette, 2012
# ====================================================================================
Function Set-UserAccountControl ($flag)
{
    $regUAC = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\policies\system").GetValue("EnableLUA")
    if ($flag -eq $regUAC)
    {
        log " - User Account Control is already" $($regUAC -replace "1","enabled." -replace "0","disabled.")
    }
    else
    {
        if ($regUAC -eq 1)
        {
            New-Item -Path "HKLM:\SOFTWARE\AutoSPInstaller\" -ErrorAction SilentlyContinue | Out-Null
			$regKey = Get-Item -Path "HKLM:\SOFTWARE\AutoSPInstaller\"
            $regKey | New-ItemProperty -Name "UACWasEnabled" -PropertyType String -Value "1" -Force | Out-Null
        }
        log " - $($flag -replace "1","Re-enabling" -replace "0","Disabling") User Account Control (effective upon restart)..."
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\policies\system" -Name EnableLUA -Value $flag
    }
}

# ====================================================================================
# Func: userExists
# Desc: "Here is a little powershell function I made to see check if specific active directory users exists or not."
# From: http://oyvindnilsen.com/powershell-function-to-check-if-active-directory-users-exists/
# ====================================================================================
function userExists ([string]$name)
{
    #written by: Øyvind Nilsen (oyvindnilsen.com)
    [bool]$ret = $false #return variable
    $domainRoot = [ADSI]''
    $dirSearcher = New-Object System.DirectoryServices.DirectorySearcher($domainRoot)
    $dirSearcher.filter = "(&(objectClass=user)(sAMAccountName=$name))"
    $results = $dirSearcher.findall()
    if ($results.Count -gt 0) #if a user object is found, that means the user exists.
    {
        $ret = $true
    }
    return $ret
}

#EndRegion

#Region Shortcuts
# ====================================================================================
# Func: AddResourcesLink
# Desc: Adds an item to the Resources list shown on the Central Admin homepage
#       $url should be relative to the central admin home page and should not include the leading /
# ====================================================================================
Function AddResourcesLink([string]$title,[string]$url)
{
    $centraladminapp = Get-SPWebApplication -IncludeCentralAdministration | ? {$_.IsAdministrationWebApplication}
    $centraladminurl = $centraladminapp.Url
    $centraladmin = (Get-SPSite $centraladminurl)

    $item = $centraladmin.RootWeb.Lists["Resources"].Items | Where { $_["URL"] -match ".*, $title" }
    If ($item -eq $null )
    {
        $item = $centraladmin.RootWeb.Lists["Resources"].Items.Add();
    }

    $url = $centraladminurl + $url + ", $title";
    $item["URL"] = $url;
    $item.Update();
}

# ====================================================================================
# Func: PinToTaskbar
# Desc: Pins a program to the taskbar
# From: http://techibee.com/powershell/pin-applications-to-task-bar-using-powershell/685
# ====================================================================================
Function PinToTaskbar([string]$application)
{
    $shell = New-Object -ComObject "Shell.Application"
    $folder = $shell.Namespace([System.IO.Path]::GetDirectoryName($application))

    Foreach ($verb in $folder.ParseName([System.IO.Path]::GetFileName($application)).verbs())
    {
        If($verb.name.replace("&","") -match "Pin to Taskbar")
        {
            $verb.DoIt()
        }
    }
}
#EndRegion

#Region Stop Default Web Site
Function Stop-DefaultWebsite ()
{
    # Added to avoid conflicts with web apps that do not use a host header
    # Thanks to Paul Stork per http://autospinstaller.codeplex.com/workitem/19318 for confirming the Stop-Website cmdlet
    ImportWebAdministration
    $defaultWebsite = Get-Website | Where-Object {$_.Name -eq "Default Web Site" -or $_.ID -eq 1 -or $_.physicalPath -eq "%SystemDrive%\inetpub\wwwroot"} # Try different ways of identifying the Default Web Site, in case it has a different name (e.g. localized installs)
    log " - Checking $($defaultWebsite.Name)..." 
    if ($defaultWebsite.State -ne "Stopped")
    {
        log "Stopping..." 
        $defaultWebsite | Stop-Website
        if ($?) {log "OK."}
    }
    else {log "Already stopped."}
}
#EndRegion

#Region Get SP Major Version Number
function Get-MajorVersionNumber ([xml]$xmlinput)
{
    # Create hash tables with major version to product year mappings & vice-versa
    $spYears = @{"14" = "2010"; "15" = "2013"}
    $spVersions = @{"2010" = "14"; "2013" = "15"}
    $env:spVer = $spVersions.($xmlinput.Configuration.Install.SPVersion)
}
#EndRegion

#Region Custom functions

# Author: Marina krynina, CSC
Function UpdateProcessIdentityToRunAs ($serviceToUpdate, [string] $newServiceIdentity)
{
    # Managed Account
    $managedAccountGen = Get-SPManagedAccount | Where-Object {$_.UserName -eq $($newServiceIdentity)}
    if ($managedAccountGen -eq $null) { Throw " - Managed Account $($newServiceIdentity) not found" }
    if ($serviceToUpdate.Service) {$serviceToUpdate = $serviceToUpdate.Service}
    if ($serviceToUpdate.ProcessIdentity.Username -ne $managedAccountGen.UserName)
    {
        log " - Updating $($serviceToUpdate.TypeName) to run as $($managedAccountGen.UserName)..." 
        # Set the Process Identity to our general App Pool Account; otherwise it's set by default to the Farm Account and gives warnings in the Health Analyzer
        $serviceToUpdate.ProcessIdentity.CurrentIdentityType = "SpecificUser"
        $serviceToUpdate.ProcessIdentity.ManagedAccount = $managedAccountGen
        $serviceToUpdate.ProcessIdentity.Update()
        $serviceToUpdate.ProcessIdentity.Deploy()
        log "Done."
    }
    else {log " - $($serviceToUpdate.TypeName) is already configured to run as $($managedAccountGen.UserName)."}
}

# MK - custom function
function CopySharePointRootCertToLocalTrustedCertStore 
{
    # Add the SharePoint PowerShell snap-in
    if (-not (Get-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
    }
 
    # Get the SharePoint root certificate
    $rootCert = (Get-SPCertificateAuthority).RootCertificate
 
    # Check if the certificate already exists
    # If it does, report and end
    if ((dir "Cert:\LocalMachine\Root" | ? { $_.Thumbprint -eq $rootCert.Thumbprint })) {
        log "INFO: SharePoint Root Authority already exists in local machine trusted root certificate store."
        return
    }
 
    # Get the certificate store for "Trusted Root Certification Authorities" (Cert:\LocalMachine\Root)
    $certStore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store Root, LocalMachine
 
    # Open the store with maximum allowed privileges
    $certStore.Open("MaxAllowed")
 
    # Add the certificate to the store
    $certStore.Add($rootCert)
 
    # Close the store
    $certStore.Close()
 
    # Get the certificate if it exists
    if ((dir "Cert:\LocalMachine\Root" | ? { $_.Thumbprint -eq $rootCert.Thumbprint })) {
        log "INFO: Certificate was successfully added to the Trusted Root store."
    }
    else {
        log "WARNING: The certificate could not be added to the Trusted Root store."
    }
}

function AddFarmAccountToLogonLocally ([string] $farmAccount)
{
    # Modified by Marina Krynina, CSC
    # written by Ingo Karstein, http://ikarstein.wordpress.com
    #  v1.0, 10/12/2012

    $accountToAdd = $farmAccount

    $sidstr = $null
    try {
	    $ntprincipal = new-object System.Security.Principal.NTAccount "$accountToAdd"
	    $sid = $ntprincipal.Translate([System.Security.Principal.SecurityIdentifier])
	    $sidstr = $sid.Value.ToString()
    } catch {
	    $sidstr = $null
    }

    log "INFO: Account: $($accountToAdd)"

    if( [string]::IsNullOrEmpty($sidstr) ) {
	    log "ERROR: Account not found!"
	    exit -1
    }

    log "INFO: Account SID: $($sidstr)"

    $tmp = [System.IO.Path]::GetTempFileName()

    log "INFO: Export current Local Security Policy"
    secedit.exe /export /cfg "$($tmp)" 

    $c = Get-Content -Path $tmp 

    $currentSetting = ""

    foreach($s in $c) {
	    if( $s -like "SeInteractiveLogonRight*") {
		    $x = $s.split("=",[System.StringSplitOptions]::RemoveEmptyEntries)
		    $currentSetting = $x[1].Trim()
	    }
    }

    if( $currentSetting -notlike "*$($sidstr)*" ) {
	    log "INFO: Modify Setting ""Allow Logon Locally"""
	
	    if( [string]::IsNullOrEmpty($currentSetting) ) {
		    $currentSetting = "*$($sidstr)"
	    } else {
		    $currentSetting = "*$($sidstr),$($currentSetting)"
	    }
	
	    log "INFO: $currentSetting"
	
	    $outfile = @"
    [Unicode]
    Unicode=yes
    [Version]
    signature="`$CHICAGO`$"
    Revision=1
    [Privilege Rights]
    SeInteractiveLogonRight = $($currentSetting)
"@

	    $tmp2 = [System.IO.Path]::GetTempFileName()
	
	
	    log "INFO: Import new settings to Local Security Policy" 
	    $outfile | Set-Content -Path $tmp2 -Encoding Unicode -Force

	    #notepad.exe $tmp2
	    Push-Location (Split-Path $tmp2)
	
	    try {
		    secedit.exe /configure /db "secedit.sdb" /cfg "$($tmp2)" /areas USER_RIGHTS 
		    #write-host "secedit.exe /configure /db ""secedit.sdb"" /cfg ""$($tmp2)"" /areas USER_RIGHTS "
	    } finally {	
		    Pop-Location
	    }
    } else {
	    log "INFO: NO ACTIONS REQUIRED! Account already in ""Allow Logon Locally"""
    }

    log "INFO: Done."
}

function ResetFIMServices
{
    $fimServices = @("FIMService", "FIMSynchronizationService")
    
    foreach($fimSvc in $fimServices)
    {
        log "INFO: Service = $fimSvc"
        $LocalSrv = Get-WmiObject win32_service | Where-Object {$_.name -eq $fimSvc}

        log ("INFO: Service.StartName before = " + $LocalSrv.StartName)
        if (!([string]$LocalSrv.StartName).Contains("LocalSystem"))
        {
            $LocalSrv.Change($null,$null,$null,$null,$null,$false,".\LocalSystem","")
        }

        log ("INFO: Service.State before = " + $LocalSrv.State)
        log ("INFO: Service.StartMode before = " + $LocalSrv.StartMode)
        if ($LocalSrv.State -ne "Disabled")
        {
            $LocalSrv.ChangeStartMode("Disabled")
        }

        $LocalSrv = Get-WmiObject win32_service | Where-Object {$_.name -eq $fimSvc}
        log ("INFO: Service.StartName after = " + $LocalSrv.StartName)
        log ("INFO: Service.State after = " + $LocalSrv.State)
        log ("INFO: Service.StartMode after = " + $LocalSrv.StartMode)
    }      
}

#EndRegion Custom functions
########################################################################################################################################

#Region Prepare For Farm configuration
Function PrepForConfig 
{
    $spInstalled = (Get-SharePointInstall)
    ValidateCredentials $xmlinput
    ValidatePassphrase $xmlinput
    CheckSQLAccess

    DisableLoopbackCheck $xmlinput
    RemoveIEEnhancedSecurity $xmlinput
    AddSourcePathToLocalIntranetZone
    DisableServices $xmlinput
    DisableCRLCheck $xmlinput
    ConfigureIISLogging $xmlinput
    FixTaxonomyPickerBug

    
    # TODO: ???? 
    #InstallProjectServer $xmlinput
    #InstallLanguagePacks $xmlinput
    #InstallUpdates
}
#EndRegion

#Region Setup Farm
Function Setup-Farm
{
    [System.Management.Automation.PsCredential]$farmCredential = GetFarmCredentials $xmlinput
    [security.securestring]$secPhrase = GetSecureFarmPassphrase $xmlinput
    ConfigureFarmAdmin $xmlinput
    Load-SharePoint-PowerShell    
    CreateOrJoinFarm $xmlinput ([security.securestring]$secPhrase) ([System.Management.Automation.PsCredential]$farmCredential)    
    CheckFarmTopology $xmlinput
    ConfigureFarm $xmlinput    
    ConfigureDiagnosticLogging $xmlinput
    ConfigureLanguagePacks $xmlinput
    AddManagedAccounts $xmlinput

    CreateWebApplications $xmlinput
}
#EndRegion

#Region Setup Services
Function Setup-Services
{
    CreateMetadataServiceApp $xmlinput
    CreateEnterpriseSearchServiceApp $xmlinput
    
    ConfigureIncomingEmail $xmlinput
    ConfigureWorkflowTimerService $xmlinput
    ConfigureFoundationWebApplicationService $xmlinput
	ConfigureDistributedCacheService $xmlinput
    
    ConfigureSandboxedCodeService $xmlinput
    ConfigureClaimsToWindowsTokenService $xmlinput
    InstallSMTP $xmlinput
    ConfigureOutgoingEmail $xmlinput

    CreateStateServiceApp $xmlinput
    
    ConfigureFoundationSearch $xmlinput
    ConfigureTracing $xmlinput
    CreateSPUsageApp $xmlinput
    ConfigureUsageLogging $xmlinput
    
    CreateSecureStoreServiceApp $xmlinput   
    CreateBusinessDataConnectivityServiceApp $xmlinput

    CreateExcelServiceApp $xmlinput
    CreateAccess2010ServiceApp $xmlinput
    CreateVisioServiceApp $xmlinput
    CreatePerformancePointServiceApp $xmlinput
    CreateWordAutomationServiceApp $xmlinput
	CreateAppManagementServiceApp $xmlinput
	CreateSubscriptionSettingsServiceApp $xmlinput
    CreateWorkManagementServiceApp $xmlinput
    CreateMachineTranslationServiceApp $xmlinput
    CreateAccessServicesApp $xmlinput
    CreatePowerPointConversionServiceApp $xmlinput

    # NOT SUPPORTED
    #CreateProjectServerServiceApp $xmlinput
    #Configure-PDFSearchAndIcon $xmlinput
    #InstallForeFront $xmlinput
    }
#EndRegion

#Region Finalize Install (perform any cleanup operations)
# Run last
Function Finalize-Install
{
    # Perform these steps only if the local server is a SharePoint farm server
    If (MatchComputerName $farmServers $env:COMPUTERNAME)
    {
        # Remove Farm Account from local Administrators group to avoid big scary warnings in Central Admin
        # But only if the script actually put it there, and we want to leave it there
        # (e.g. to work around the issue with native SharePoint backups deprovisioning UPS per http://www.toddklindt.com/blog/Lists/Posts/Post.aspx?ID=275)
        $farmAcct = $xmlinput.Configuration.Farm.Account.Username
        If (!($runningAsFarmAcct) -and ($xmlinput.Configuration.Farm.Account.getAttribute("AddToLocalAdminsDuringSetup") -eq $true) -and ($xmlinput.Configuration.Farm.Account.LeaveInLocalAdmins -eq $false))
        {
            $builtinAdminGroup = Get-AdministratorsGroup
            log " - Removing $farmAcct from local group `"$builtinAdminGroup`"..."
            $farmAcctDomain,$farmAcctUser = $farmAcct -Split "\\"
            try
            {
                ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Remove("WinNT://$farmAcctDomain/$farmAcctUser")
                If (-not $?) {throw}
            }
            catch {log " - $farmAcct already removed from `"$builtinAdminGroup.`""}

            # Restart SPTimerV4 so it can now run under non-local Admin privileges and avoid Health Analyzer warning
            log " - Restarting SharePoint Timer Service..."
            Restart-Service SPTimerV4
        }
        Else
        {
            log " - Not changing local Admin membership of $farmAcct."
        }

        log " - Adding Network Service to local WSS_WPG group (fixes event log warnings)..."
        Try
        {
            ([ADSI]"WinNT://$env:COMPUTERNAME/WSS_WPG,group").Add("WinNT://NETWORK SERVICE")
            If (-not $?) {Throw}
        }
        Catch {log " - Network Service is already a member."}
        Run-HealthAnalyzerJobs
    }

    log " - Completed!`a"
    $Host.UI.RawUI.WindowTitle = " -- Completed -- $env:COMPUTERNAME --"
    $env:EndDate = Get-Date
}
#EndRegion
