#######################
# Function definition #
#######################

function New-AzState {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]$Id,
        [Parameter()]
        [String]$Type
    )

    if ($Id -and $Type) {
        $AzState = New-Object -TypeName AzState -ArgumentList $Id $Type
    }
    elseif ($Id) {
        $AzState = New-Object -TypeName AzState -ArgumentList $Id
    }
    else {
        $AzState = New-Object -TypeName AzState
    }

    return $AzState

}
