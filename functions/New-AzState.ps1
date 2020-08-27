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
        [Parameter()]
        [String]$Id,
        [Parameter()]
        [CacheMode]$CacheMode
    )

    $ArgumentList = @($Id)
    if ($CacheMode) {
        $ArgumentList += $CacheMode
    }

    $AzState = New-Object -TypeName AzState -ArgumentList $ArgumentList

    return $AzState

}
