#################################
# Internal function definitions #
#################################

function Get-AzStateChildrenByType {

    [CmdletBinding()]
    [OutputType([AzState[]])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AzState[]]$AzStateInputs,
        [Parameter(Mandatory = $false, HelpMessage = "If provided, ExcludePathIds is used to surpress specific paths in the discovery process")]
        [String[]]$ExcludePathIds,
        [Parameter()]
        [Switch]$IncludeManagementGroups,
        [Parameter()]
        [Switch]$IncludeSubscriptions,
        [Parameter()]
        [Switch]$IncludeResourceGroups,
        [Parameter()]
        [Switch]$IncludeResources,
        [Parameter()]
        [Switch]$IncludeIAM,
        [Parameter()]
        [Switch]$IncludePolicy,
        [Parameter()]
        [Int]$ThrottleLimit,
        [Parameter()]
        [CacheMode]$CacheMode
    )

    begin {

        # The begin block is used to setup the environment.
        # This includes initialising all variables and determining
        # which resource types to discover.

        [AzState[]]$AzStateOutput = @()
        [String[]]$FilterChildrenByType = @()
        if ($IncludeManagementGroups) {
            $FilterChildrenByType += "Microsoft.Management/managementGroups"
        }
        if ($IncludeSubscriptions) {
            $FilterChildrenByType += "Microsoft.Management/managementGroups/subscriptions", "Microsoft.Resources/subscriptions"
        }
        if ($IncludeResourceGroups) {
            $FilterChildrenByType += "Microsoft.Resources/resourceGroups"
        }
        $ChildrenToProcess = @()
        $IAMToProcess = @()
        $PolicyToProcess = @()

    }

    process {

        # The process block is used to build a list of all
        # resources from AzStateInputs.
        # This ensures that each AzStateInputs object is added
        # to the xToProcess variables before building the
        # AzStateOutput to return.

        foreach ($AzStateInput in $AzStateInputs) {
            if ($AzStateInput.Children) {
                # The following is to avoid needing to list all Resource Types in
                # FilterChildrenByType when IncludeResources is specified
                if ($IncludeResources -and ($AzStateInput.Type -ieq "Microsoft.Resources/resourceGroups")) {
                    $ChildrenToProcess += $AzStateInput.Children | `
                    Where-Object { $_.Id -ne "" } | `
                    Where-Object { $_.Id -inotin $ExcludePathIds }
                }
                else {
                    $ChildrenToProcess += $AzStateInput.Children | `
                    Where-Object { $_.Id -ne "" } | `
                    Where-Object { $_.Id -inotin $ExcludePathIds } | `
                    Where-Object { $_.Type -iin $FilterChildrenByType }
                }
            }
            if ($IncludeIAM) {
                foreach ($IamPathSuffix in [AzState]::IamPathSuffixes($_.Type)) {
                    $IAMPath = $_.Id + $IamPathSuffix
                    $IAMToProcess += $IAMPath
                }
            }
            if ($IncludePolicy) {
                foreach ($PolicyPathSuffix in [AzState]::PolicyPathSuffixes($_.Type)) {
                    $PolicyPath = $_.Id + $PolicyPathSuffix
                    $PolicyToProcess += $PolicyPath
                }
            }
        }

    }

    end {

        # The end block is used to generate and return the
        # AzStateOutput from all xToProcess variables.
        # This ensure optimal parallel processing as the content
        # of all AzStateInputs is aggregated first.

        if ($ChildrenToProcess) {
            # Determine how many of each Resource Type are to be processed (for logging information only)
            $ResourceProfile = $ChildrenToProcess | Group-Object -Property Type
            foreach ($Profile in $ResourceProfile) {
                Write-Verbose "[Get-AzStateChildrenByType] Processing [$($Profile.Count)] Resources of Type [$($Profile.Name)]"
            }
            $IdsToProcess = ($ChildrenToProcess | Sort-Object).Id
            if ($ThrottleLimit -and $CacheMode) {
                $AzStateOutput += [AzState]::FromIds($IdsToProcess, $ThrottleLimit, $CacheMode)
            }
            elseif ($ThrottleLimit) {
                $AzStateOutput += [AzState]::FromIds($IdsToProcess, $ThrottleLimit)
            }
            elseif ($CacheMode) {
                $AzStateOutput += [AzState]::FromIds($IdsToProcess, $CacheMode)
            }
            else {
                $AzStateOutput += [AzState]::FromIds($IdsToProcess)
            }
        }
        if ($IAMToProcess) {
            Write-Verbose "[Get-AzStateChildrenByType] Processing [IAM] settings for [$($IAMToProcess.Count)] Resources"
            if ($CacheMode) {
                $AzStateOutput += [AzState]::DirectFromScope($IAMToProcess, $CacheMode) | Sort-Object -Property Id -Unique
            }
            else {
                $AzStateOutput += [AzState]::DirectFromScope($IAMToProcess) | Sort-Object -Property Id -Unique
            }
        }
        if ($PolicyToProcess) {
            Write-Verbose "[Get-AzStateChildrenByType] Processing [Policy] settings for [$($PolicyToProcess.Count)] Resources"
            if ($CacheMode) {
                $AzStateOutput += [AzState]::DirectFromScope($PolicyToProcess, $CacheMode) | Sort-Object -Property Id -Unique
            }
            else {
                $AzStateOutput += [AzState]::DirectFromScope($PolicyToProcess) | Sort-Object -Property Id -Unique
            }
        }

        return $AzStateOutput | Sort-Object -Property Id -Unique

    }

}

###############################
# Primary function definition #
###############################

function New-AzStateDiscovery {
    ###############################################
    # Configure PSScriptAnalyzer rule suppression #
    ###############################################

    # The following SuppressMessageAttribute entries are used to surpress
    # PSScriptAnalyzer tests against known exceptions as per:
    # https://github.com/powershell/psscriptanalyzer#suppressing-rules
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only creating new object with custom type')] # May refactor to support ShouldProcess

    [CmdletBinding()]
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [String[]]$RootId,
        [Parameter()]
        [String[]]$ExcludePathIds,
        [Parameter()]
        [Switch]$IncludeManagementGroups,
        [Parameter()]
        [Switch]$IncludeSubscriptions,
        [Parameter()]
        [Switch]$IncludeResourceGroups,
        [Parameter()]
        [Switch]$IncludeResources,
        [Parameter()]
        [Switch]$IncludeIAM,
        [Parameter()]
        [Switch]$IncludePolicy,
        [Parameter()]
        [Switch]$Recurse,
        [Parameter()]
        [Int]$ThrottleLimit,
        [Parameter()]
        [CacheMode]$CacheMode
    )

    begin {

        [AzState[]]$AzStateDiscoveryOutput = @()

        Write-Verbose -Message "############################################################"
        Write-Verbose -Message "[AzStateDiscovery] Starting AzState Discovery for [$($RootId.Count)] Root Nodes"
        Write-Verbose -Message "$("[AzStateDiscovery] {0} Management Groups"    -f $(($IncludeManagementGroups) ? {Including}  : {Excluding} ))"
        Write-Verbose -Message "$("[AzStateDiscovery] {0} Subscriptions"        -f $(($IncludeSubscriptions)    ? {Including}  : {Excluding} ))"
        Write-Verbose -Message "$("[AzStateDiscovery] {0} Resource Groups"      -f $(($IncludeResourceGroups)   ? {Including}  : {Excluding} ))"
        Write-Verbose -Message "$("[AzStateDiscovery] {0} Resources"            -f $(($IncludeResources)        ? {Including}  : {Excluding} ))"
        Write-Verbose -Message "$("[AzStateDiscovery] {0} Access control (IAM)" -f $(($IncludeIAM)              ? {Including}  : {Excluding} ))"
        Write-Verbose -Message "$("[AzStateDiscovery] {0} Policy"               -f $(($IncludePolicy)           ? {Including}  : {Excluding} ))"
        Write-Verbose -Message "$("[AzStateDiscovery] Using cache mode [{0}]"   -f $(($CacheMode)               ? {$CacheMode} : {Default}   ))"
        Write-Verbose -Message "############################################################"

    }

    process {

        foreach ($Id in $RootId) {

            Write-Verbose "[AzStateDiscovery] Setting Root Id [$Id]"

            $ArgumentList = @{
                Id = $Id
            }
            if ($CacheMode) {
                $ArgumentList += @{
                    CacheMode = $CacheMode
                }
            }

            $RootAzState = New-AzState @ArgumentList

            $AzStateDiscoveryOutput += $RootAzState

            $ArgumentListChildren = @{
                IncludeManagementGroups = $IncludeManagementGroups
                IncludeSubscriptions    = $IncludeSubscriptions
                IncludeResourceGroups   = $IncludeResourceGroups
                IncludeResources        = $IncludeResources
                IncludeIAM              = $IncludeIAM
                IncludePolicy           = $IncludePolicy
            }
            if ($ExcludePathIds) {
                $ArgumentListChildren += @{
                    ExcludePathIds = $ExcludePathIds
                }
            }
            if ($ThrottleLimit) {
                $ArgumentListChildren += @{
                    ThrottleLimit = $ThrottleLimit
                }
            }
            if ($CacheMode) {
                $ArgumentListChildren += @{
                    CacheMode = $CacheMode
                }
            }

            # The following loop will discovery all children by type based on the selected
            # switches and will recurse if selected
            $DiscoveryComplete = $false
            do {
                $RootAzState = $RootAzState | Get-AzStateChildrenByType @ArgumentListChildren
                $AzStateDiscoveryOutput += $RootAzState
                if ((-not $RootAzState) -or (-not $Recurse)) {
                    $DiscoveryComplete = $true
                }
            } until ($DiscoveryComplete)

        }
    }

    end {
        # Once processing is complete return the final array of AzState objects
        # Need to sort unique due to duplicate Policy and Role definitions across multiple resources
        return $AzStateDiscoveryOutput | Sort-Object -Property Id -Unique
    }

}
