﻿try
{
    $scriptPath = split-path -parent $MyInvocation.MyCommand.Definition   

    write-host "INFO: Start Execute-OfcOnline-Install"

     # Agility Variables - set default
    $DEBUG = $true
    $VARIABLES = "ConfigFiles\Variables-OfcOnline.ps1"

    . .\Install\Execute-OfcOnline-Install.ps1 $scriptPath

    exit 0
}
catch
{
    $ex = $_.Exception | format-list | Out-String
    write-host "ERROR: Exception occurred `nException Message: $ex"

    exit 1
} 
 