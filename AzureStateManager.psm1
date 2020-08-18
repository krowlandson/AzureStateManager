#########################################
# Module dependencies and configuration #
#########################################

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

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
