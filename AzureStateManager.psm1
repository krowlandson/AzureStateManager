#########################################
# Module dependencies and configuration #
#########################################

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$module = Get-Module Az.Accounts
        if ($null -ne $module -and $module.Version -lt [System.Version]"1.9.1")
{
    Write-Error "This module requires Az.Accounts version 1.9.1. An earlier version of Az.Accounts is imported in the current PowerShell session. Please open a new session before importing this module. This error could indicate that multiple incompatible versions of the Azure PowerShell cmdlets are installed on your system. Please see https://aka.ms/azps-version-error for troubleshooting information." -ErrorAction Stop
}
elseif ($null -eq $module)
{
    Import-Module Az.Accounts -MinimumVersion 1.9.1 -Scope Global
}

# Dot source all functions in all ps1 files located in the module
# Excludes tests and profiles

$functions = @()
$functions += Get-ChildItem -Path $PSScriptRoot\functions\*.ps1 -Exclude *.tests.ps1, *profile.ps1 -ErrorAction SilentlyContinue

foreach ($function in $functions.FullName) {
    try {
        Write-Verbose "Dot sourcing [$function]"
        . "$function"
    }
    catch {
        throw "Unable to dot source [$function]"
    }
}

# Create alias(es) for Functions
# New-Alias -Name "example" -Value "Invoke-ExampleFunction"

# Export module members
Export-ModuleMember -Function * -Alias *
