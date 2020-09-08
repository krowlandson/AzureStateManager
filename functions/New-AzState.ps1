#######################
# Function definition #
#######################

function New-AzState {
    ###############################################
    # Configure PSScriptAnalyzer rule suppression #
    ###############################################

    # The following SuppressMessageAttribute entries are used to surpress
    # PSScriptAnalyzer tests against known exceptions as per:
    # https://github.com/powershell/psscriptanalyzer#suppressing-rules
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only creating new object with custom type')] # May refactor to support ShouldProcess

    [CmdletBinding()]
    param (
        [String]$Id,
        [Switch]$IncludeIAM,
        [Switch]$IncludePolicy,
        [Switch]$SkipCache
    )

    # Initialize ArgumentList variable and update based on parameter inputs
    $ArgumentList = @{}
    if ($Id) {
        $ArgumentList = @{
            ArgumentList = [Object[]]$Id
        }
        if ($SkipCache) {
            $ArgumentList.ArgumentList += [CacheMode]"SkipCache"
        }
        else {
            $ArgumentList.ArgumentList += [CacheMode]"UseCache"
        }

        if ($IncludeIAM -and $IncludePolicy) {
            $ArgumentList.ArgumentList += [DiscoveryMode]"IncludeBoth"
        }
        elseif ($IncludeIAM) {
            $ArgumentList.ArgumentList += [DiscoveryMode]"IncludeIAM"
        }
        elseif ($IncludePolicy) {
            $ArgumentList.ArgumentList += [DiscoveryMode]"IncludePolicy"
        }
        else {
            $ArgumentList.ArgumentList += [DiscoveryMode]"ExcludeBoth"
        }
    }

    $AzState = New-Object -TypeName AzState @ArgumentList

    return $AzState

}
