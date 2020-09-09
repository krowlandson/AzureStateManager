###############################################
# Configure PSScriptAnalyzer rule suppression #
###############################################

# The following SuppressMessageAttribute entries are used to surpress
# PSScriptAnalyzer tests against known exceptions as per:
# https://github.com/powershell/psscriptanalyzer#suppressing-rules
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Using ArgumentList')]
param ()

############################################
# Custom enum data sets used within module #
############################################

enum CacheMode {
    UseCache
    SkipCache
    # Future feature in consideration to allow SkipCache
    # to optionally apply to resource dependencies
    # SkipCacheRecurse
}

enum DiscoveryMode {
    IncludeIAM
    IncludePolicy
    IncludeBoth
    ExcludeBoth
}

enum Release {
    stable
    latest
}

##########################
# AzStateProviders Class #
##########################

# [AzStateProviders] class is used to create cache of latest API version for all Azure Providers
# This can be used to dynamically retrieve the latest or stable API version in string format
# Can also output the API version as a param string for use within a Rest API request
# To minimise the number of Rest API requests needed, this class creates a cache and populates
# it with all results from the request. The cache is then used to return the requested result.
# Need to store and lookup the key in lowercase to avoid case sensitivity issues while providing
# better performance as allows using ContainsKey method to search for key in cache.
# Should be safe to ignore case as Providers are not case sensitive.
class AzStateProviders {

    # Public class properties
    [String]$Provider
    [String]$ResourceType
    [String]$Type
    [String]$ApiVersion
    [Release]$Release

    # Static properties
    hidden static [String]$ProvidersApiVersion = "2020-06-01"
    hidden static [Release]$DefaultApiRelease = "latest"

    # Default empty constructor
    AzStateProviders() {
    }

    # Default constructor using PSCustomObject to populate object
    AzStateProviders([PSCustomObject]$PSCustomObject) {
        $this.Provider = $PSCustomObject.Provider
        $this.ResourceType = $PSCustomObject.ResourceType
        $this.Type = $PSCustomObject.Type
        $this.ApiVersion = $PSCustomObject.ApiVersion
        $this.Release = $PSCustomObject.Release
    }

    # Static method to get latest stable Api Version using Type
    static [String] GetApiVersionByType([String]$Type) {
        return [AzStateProviders]::GetApiVersionByType($Type, [AzStateProviders]::DefaultApiRelease)
    }

    # Static method to get Api Version using Type
    static [String] GetApiVersionByType([String]$Type, [Release]$Release) {
        if (-not [AzStateProviders]::InCache($Type, ($Release))) {
            [AzStateProviders]::UpdateCache()
        }
        $private:AzStateProvidersFromCache = [AzStateProviders]::SearchCache($Type, $Release)
        return $private:AzStateProvidersFromCache.ApiVersion
    }

    # Static method to get Api Params String using Type
    static [String] GetApiParamsByType([String]$Type) {
        return "?api-version={0}" -f [AzStateProviders]::GetApiVersionByType($Type)
    }

    # Static property to store cache of AzStateProviders using a threadsafe
    # dictionary variable to allow caching across parallel jobs
    # https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/foreach-object#example-14--using-thread-safe-variable-references
    static [System.Collections.Concurrent.ConcurrentDictionary[String, AzStateProviders]]$Cache

    # Static method to show all entries in Cache
    static [AzStateProviders[]] ShowCache() {
        return ([AzStateProviders]::Cache).Values
    }

    # Static method to show all entries in Cache matching the specified release type (latest|stable)
    static [AzStateProviders[]] ShowCache([Release]$Release) {
        return ([AzStateProviders]::Cache).Values | Where-Object -Property Release -EQ $Release
    }

    # Static method to show all entries in Cache matching the specified type using default stable release type
    static [AzStateProviders[]] SearchCache([String]$Type) {
        return [AzStateProviders]::SearchCache($Type, [AzStateProviders]::DefaultApiRelease)
    }

    # Static method to show all entries in Cache matching the specified type using the specified release type
    static [AzStateProviders[]] SearchCache([String]$Type, [Release]$Release) {
        return [AzStateProviders]::Cache["$Type ($Release)".ToString().ToLower()]
    }

    # Static method to return [Boolean] for Resource Type in Cache query using default stable release type
    static [Boolean] InCache([String]$Type) {
        return [AzStateProviders]::InCache($Type, [AzStateProviders]::DefaultApiRelease)
    }

    # Static method to return [Boolean] for Resource Type in Cache query using the specified release type
    static [Boolean] InCache([String]$Type, [Release]$Release) {
        if ([AzStateProviders]::Cache) {
            $private:CacheKeyLowercase = "$Type ($Release)".ToString().ToLower()
            $private:InCache = ([AzStateProviders]::Cache).ContainsKey($private:CacheKeyLowercase)
            if ($private:InCache) {
                Write-Verbose "[AzStateProviders] Resource Type found in Cache [$Type] ($Release)"
            }
            else {
                Write-Verbose "[AzStateProviders] Resource Type not found in Cache [$Type] ($Release)"
            }
            return $private:InCache
        }
        else {
            # The following prevents needing to initialize the cache
            # manually if not exist on first attempt to use
            [AzStateProviders]::InitializeCache()
            return $false
        }
    }

    # Static method to update Cache using current Subscription from context
    static [Void] UpdateCache() {
        $private:SubscriptionId = (Get-AzContext).Subscription.Id
        [AzStateProviders]::UpdateCache($private:SubscriptionId)
    }

    # Static method to update Cache using specified SubscriptionId
    static [Void] UpdateCache([String]$SubscriptionId) {
        $private:Method = "GET"
        $private:Path = "/subscriptions/$subscriptionId/providers?api-version=$([AzStateProviders]::ProvidersApiVersion)"
        $private:PSHttpResponse = Invoke-AzRestMethod -Method $private:Method -Path $private:Path
        $private:PSHttpResponseContent = $private:PSHttpResponse.Content
        $private:Providers = ($private:PSHttpResponseContent | ConvertFrom-Json).value
        if ($private:Providers) {
            [AzStateProviders]::ClearCache()
        }
        foreach ($private:Provider in $private:Providers) {
            Write-Verbose "[AzStateProviders] Processing Provider Namespace [$($private:Provider.namespace)]"
            foreach ($private:Type in $private:Provider.resourceTypes) {
                # Check for latest ApiVersion and add to cache
                $private:LatestApiVersion = ($private:Type.apiVersions `
                    | Sort-Object -Descending `
                    | Select-Object -First 1)
                if ($private:LatestApiVersion) {
                    [AzStateProviders]::AddToCache(
                        $private:Provider.namespace.ToString(),
                        $private:Type.resourceType.ToString(),
                        $private:LatestApiVersion.ToString(),
                        "latest"
                    )
                }
                # Check for stable ApiVersion and add to cache
                $private:StableApiVersion = ($private:Type.apiVersions `
                    | Sort-Object -Descending `
                    | Where-Object { $_ -match "^(\d{4}-\d{2}-\d{2})$" } `
                    | Select-Object -First 1)
                if ($private:StableApiVersion) {
                    [AzStateProviders]::AddToCache(
                        $private:Provider.namespace.ToString(),
                        $private:Type.resourceType.ToString(),
                        $private:StableApiVersion.ToString(),
                        "stable"
                    )
                }
            }
        }
    }

    # Static method to add provider instance to Cache
    hidden static [Void] AddToCache([String]$Provider, [String]$ResourceType, [String]$ApiVersion, [String]$Release) {
        Write-Debug "[AzStateProviders] Adding [$($Provider)/$($ResourceType)] to Cache with $Release Api-Version [$ApiVersion]"
        $private:AzStateProviderObject = [PsCustomObject]@{
            Provider     = "$Provider"
            ResourceType = "$ResourceType"
            Type         = "$Provider/$ResourceType"
            ApiVersion   = "$ApiVersion"
            Release      = "$Release"
        }
        $private:CacheKey = "$Provider/$ResourceType ($Release)"
        $private:CacheKeyLowercase = $private:CacheKey.ToString().ToLower()
        $private:CacheValue = [AzStateProviders]::new($private:AzStateProviderObject)
        $private:TryAdd = ([AzStateProviders]::Cache).TryAdd($private:CacheKeyLowercase, $private:CacheValue)
        if ($private:TryAdd) {
            Write-Verbose "[AzStateProviders] Added Resource Type to Cache [$private:CacheKey]"
        }
    }

    # Static method to initialize Cache
    # Will also reset cache if exists
    static [Void] InitializeCache() {
        Write-Verbose "[AzStateProviders] Initializing Cache (Empty)"
        [AzStateProviders]::Cache = [System.Collections.Concurrent.ConcurrentDictionary[String, AzStateProviders]]::new()
    }

    # Static method to initialize Cache from copy of cache stored in input variable
    static [Void] InitializeCache([System.Collections.Concurrent.ConcurrentDictionary[String, AzStateProviders]]$AzStateProvidersCache) {
        Write-Verbose "[AzStateProviders] Initializing Cache (From Copy)"
        [AzState]::Cache = $AzStateProvidersCache
    }

    # Static method to clear all entries from Cache
    static [Void] ClearCache() {
        [AzStateProviders]::InitializeCache()
    }

}

#######################
# AzStateSimple Class #
#######################

# The [AzStateSimple] class is used to control the creation of a simple object used for storing
# the ID and Type of Resources linked to the primary Resource within [AzState]
# We explicitly store the Type to simplify filtering when querying these Resources
class AzStateSimple {

    # Public class properties
    [String]$Id
    [String]$Type

    AzStateSimple() {
        $this.Id = ""
        $this.Type = ""
    }

    AzStateSimple([PsCustomObject]$PsCustomObject) {
        $this.Id = $PsCustomObject.Id
        $this.Type = $PsCustomObject.Type
    }

    static [AzStateSimple[]] Convert([PsCustomObject[]]$PsCustomObjects) {
        $private:Convert = @()
        foreach ($private:PsCustomObject in $PsCustomObjects) {
            $private:Convert += [AzStateSimple]::new($private:PsCustomObject)
        }
        return $private:Convert
    }

}

#######################
# AzStatePolicy Class #
#######################

# The [AzStatePolicy] class is used to control the creation of an object used for storing
# the different Policy associations within [AzState]
class AzStatePolicy {

    # Public class properties
    [AzStateSimple[]]$PolicyDefinitions
    [AzStateSimple[]]$PolicySetDefinitions
    [AzStateSimple[]]$PolicyAssignments

    AzStatePolicy() {
        $this.PolicyAssignments = @()
        $this.PolicyDefinitions = @()
        $this.PolicySetDefinitions = @()
    }

}

####################
# AzStateIAM Class #
####################

# The [AzStateIAM] class is used to control the creation of an object used for storing
# the different Access control (IAM) associations within [AzState]
class AzStateIAM {

    # Public class properties
    [AzStateSimple[]]$RoleDefinitions = @()
    [AzStateSimple[]]$RoleAssignments = @()

    AzStateIAM() {
        $this.RoleDefinitions = @()
        $this.RoleAssignments = @()
    }

}

##########################
# AzStateRestCache Class #
##########################

# The [AzStateRestCache] class is used to control the creation of an object used for creating
# cached copies of results from the GetAzRestMethod method in [AzState]
class AzStateRestCache {

    # Public class properties
    [String]$Key
    [PSCustomObject]$Value

    AzStateRestCache([String]$Key, [PSCustomObject]$Value) {
        $this.Key = $Key
        $this.Value = $Value
    }

}

###################
# [AzState] Class #
###################

# The [AzState] class used to create and update new AsState objects
# This is the primary module class containing all logic for managing
# [AzState] objects for Azure Resources.
# By default, the Cache in case insensitive mode to minimise false
# Cache misses due to inconsistent case in API responses.
# By default, discovery for IAM and Policy is excluded due to the
# high overhead this incurs on discovery (time and performance).

class AzState {

    # Public class properties
    [String]$Id
    [String]$Type
    [String]$Name
    [Object]$Raw
    [String]$Provider
    [AzStateIAM]$IAM
    [AzStatePolicy]$Policy
    [AzStateSimple[]]$Children
    [AzStateSimple[]]$LinkedResources
    [AzStateSimple]$Parent
    [AzStateSimple[]]$Parents
    [String]$ParentPath
    [String]$ResourcePath

    # Hidden static class properties
    hidden static [String[]]$DefaultProperties = "Id", "Type", "Name"
    hidden static [CacheMode]$DefaultCacheMode = "UseCache"
    hidden static [Boolean]$DefaultCacheCaseSenstive = $false
    hidden static [DiscoveryMode]$DefaultDiscoveryMode = "ExcludeBoth"
    hidden static [Int]$DefaultThrottleLimit = 4
    hidden static [String[]]$DefaultAzStateChildrenTypes = @(
        "Microsoft.Management/managementGroups"
        "Microsoft.Management/managementGroups/subscriptions"
        "Microsoft.Resources/subscriptions"
        "Microsoft.Resources/resourceGroups"
    )

    # Thread safe object containing a map of parents once generated
    hidden static [System.Collections.Concurrent.ConcurrentDictionary[String, String]]$ParentMap

    # Regex patterns for use within methods
    hidden static [Regex]$RegexAfterLastForwardSlash = "(?!.*(?=\/)).*"
    hidden static [Regex]$RegexBeforeLastForwardSlash = "^.*(?=\/)"
    hidden static [Regex]$RegexQuestionMarksAfterFirst = "(?<=[^\?]+\?[^\?]+)\?"
    hidden static [Regex]$RegexUriParams = "\?\S+"
    hidden static [Regex]$RegexRemoveParamsFromUri = "(?<=[^\?]+\?[^\?]+)\?"
    hidden static [Regex]$RegexIsGuid = "[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}"
    hidden static [Regex]$RegexProviderTypeFromId = "(?i)(?<=\/providers\/)(?!.*\/providers\/)[^\/]+\/[\w-]+"
    hidden static [Regex]$RegexIsSubscription = "(?i)(\/subscriptions)(?!\/.*\/)"
    hidden static [Regex]$RegexIsResourceGroup = "(?i)(\/resourceGroups)(?!\/.*\/)"
    hidden static [Regex]$RegexIsResource = "(?i)(\/resources)(?!\/.*\/)"
    hidden static [Regex]$RegexExtractProviderScope = "(?i)\/(?=.*\/providers\/)[^\/]+\/[\S]+(?=.*\/providers\/)"
    hidden static [Regex]$RegexExtractSubscriptionId = "(?i)^(\/subscriptions\/)[^\/]{36}((?![^\/])|$)"
    hidden static [Regex]$RegexExtractResourceGroupId = "(?i)^(\/subscriptions\/)[^\/]{36}(\/resourceGroups\/)[^\/]+((?![^\/])|$)"
    hidden static [Regex]$RegexSubscriptionTypes = "(?i)^(Microsoft.)(Management\/managementGroups|Resources)\/(subscriptions)$"
    hidden static [Regex]$RegexIAMTypes = "(?i)^(Microsoft.Authorization\/role)(Assignments|Definitions)$"
    hidden static [Regex]$RegexPolicyTypes = "(?i)^(Microsoft.Authorization\/policy)(Assignments|Definitions|SetDefinitions)$"

    # Static method to return list of policy types supported by Resource
    hidden static [String[]] PolicyPathSuffixes($Type) {
        switch ($Type) {
            { $Type -in "Microsoft.Management/managementGroups", "Microsoft.Resources/subscriptions" } {
                $private:PolicyPathSuffixes = @(
                    "/providers/Microsoft.Authorization/policyDefinitions"
                    "/providers/Microsoft.Authorization/policySetDefinitions"
                    "/providers/Microsoft.Authorization/policyAssignments?`$filter=atScope()"
                )
            }
            "Microsoft.Resources/resourceGroups" {
                $private:PolicyPathSuffixes = @(
                    "/providers/Microsoft.Authorization/policyAssignments?`$filter=atScope()"
                )
            }
            Default {
                $private:PolicyPathSuffixes = @(
                    # "/providers/Microsoft.Authorization/policyAssignments?`$filter=atScope()"
                )
            }
        }
        return $private:PolicyPathSuffixes
    }

    # Static method to return list of Access control (IAM) types supported by Resource
    hidden static [String[]] IamPathSuffixes($Type) {
        switch ($Type) {
            { $Type -in "Microsoft.Management/managementGroups", "Microsoft.Resources/subscriptions" } {
                $private:IamPathSuffixes = @(
                    "/providers/Microsoft.Authorization/roleDefinitions"
                    "/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()"
                )
            }
            "Microsoft.Resources/resourceGroups" {
                $private:IamPathSuffixes = @(
                    "/providers/Microsoft.Authorization/roleDefinitions"
                    "/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()"
                )
            }
            Default {
                $private:IamPathSuffixes = @(
                    # "/providers/Microsoft.Authorization/roleDefinitions"
                    # "/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()"
                )
            }
        }
        return $private:IamPathSuffixes
    }

    #----------------------#
    # Default Constructors #
    #----------------------#

    # Create new empty AzState object
    AzState() {
    }

    # Create new AzState object from input Id with default settings
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    AzState([String]$Id) {
        $this.Update($Id, [AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Create new AzState object from input Id
    # Sets UseCache to specified value
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    AzState([String]$Id, [CacheMode]$CacheMode) {
        $this.Update($Id, $CacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Create new AzState object from input Id
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    AzState([String]$Id, [DiscoveryMode]$DiscoveryMode) {
        $this.Update($Id, [AzState]::DefaultCacheMode, $DiscoveryMode)
    }

    # Create new AzState object from input Id
    # Sets CacheMode to specified value
    # Sets DiscoveryMode to specified value
    AzState([String]$Id, [CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        $this.Update($Id, $CacheMode, $DiscoveryMode)
    }

    # Create new AzState object from input object with default settings
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    AzState([PSCustomObject]$PSCustomObject) {
        $this.Initialize($PSCustomObject, [AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Create new AzState object from input object
    # Sets UseCache to specified value
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    AzState([PSCustomObject]$PSCustomObject, [CacheMode]$CacheMode) {
        $this.Initialize($PSCustomObject, $CacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Create new AzState object from input object
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    AzState([PSCustomObject]$PSCustomObject, [DiscoveryMode]$DiscoveryMode) {
        $this.Initialize($PSCustomObject, [AzState]::DefaultCacheMode, $DiscoveryMode)
    }

    # Create new AzState object from input object
    # Sets CacheMode to specified value
    # Sets DiscoveryMode to specified value
    AzState([PSCustomObject]$PSCustomObject, [CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        $this.Initialize($PSCustomObject, $CacheMode, $DiscoveryMode)
    }

    #----------------#
    # Update Methods #
    #----------------#

    # The update method is used to update all AzState attributes
    # using either the existing Id, provided Id or input object
    # to start discovery
    # This method is also used for creation of a new AzState
    # object to avoid duplication of code

    # Update [AzState] object using the existing Id value
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    [Void] Update() {
        $this.Update([AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Update [AzState] object using the existing Id value
    # Sets CacheMode to specified value
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    [Void] Update([CacheMode]$CacheMode) {
        $this.Update($CacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Update [AzState] object using the existing Id value
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    [Void] Update([DiscoveryMode]$DiscoveryMode) {
        $this.Update([AzState]::DefaultCacheMode, $DiscoveryMode)
    }

    # Update [AzState] object using the existing Id value
    # Sets UseCache to specified value
    [Void] Update([CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        if ($this.Id) {
            $this.Update($this.Id, $CacheMode, $DiscoveryMode)
        }
        else {
            Write-Error "Unable to update AzState. Please set a valid resource Id in the AzState object, or provide as an argument."
        }
    }

    # Update [AzState] object using the specified Id value
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    [Void] Update([String]$Id) {
        $this.Update($Id, [AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Update [AzState] object using the specified Id value
    # Sets UseCache to specified value
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    [Void] Update([String]$Id, [CacheMode]$CacheMode) {
        $this.Update($Id, $CacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Update [AzState] object using the specified Id value
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    [Void] Update([String]$Id, [DiscoveryMode]$DiscoveryMode) {
        $this.Update($Id, [AzState]::DefaultCacheMode, $DiscoveryMode)
    }

    # Update method used to update [AzState] object using the specified Id value
    # Sets UseCache to specified value
    # Sets DiscoveryMode to specified value
    [Void] Update([String]$Id, [CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        if (($CacheMode -eq "UseCache") -and [AzState]::InCache($Id)) {
            Write-Verbose "New-AzState (FROM CACHE) [$Id]"
            $private:CachedAzState = [AzState]::SearchCache($Id)
            $this.Initialize($private:CachedAzState, $CacheMode, $DiscoveryMode, $true)
        }
        else {
            Write-Information "New-AzState (FROM API) [$Id]"
            $private:GetAzConfig = [AzState]::GetAzConfig($Id, [CacheMode]"SkipCache")
            if ($private:GetAzConfig.Count -eq 1) {
                $this.Initialize($private:GetAzConfig[0], $CacheMode, $DiscoveryMode, $false)
            }
            else {
                Write-Error "Unable to update AzState for multiple Resources under ID [$Id]. Please set the ID to a specific Resource ID, or use the FromScope method to create AzState for multiple Resources at the specified scope."
                break
            }
        }
    }

    #------------------------#
    # Initialization Methods #
    #------------------------#

    # The initialization methods are use to set additional AzState attributes
    # which are calculated from the base object properties

    # Initialize [AzState] object
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    [Void] Initialize() {
        $this.Initialize([AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Initialize [AzState] object
    # Sets CacheMode to specified value
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    [Void] Initialize([CacheMode]$CacheMode) {
        $this.Initialize($CacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Initialize [AzState] object
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    [Void] Initialize([DiscoveryMode]$DiscoveryMode) {
        $this.Initialize([AzState]::DefaultCacheMode, $DiscoveryMode)
    }

    # Initialize [AzState] object
    # Sets CacheMode to specified value (pending development)
    # Sets DiscoveryMode to specified value
    [Void] Initialize([CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        # Used to set values on variables which require internal methods
        $this.SetProvider()
        $this.SetChildren()
        $this.SetParent()
        $this.SetParents()
        $this.SetResourcePath()
        $this.SetIAM($DiscoveryMode)
        $this.SetPolicy($DiscoveryMode)
        # After the state object is initialized, add to the Cache array
        [AzState]::AddToCache($this)
    }

    # Initialize [AzState] object using the specified input object
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    # Sets UsingCache to false to enable full initialization
    [Void] Initialize([PsCustomObject]$PsCustomObject) {
        $this.Initialize($PsCustomObject, [AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode, $false)
    }

    # Initialize [AzState] object using the specified input object
    # Sets UseCache to specified value
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    # Sets UsingCache to false to enable full initialization
    [Void] Initialize([PsCustomObject]$PsCustomObject, [CacheMode]$CacheMode) {
        $this.Initialize($PsCustomObject, $CacheMode, [AzState]::DefaultDiscoveryMode, $false)
    }

    # Initialize [AzState] object using the specified input object
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    # Sets UsingCache to false to enable full initialization
    [Void] Initialize([PsCustomObject]$PsCustomObject, [DiscoveryMode]$DiscoveryMode) {
        $this.Initialize($PsCustomObject, [AzState]::DefaultCacheMode, $DiscoveryMode, $false)
    }

    # Initialize [AzState] object using the specified input object
    # Sets UseCache to specified value
    # Sets DiscoveryMode to specified value
    # Sets UsingCache to false to enable full initialization
    [Void] Initialize([PsCustomObject]$PsCustomObject, [CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        $this.Initialize($PsCustomObject, $CacheMode, $DiscoveryMode, $false)
    }

    # Initialize [AzState] object using the specified input object
    # Sets UseCache to specified value
    # Sets DiscoveryMode to specified value
    # Sets UsingCache to specified value
    [Void] Initialize([PsCustomObject]$PsCustomObject, [CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode, [Boolean]$UsingCache) {
        # Using a foreach loop to set all properties dynamically
        if ($UsingCache) {
            foreach ($property in $this.psobject.Properties.Name) {
                $this.$property = $PsCustomObject.$property
            }
            # Check whether cached item needs updating to include IAM or Policy
            # IMPROVEMENT: Need to look into whether to add method to force update of cached item
            if (($DiscoveryMode -eq "IncludeBoth") -and ((-not $this.IAM) -or (-not $this.Policy))) {
                $this.Initialize($CacheMode, $DiscoveryMode)
            }
            elseif (($DiscoveryMode -eq "IncludeIAM") -and (-not $this.IAM)) {
                $this.Initialize($CacheMode, $DiscoveryMode)
            }
            elseif (($DiscoveryMode -eq "IncludePolicy") -and (-not $this.Policy)) {
                $this.Initialize($CacheMode, $DiscoveryMode)
            }
        }
        else {
            $this.SetDefaultProperties($PsCustomObject)
            $this.Initialize($CacheMode, $DiscoveryMode)
        }
    }

    #----------------#
    # Hidden Methods #
    #----------------#

    # The following pool of methods provide the inner workings of the AzState class

    # Method to set default properties in AzState from input object
    hidden [Void] SetDefaultProperties([PsCustomObject]$PsCustomObject) {
        if ($PsCustomObject.Raw) {
            # This is to catch an input PsCustomObject which is already an AzState object
            $this.Raw = $PsCustomObject.Raw
        }
        else {
            $this.Raw = $PsCustomObject
        }
        $this.SetDefaultProperties()
    }

    hidden [Void] SetDefaultProperties() {
        foreach ($private:Property in [AzState]::DefaultProperties) {
            $this.$private:Property = $this.Raw.$private:Property
        }
        switch -regex ($this.Raw.Id) {
            # ([AzState]::RegexProviderTypeFromId).ToString() { <# pending development #> }
            # ([AzState]::RegexIsResourceGroup).ToString() { <# pending development #> }
            ([AzState]::RegexIsSubscription).ToString() {
                $this.Type = [AzState]::GetTypeFromId($this.Raw.Id)
                $this.Name = $this.Raw.displayName
            }
            Default {}
        }
    }

    # Method to set Provider value based on Resource Type of object
    hidden [Void] SetProvider() {
        $this.Provider = ([AzStateProviders]::SearchCache($this.Type)).Provider
    }

    # Method to get Children based on Resource Type of object
    # Uses GetAzConfig to prevent circular loop caused by FromScope
    hidden [Object[]] GetChildren() {
        if (-not [AzState]::ParentMap) {
            [AzState]::ParentMap = [System.Collections.Concurrent.ConcurrentDictionary[String, String]]::new()
        }
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:children = [AzState]::GetAzConfig("$($this.Id)/descendants")
                # Update the ParentMap static property to improve Parent lookup
                # for future Management Group and Subscription discoveries
                foreach ($private:child in $private:children) {
                    [AzState]::ParentMap.TryAdd($private:child.id, $private:child.properties.parent.id)
                }
            }
            "Microsoft.Resources/subscriptions" {
                $private:children = [AzState]::GetAzConfig("$($this.Id)/resourceGroups")
            }
            "Microsoft.Resources/resourceGroups" {
                $private:children = [AzState]::GetAzConfig("$($this.Id)/resources")
            }
            Default { $private:children = $null }
        }
        return $private:children
    }

    # Method to set Children and LinkedResources based on Resource Type of object
    hidden [Void] SetChildren() {
        $this.Children = @()
        $this.LinkedResources = @()
        $private:GetChildren = $this.GetChildren()
        if ($private:GetChildren) {
            switch ($this.Type) {
                "Microsoft.Management/managementGroups" {
                    $this.Children = [AzStateSimple]::Convert(($private:GetChildren | Where-Object { $_.properties.parent.id -eq $this.Id }))
                    $this.LinkedResources = [AzStateSimple]::Convert(($private:GetChildren | Where-Object { $_.properties.parent.id -ne $this.Id }))
                }
                Default {
                    $this.Children = [AzStateSimple]::Convert($private:GetChildren)
                }
            }
        }
        else {
            $this.Children = $null
        }
    }

    # Method to get IAM configuration based on Resource Type of object
    hidden [AzStateIAM] GetIAM() {
        $private:AzStateIAM = [AzStateIAM]::new()
        foreach ($private:PathSuffix in [AzState]::IamPathSuffixes($this.Type)) {
            $private:IAMPath = $this.Id + $private:PathSuffix
            $private:IAMType = Split-Path ([AzState]::RegexUriParams.Replace($private:PathSuffix, "")) -Leaf
            $private:IAMItems = [AzState]::DirectFromScope($private:IAMPath)
            $private:AzStateIAM.$private:IAMType = [AzStateSimple]::Convert($private:IAMItems)
        }
        return $private:AzStateIAM
    }

    # Method to set IAM configuration based on Resource Type of object
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    hidden [Void] SetIAM() {
        $this.SetIAM([AzState]::DefaultDiscoveryMode)
    }

    # Method to set IAM configuration based on Resource Type of object
    # Sets DiscoveryMode to specified value
    hidden [Void] SetIAM([String]$DiscoveryMode) {
        $private:SupportedDiscoveryModes = @(
            "IncludeIAM"
            "IncludeBoth"
        )
        if ($DiscoveryMode -in $private:SupportedDiscoveryModes) {
            $private:IAM = $this.GetIAM()
            $this.IAM = $private:IAM
        }
    }

    # Method to get Policy configuration based on Resource Type of object
    hidden [AzStatePolicy] GetPolicy() {
        $private:AzStatePolicy = [AzStatePolicy]::new()
        foreach ($private:PathSuffix in [AzState]::PolicyPathSuffixes($this.Type)) {
            $private:PolicyPath = $this.Id + $private:PathSuffix
            $private:PolicyType = Split-Path ([AzState]::RegexUriParams.Replace($private:PathSuffix, "")) -Leaf
            $private:PolicyItems = [AzState]::DirectFromScope($private:PolicyPath)
            $private:AzStatePolicy.$private:PolicyType = [AzStateSimple]::Convert($private:PolicyItems)
        }
        return $private:AzStatePolicy
    }

    # Method to set Policy configuration based on Resource Type of object
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    hidden [Void] SetPolicy() {
        $this.SetPolicy([AzState]::DefaultDiscoveryMode)
    }

    # Method to set Policy configuration based on Resource Type of object
    # Sets DiscoveryMode to specified value
    hidden [Void] SetPolicy([String]$DiscoveryMode) {
        $private:SupportedDiscoveryModes = @(
            "IncludePolicy"
            "IncludeBoth"
        )
        if ($DiscoveryMode -in $private:SupportedDiscoveryModes) {
            $private:Policy = $this.GetPolicy()
            $this.Policy = $private:Policy
        }
    }

    # Method to determine the parent resource for the current AzState instance
    # Different resource types use different methods to determine the parent
    hidden [AzStateSimple] GetParent() {
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:parentId = $this.Raw.Properties.details.parent.id
                if ($private:parentId) {
                    $private:parent = [PsCustomObject]@{
                        Id   = $this.Raw.Properties.details.parent.id
                        Type = "Microsoft.Management/managementGroups"
                    }
                }
            }
            "Microsoft.Resources/subscriptions" {
                $private:CheckParentMap = [AzState]::ParentMap[$this.Id]
                if ($private:CheckParentMap) {
                    $private:parent = $private:CheckParentMap
                    $private:parent = [PsCustomObject]@{
                        Id   = $private:CheckParentMap
                        Type = [AzState]::GetTypeFromId($private:CheckParentMap)
                    }
                }
                else {
                    $private:managementGroups = [AzState]::FromScope("/providers/Microsoft.Management/managementGroups")
                    $private:searchParent = $private:managementGroups | Where-Object { $_.Children.Id -Contains "$($this.Id)" }
                    $private:parent = [AzStateSimple]::new($private:searchParent)
                }
            }
            "Microsoft.Resources/resourceGroups" {
                $private:parent = [PsCustomObject]@{
                    Id   = [AzState]::RegexExtractSubscriptionId.Match($this.Id).value
                    Type = "Microsoft.Resources/subscriptions"
                }
            }
            Default {
                $private:ScopeId = [AzState]::RegexExtractProviderScope.Match($this.Id).value
                if ($private:ScopeId) {
                    $private:parent = [PsCustomObject]@{
                        Id   = $private:ScopeId
                        Type = [AzState]::GetTypeFromId($private:ScopeId)
                    }
                }
                else {
                    $private:parent = $null
                }
            }
        }
        return [AzStateSimple]::new($private:parent)
    }


    hidden [AzStateSimple] GetParent([String]$Id) {
        # Need to wrap in Try/Catch block to gracefully handle limited permissions on parent resources
        try {
            $private:Parent = [AzState]::new($Id).GetParent()
        }
        catch {
            Write-Warning $_.Exception.Message
            return $null
        }
        return $private:Parent
    }

    hidden [Void] SetParent() {
        $this.Parent = $this.GetParent()
    }

    hidden [System.Collections.Specialized.OrderedDictionary] GetParents() {
        # Need to create an ordered Hashtable to ensure correct order of parents when reversing
        $private:parents = [ordered]@{}
        # Start by setting the current parentId from the current [AzState]
        $private:parent = ($this.Parent) ?? ($this.GetParent())
        $private:count = 0
        # Start a loop to find the next parentId from the current parentId
        while ($private:parent.Id) {
            $private:count ++
            Write-Verbose "Adding Parent [$($private:parent.Id)] ($($private:count))"
            $private:parents += @{ $private:count = $private:parent }
            $private:parent = $this.GetParent($private:parent.Id)
        }
        return $private:parents
    }

    hidden [Void] SetParents() {
        # Get Parents
        [System.Collections.Specialized.OrderedDictionary]$private:GetParents = $this.GetParents()
        [AzStateSimple[]]$private:parents = @()
        # Return all parent IDs to $this.Parents as string array
        foreach ($parent in $private:GetParents.GetEnumerator() | Sort-Object -Property Key -Descending) {
            $private:parents += $parent.value
        }
        $this.Parents = $private:parents
        # Create an ordered path of parent names from the parent
        # ID in string format and save to ParentPath attribute
        if ($private:parents) {
            [String]$private:parentPath = ""
            foreach ($parent in $private:parents.Id) {
                $private:parentPath = $private:parentPath + [AzState]::RegexBeforeLastForwardSlash.Replace($parent, "")
            }
        }
        else {
            [String]$private:parentPath = "/"
        }
        $this.ParentPath = $private:parentPath.ToString()
    }

    hidden [String] GetResourcePath() {
        $private:ResourcePath = $this.ParentPath
        if ($private:ResourcePath -ne "/") {
            $private:ResourcePath = $private:ResourcePath + "/"
        }
        $private:ResourcePath = $private:ResourcePath + [AzState]::RegexAfterLastForwardSlash.Match($this.Id).Value
        return $private:ResourcePath
    }

    hidden [Void] SetResourcePath() {
        $this.ResourcePath = $this.GetResourcePath().ToString()
    }

    # Method to return a string list of IDs for Role Assignments
    # at the current object scope
    [String[]] GetRoleAssignmentsAtScope() {
        return $this.IAM.RoleAssignments.Id | Where-Object { $RegexExtractProviderScope.Match($_).Value -eq $this.Id }
    }

    # Method to return a string list of IDs for Role Definitions
    # at the current object scope
    [String[]] GetRoleDefinitionsAtScope() {
        return $this.IAM.RoleDefinitions.Id | Where-Object { [AzState]::RegexExtractProviderScope.Match($_).Value -eq $this.Id }
    }

    # Method to return a string list of IDs for Policy Assignments
    # at the current object scope
    [String[]] GetPolicyAssignmentsAtScope() {
        return $this.Policy.PolicyAssignments.Id | Where-Object { [AzState]::RegexExtractProviderScope.Match($_).Value -eq $this.Id }
    }

    # Method to return a string list of IDs for Policy Definitions
    # at the current object scope
    [String[]] GetPolicyDefinitionsAtScope() {
        return $this.Policy.PolicyDefinitions.Id | Where-Object { [AzState]::RegexExtractProviderScope.Match($_).Value -eq $this.Id }
    }

    # Method to return a string list of IDs for Policy Set Definitions
    # at the current object scope
    [String[]] GetPolicySetDefinitionsAtScope() {
        return $this.Policy.PolicySetDefinitions.Id | Where-Object { [AzState]::RegexExtractProviderScope.Match($_).Value -eq $this.Id }
    }

    # ------------------------------------------------------------ #
    # IMPROVEMENT: Consider moving to new class or function for [Terraform]
    hidden [String] Terraform() {
        $private:dotTf = @()
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:subscriptions = $this.Children `
                | Where-Object { $_.type -match "/subscriptions$" }
                $private:dotTf += "resource `"azurerm_management_group`" `"{0}`" {{" -f ($this.Id -replace "[^\w]", "_")
                $private:dotTf += "  display_name = `"{0}`"" -f $this.Name
                $private:dotTf += ""
                if ($this.Parent.Id) {
                    $private:dotTf += "  parent_management_group_id = `"{0}`"" -f $this.Parent.Id
                    $private:dotTf += ""
                }
                if ($private:subscriptions) {
                    $private:dotTf += "  subscription_ids = ["
                    foreach ($private:subscription in $private:subscriptions) {
                        $private:dotTf += "    `"{0}`"," -f ($private:subscription.Id -replace "/subscriptions/", "")
                    }
                    $private:dotTf += "  ]"
                }
                $private:dotTf += "}"
                $private:dotTf += ""
            }
            "Microsoft.Resources/subscriptions" {
                $private:dotTf += "data `"azurerm_subscription`" `"{0}`" {{" -f ($this.Id -replace "[^\w]", "_")
                $private:dotTf += "  subscription_id = `"{0}`"" -f $this.Raw.subscriptionId
                $private:dotTf += "}"
                $private:dotTf += ""
            }
            "Microsoft.Resources/resourceGroups" {
                $private:subscriptions = $this.Children `
                | Where-Object { $_.type -match "/subscriptions$" }
                $private:dotTf += "resource `"azurerm_resource_group`" `"{0}`" {{" -f ($this.Id -replace "[^\w]", "_")
                $private:dotTf += "  name     = `"{0}`"" -f $this.Name
                $private:dotTf += "  location = `"{0}`"" -f $this.Raw.Location
                if ($this.Raw.Tags.psobject.properties.count -ge 1) {
                    $private:dotTf += ""
                    $private:dotTf += "  tags = {"
                    foreach ($Tag in $this.Raw.Tags.psobject.properties) {
                        $private:dotTf += "    `"{0}`" = `"{1}`"" -f $Tag.Name, $Tag.Value
                    }
                    $private:dotTf += "  }"
                }
                $private:dotTf += "}"
                $private:dotTf += ""
            }
            Default {
                Write-Warning "Resource type [$($this.Type)] not currently supported in method Terraform()"
                $private:dotTf = $null
            }
        }
        return $private:dotTf -join "`n"
    }

    hidden [Void] SaveTerraform([String]$Path) {
        # WIP: Requires additional work
        if (-not (Test-Path -Path $Path -PathType Container)) {
            $this.Terraform() | Out-File -FilePath $Path -Encoding "UTF8" -NoClobber
        }
    }

    # ------------------------------------------------------------ #
    # Static method to get "Type" value from "Id" using RegEx pattern matching
    # IMPROVEMENT - need to consider situations where an ID may contain multi-level
    # Resource Types within the same provider
    hidden static [String] GetTypeFromId([String]$Id) {
        switch -regex ($Id) {
            ([AzState]::RegexProviderTypeFromId).ToString() {
                $private:TypeFromId = [AzState]::RegexProviderTypeFromId.Match($Id).Value
            }
            ([AzState]::RegexIsResource).ToString() {
                $private:TypeFromId = "Microsoft.Resources/resources"
            }
            ([AzState]::RegexIsResourceGroup).ToString() {
                $private:TypeFromId = "Microsoft.Resources/resourceGroups"
            }
            ([AzState]::RegexIsSubscription).ToString() {
                $private:TypeFromId = "Microsoft.Resources/subscriptions"
            }
            Default { $private:TypeFromId = $null }
        }
        Write-Verbose "Resource Type [$private:TypeFromId] identified from Id [$Id]"
        return $private:TypeFromId
    }

    # ------------------------------------------------------------ #
    # Static method to get "Path" value from Id and Type, for use with Invoke-AzRestMethod
    # Relies on the following additional static methods:
    #  -- [AzStateProviders]::GetApiParamsByType(Id, Type)
    hidden static [String] GetAzRestMethodPath([String]$Id, [String]$Type) {
        $private:AzRestMethodPath = $Id + [AzStateProviders]::GetApiParamsByType($Type)
        # The following RegEx replace ensures support for generating
        # a valid path from a URI containing existing params
        $private:AzRestMethodPath = [AzState]::RegexQuestionMarksAfterFirst.Replace($private:AzRestMethodPath, "&")
        Write-Verbose "Resource Path [$private:AzRestMethodPath]"
        return $private:AzRestMethodPath
    }

    # Static method to get "Path" value from Id, for use with Invoke-AzRestMethod
    # Relies on the following additional static methods:
    #  -- [AzState]::GetTypeFromId(Id)
    #    |-- [AzState]::GetAzRestMethodPath(Id, Type)
    #       |-- [AzStateProviders]::GetApiParamsByType(Id, Type)
    hidden static [String] GetAzRestMethodPath([String]$Id) {
        $private:Type = [AzState]::GetTypeFromId($Id)
        return [AzState]::GetAzRestMethodPath($Id, $private:Type)
    }

    # ------------------------------------------------------------ #
    # Static method to simplify running Invoke-AzRestMethod using provided Id only
    # Relies on the following additional static methods:
    #  -- [AzState]::GetAzRestMethodPath(Id)
    #    |-- [AzState]::GetTypeFromId(Id)
    #       |-- [AzState]::GetAzRestMethodPath(Id, Type)
    #          |-- [AzStateProviders]::GetApiParamsByType(Id, Type)

    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    hidden static [PsCustomObject] GetAzRestMethod([String]$Id) {
        return [AzState]::GetAzRestMethod($Id, [AzState]::DefaultCacheMode)
    }

    # Sets UseCache to specified value
    hidden static [PsCustomObject] GetAzRestMethod([String]$Id, [CacheMode]$CacheMode) {
        $private:AzRestMethodUri = [AzState]::GetAzRestMethodPath($Id)
        if (($CacheMode -eq "UseCache") -and [AzState]::InRestCache($private:AzRestMethodUri)) {
            $private:SearchRestCache = [AzState]::SearchRestCache($private:AzRestMethodUri)
            Write-Verbose "GetAzRestMethod (FROM CACHE) [$($private:AzRestMethodUri)]"
            $private:PSHttpResponse = $private:SearchRestCache
        }
        else {
            Write-Verbose "GetAzRestMethod (FROM API) [$private:AzRestMethodUri]"
            $private:PSHttpResponse = Invoke-AzRestMethod -Method GET -Path $private:AzRestMethodUri
            if ($private:PSHttpResponse.StatusCode -ne 200) {
                $private:ErrorBody = ($private:PSHttpResponse.Content | ConvertFrom-Json).error
                Write-Error "Invalid response from API:`n StatusCode=$($private:PSHttpResponse.StatusCode)`n ErrorCode=$($private:ErrorBody.code)`n ErrorMessage=$($private:ErrorBody.message)"
                break
            }
            $private:AddToRestCache = [AzStateRestCache]::new($private:AzRestMethodUri, $private:PSHttpResponse)
            [AzState]::AddToRestCache($private:AddToRestCache)
        }
        return $private:PSHttpResponse
    }

    # ------------------------------------------------------------ #
    # Static method to return Resource configuration from Azure using provided Id to modify scope
    # Will return multiple items for IDs scoped at a Resource Type level (e.g. "/subscriptions")
    # Will return a single item for IDs scoped at a Resource level (e.g. "/subscriptions/{subscription_id}")
    # Relies on the following additional static methods:
    #  -- [AzState]::GetAzRestMethod(Id)
    #    |-- [AzState]::GetAzRestMethodPath(Id)
    #       |-- [AzState]::GetTypeFromId(Id)
    #          |-- [AzState]::GetAzRestMethodPath(Id, Type)
    #             |-- [AzStateProviders]::GetApiParamsByType(Id, Type)

    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    hidden static [PsCustomObject[]] GetAzConfig([String]$Id) {
        return [AzState]::GetAzConfig($Id, [AzState]::DefaultCacheMode)
    }

    # Sets UseCache to specified value
    hidden static [PSCustomObject[]] GetAzConfig([String]$Id, [CacheMode]$CacheMode) {
        $private:AzConfigJson = ([AzState]::GetAzRestMethod($Id, $CacheMode)).Content
        if ($private:AzConfigJson | Test-Json) {
            $private:AzConfig = $private:AzConfigJson | ConvertFrom-Json
        }
        else {
            Write-Error "Unknown content type found in response."
            break
        }
        if (($private:AzConfig.value) -and ($private:AzConfig.psobject.properties.count -eq 1)) {
            $private:AzConfigResourceCount = $private:AzConfig.value.Count
            Write-Verbose "GetAzConfig [$Id] contains [$private:AzConfigResourceCount] resources."
            return $private:AzConfig.Value
        }
        else {
            return $private:AzConfig
        }
    }

    # ------------------------------------------------------------ #
    # Static methods to support returning multiple AzState objects from defined scope
    # Uses object returned from scope query to create AzState with optimal performance
    # Not all resources can use this due to missing properties in scope-level response
    # (e.g. managementGroups)

    # Sets ThrottleLimit to 0
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    static [AzState[]] DirectFromScope([String[]]$Scope) {
        return [AzState]::FromScope($Scope, 0, [AzState]::DefaultCacheMode)
    }

    # Sets ThrottleLimit to 0
    # Sets CacheMode to specified value
    static [AzState[]] DirectFromScope([String[]]$Scope, [CacheMode]$CacheMode) {
        return [AzState]::FromScope($Scope, 0, $CacheMode)
    }

    # ------------------------------------------------------------ #
    # Static methods to support returning multiple AzState objects from defined scope
    # Uses Id of value to perform full lookup of Resource from ARM Rest API

    # Sets ThrottleLimit to 1
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    static [AzState[]] FromScope([String[]]$Scope) {
        return [AzState]::FromScope($Scope, 1, [AzState]::DefaultCacheMode)
    }

    # Sets ThrottleLimit to 1
    # Sets CacheMode to specified value
    static [AzState[]] FromScope([String[]]$Scope, [CacheMode]$CacheMode) {
        return [AzState]::FromScope($Scope, 1, $CacheMode)
    }

    # ------------------------------------------------------------ #
    # Static methods to support returning multiple AzState objects from defined scope
    # using multiple thread jobs to enable parallel processing
    # Supports multiple input IDs to enable parallel processing across multiple
    # items not grouped under a single scope ID

    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    static [AzState[]] FromScopeParallel([String[]]$Scope) {
        return [AzState]::FromScopeParallel($Scope, [AzState]::DefaultCacheMode)
    }

    # Sets ThrottleLimit to value based on either AzStateThrottleLimit variable
    # (if present) or the default value set by [AzState]::DefaultThrottleLimit
    # Sets CacheMode to specified value
    static [AzState[]] FromScopeParallel([String[]]$Scope, [CacheMode]$CacheMode) {
        # The AzStateThrottleLimit variable can be set to allow
        # performance tuning based on system resources
        $private:ThrottleLimit = Get-Variable -Name AzStateThrottleLimit -ErrorAction Ignore
        if (-not $private:ThrottleLimit) {
            $private:ThrottleLimit = [AzState]::DefaultThrottleLimit
        }
        return [AzState]::FromScope($Scope, $private:ThrottleLimit, $CacheMode)
    }

    # Sets ThrottleLimit to specified value
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    static [AzState[]] FromScopeParallel([String[]]$Scope, [Int]$ThrottleLimit) {
        return [AzState]::FromScope($Scope, $ThrottleLimit, [AzState]::DefaultCacheMode)
    }

    # Sets ThrottleLimit to specified value
    # Sets CacheMode to specified value
    static [AzState[]] FromScopeParallel([String[]]$Scope, [Int]$ThrottleLimit, [CacheMode]$CacheMode) {
        return [AzState]::FromScope($Scope, $ThrottleLimit, $CacheMode)
    }

    # ------------------------------------------------------------ #
    # Static method to support returning multiple AzState objects from defined scope
    # Runs in 3 modes:
    #   1. Direct   : Supports the DirectFromScope method
    #   2. Single   : Supports the FromScope method
    #   3. Parallel : Supports the FromScopeParallel method
    # Sets ThrottleLimit to specified value
    # Sets CacheMode to specified value
    static [AzState[]] FromScope([String[]]$Scope, [Int]$ThrottleLimit, [CacheMode]$CacheMode) {
        Write-Verbose "[FromScope] initialized with CacheMode [$CacheMode]"
        $private:AzConfigAtScope = @()
        $private:FromScope = @()
        # Get AzConfig for all scope items ready to process
        foreach ($private:Id in $Scope) {
            Write-Verbose "[FromScope] processing [$private:Id]"
            $private:AzConfigAtScope += [AzState]::GetAzConfig($private:Id, $CacheMode)
        }
        $private:AzConfigAtScopeCount = $private:AzConfigAtScope.Count
        # The following optimises processing by auto-disabling parallel thread
        # jobs when only 1 result needs processing in AzConfigAtScope
        if (($ThrottleLimit -gt 1) -and ($private:AzConfigAtScopeCount -eq 1)) {
            Write-Verbose "[FromScope] Auto-disabling parallel processing as only [1] result found in scope"
            $ThrottleLimit = 1
        }
        switch ($ThrottleLimit) {
            0 {
                # Converts all objects directly from AzConfig to AzState
                Write-Verbose "[FromScope] running in [direct] mode to process [$private:AzConfigAtScopeCount] resources"
                $private:AzConfigAtScope | ForEach-Object {
                    Write-Verbose "[FromScope] generating AzState for [$($_.Id)]"
                    $private:FromScope += [AzState]::new($_, $CacheMode)
                }
            }
            1 {
                # Generates AzState object from each Id within scope
                Write-Verbose "[FromScope] running in [single] mode to process [$private:AzConfigAtScopeCount] resources"
                $private:AzConfigAtScope.Id | ForEach-Object {
                    Write-Verbose "[FromScope] generating AzState for [$_]"
                    $private:FromScope += [AzState]::new($_, $CacheMode)
                }
            }
            Default {
                # Generates AzState object from each Id within scope using ThrottleLimit
                # value to determine the maximum number of parallel threads to use
                Write-Verbose "[FromScope] running in [parallel] mode to process [$private:AzConfigAtScopeCount] using [FromIds] method"
                # Set up and run the parallel processing runspace
                $private:FromScope += [AzState]::FromIds($private:AzConfigAtScope.Id, $ThrottleLimit, $CacheMode)
            }
        }
        return $private:FromScope
    }

    # ------------------------------------------------------------ #
    # Static methods to support returning multiple AzState objects from input IDs
    # using multiple thread jobs to enable parallel processing

    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    static [AzState[]] FromIds([String[]]$Ids) {
        return [AzState]::FromIds($Ids, [AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    static [AzState[]] FromIds([String[]]$Ids, [CacheMode]$CacheMode) {
        return [AzState]::FromIds($Ids, $CacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    static [AzState[]] FromIds([String[]]$Ids, [DiscoveryMode]$DiscoveryMode) {
        return [AzState]::FromIds($Ids, [AzState]::DefaultCacheMode, $DiscoveryMode)
    }

    # Sets ThrottleLimit to value based on either AzStateThrottleLimit variable
    # (if present) or the default value set by [AzState]::DefaultThrottleLimit
    # Sets CacheMode to specified value
    static [AzState[]] FromIds([String[]]$Ids, [CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        # The AzStateThrottleLimit variable can be set to allow
        # performance tuning based on system resources
        $private:ThrottleLimit = Get-Variable -Name AzStateThrottleLimit -ErrorAction Ignore
        if (-not $private:ThrottleLimit) {
            $private:ThrottleLimit = [AzState]::DefaultThrottleLimit
        }
        return [AzState]::FromIds($Ids, $private:ThrottleLimit, $CacheMode, $DiscoveryMode)
    }

    # Sets ThrottleLimit to specified value
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    static [AzState[]] FromIds([String[]]$Ids, [Int]$ThrottleLimit) {
        return [AzState]::FromIds($Ids, $ThrottleLimit, [AzState]::DefaultCacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Sets ThrottleLimit to specified value
    # Sets CacheMode to specified value
    # Sets DiscoveryMode to default value from [AzState]::DefaultDiscoveryMode
    static [AzState[]] FromIds([String[]]$Ids, [Int]$ThrottleLimit, [CacheMode]$CacheMode) {
        return [AzState]::FromIds($Ids, $ThrottleLimit, $CacheMode, [AzState]::DefaultDiscoveryMode)
    }

    # Sets ThrottleLimit to specified value
    # Sets CacheMode to default value from [AzState]::DefaultCacheMode
    # Sets DiscoveryMode to specified value
    static [AzState[]] FromIds([String[]]$Ids, [Int]$ThrottleLimit, [DiscoveryMode]$DiscoveryMode) {
        return [AzState]::FromIds($Ids, $ThrottleLimit, [AzState]::DefaultCacheMode, $DiscoveryMode)
    }

    # Sets ThrottleLimit to specified value
    # Sets CacheMode to specified value
    static [AzState[]] FromIds([String[]]$Ids, [Int]$ThrottleLimit, [CacheMode]$CacheMode, [DiscoveryMode]$DiscoveryMode) {
        $private:FromIds = @()
        $private:IncludeIAM = $false
        $private:IncludePolicy = $false
        $private:SkipCache = $false
        if ($CacheMode -eq "SkipCache") {
            $private:SkipCache = $true
        }
        if ($DiscoveryMode -eq "IncludeBoth") {
            $private:IncludeIAM = $true
            $private:IncludePolicy = $true
        }
        if ($DiscoveryMode -eq "IncludeIAM") {
            $private:IncludeIAM = $true
        }
        if ($DiscoveryMode -eq "IncludePolicy") {
            $private:IncludePolicy = $true
        }
        # The following removes items with no value if sent from upstream commands
        $Ids = $Ids | Where-Object { $_ -ne "" }
        $private:IdsCount = $Ids.Count
        Write-Verbose "[FromIds] running in [parallel] mode with maximum [$ThrottleLimit] threads to process [$private:IdsCount] resources"
        # Set up and run the parallel processing runspace
        $FromIdsThreadSafeAzState = [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]::new()
        $FromIdsJobs = $Ids | ForEach-Object {
            Write-Verbose "[FromIds] adding thread job to queue for [$_]"
            Start-ThreadJob -Name $_ `
                -ThrottleLimit $ThrottleLimit `
                -ArgumentList $_, $private:IncludeIAM, $private:IncludePolicy, $private:SkipCache `
                -ScriptBlock {
                param ([Parameter()][String]$ScopeId, $IncludeIAM, $IncludePolicy, $SkipCache)
                $InformationPreference = $using:InformationPreference
                $VerbosePreference = $using:VerbosePreference
                $DebugPreference = $using:DebugPreference
                Write-Information "[FromIds] generating AzState for [$ScopeId]"
                $private:AzStateObject = New-AzState -Id $ScopeId -IncludeIAM:$IncludeIAM -IncludePolicy:$IncludePolicy -SkipCache:$SkipCache
                $FromIdsAzStateTracker = $using:FromIdsThreadSafeAzState
                $FromIdsAzStateTracker.TryAdd($private:AzStateObject.Id, $private:AzStateObject)
            }
        }
        $FromIdsJobs | Receive-Job -Wait -AutoRemoveJob
        # The following is used to ensure the object returned from the Threadjob
        # is correctly initialized as a valid AzState object, to avoid the error
        # OperationStopped: Object reference not set to an instance of an object.
        $FromIdsThreadSafeAzState.Values | ForEach-Object {
            $private:AzState = New-AzState
            $private:AzState.Initialize($_, $CacheMode, $DiscoveryMode, $true)
            $private:FromIds += $private:AzState
        }
        # Finally return the array of AzState values from the threadsafe dictionary
        return $private:FromIds
    }

    #---------------#
    # AzState Cache #
    #---------------#

    # Static property to store cache of AzState using a threadsafe
    # dictionary variable to allow caching across parallel jobs for
    # performance improvements when building the AzState hierarchy
    # https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/foreach-object#example-14--using-thread-safe-variable-references
    hidden static [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]$Cache

    # Static method to show all entries in Cache
    static [AzState[]] ShowCache() {
        return ([AzState]::Cache).Values
    }

    # Static method to show all entries in Cache matching the specified resource Id
    hidden static [AzState[]] SearchCache([String]$Id) {
        if ([AzState]::DefaultCacheCaseSenstive) {
            return [AzState]::Cache[$Id]
        }
        else {
            return [AzState]::Cache[$Id.ToLower()]
        }
    }

    # Static method to return [Boolean] for Resource in Cache query
    hidden static [Boolean] InCache([String]$Id) {
        if ([AzState]::Cache -and [AzState]::DefaultCacheCaseSenstive) {
            return ([AzState]::Cache).ContainsKey($Id)
        }
        elseif ([AzState]::Cache) {
            return ([AzState]::Cache).ContainsKey($Id.ToLower())
        }
        else {
            # The following prevents needing to initialize the cache
            # manually if not exist on first attempt to use
            [AzState]::InitializeCache()
            return $false
        }
    }

    # Static method to update all entries in Cache
    hidden static [Void] UpdateCache() {
        $private:IdListFromCache = [AzState]::ShowCache().Id
        [AzState]::ClearCache()
        foreach ($private:Id in $private:IdListFromCache) {
            [AzState]::new($private:Id)
        }
    }

    # Static method to add AzState object to Cache
    hidden static [Void] AddToCache([AzState[]]$AddToCache) {
        # The following prevents needing to initialize the cache
        # manually if not exist on first attempt to use
        if (-not [AzState]::Cache) {
            [AzState]::InitializeCache()
        }
        foreach ($AzState in $AddToCache) {
            if ([AzState]::DefaultCacheCaseSenstive) {
                $AddedToCache = [AzState]::Cache.TryAdd($AzState.Id, $AzState)
            }
            else {
                $AddedToCache = [AzState]::Cache.TryAdd($AzState.Id.ToLower(), $AzState)
            }
            if ($AddedToCache) {
                Write-Verbose "Added Resource to AzState Cache [$($AzState.Id)]"
            }
        }
    }

    # Static method to initialize Cache
    # Will also reset cache if exists
    hidden static [Void] InitializeCache() {
        Write-Verbose "Initializing AzState cache (Empty)"
        [AzState]::Cache = [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]::new()
    }

    # Static method to initialize Cache from copy of cache stored in input variable
    hidden static [Void] InitializeCache([System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]$AzStateCache) {
        Write-Verbose "Initializing AzState Cache (From Copy)"
        [AzState]::Cache = $AzStateCache
    }

    # Static method to clear all entries from Cache
    static [Void] ClearCache() {
        [AzState]::InitializeCache()
    }

    #--------------------#
    # AzRestMethod Cache #
    #--------------------#

    # Static property to store cache of AzConfig using a threadsafe
    # dictionary variable to allow caching across parallel jobs for
    # performance improvements when building the AzState hierarchy
    # https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/foreach-object#example-14--using-thread-safe-variable-references
    hidden static [System.Collections.Concurrent.ConcurrentDictionary[String, Object]]$RestCache

    # Static method to show all entries in Rest Cache
    static [PsCustomObject[]] ShowRestCache() {
        return ([AzState]::RestCache).Values
    }

    # Static method to show all entries in Rest Cache matching the specified Uri
    hidden static [PsCustomObject[]] SearchRestCache([String]$Uri) {
        if ([AzState]::DefaultCacheCaseSenstive) {
            return [AzState]::RestCache[$Uri]
        }
        else {
            return [AzState]::RestCache[$Uri.ToLower()]
        }
    }

    # Static method to return [Boolean] for Response in Rest Cache query
    hidden static [Boolean] InRestCache([String]$Uri) {
        if ([AzState]::RestCache -and [AzState]::DefaultCacheCaseSenstive) {
            return ([AzState]::RestCache).ContainsKey($Uri)
        }
        elseif ([AzState]::RestCache) {
            return ([AzState]::RestCache).ContainsKey($Uri.ToLower())
        }
        else {
            # The following prevents needing to initialize the cache
            # manually if not exist on first attempt to use
            [AzState]::InitializeRestCache()
            return $false
        }
    }

    # Static method to add Response to Rest Cache
    # Using the custom [AzStateRestCache[]] class for the input type allows multiple
    # items to be uploaded to the cache at once in a known valid format
    hidden static [Void] AddToRestCache([AzStateRestCache[]]$AddToCache) {
        # The following prevents needing to initialize the cache
        # manually if not exist on first attempt to use
        if (-not [AzState]::RestCache) {
            [AzState]::InitializeRestCache()
        }
        foreach ($Response in $AddToCache) {
            if ([AzState]::DefaultCacheCaseSenstive) {
                $AddedToCache = [AzState]::RestCache.TryAdd($Response.Key, $Response.Value)
            }
            else {
                $AddedToCache = [AzState]::RestCache.TryAdd($Response.Key.ToLower(), $Response.Value)
            }
            if ($AddedToCache) {
                Write-Verbose "Added API Response to Cache [$($Response.Key)]"
            }
        }
    }

    # Static method to initialize Cache
    # Will also reset cache if exists
    hidden static [Void] InitializeRestCache() {
        Write-Verbose "Initializing Rest cache (Empty)"
        [AzState]::RestCache = [System.Collections.Concurrent.ConcurrentDictionary[String, Object]]::new()
    }

    # Static method to clear all entries from Cache
    static [Void] ClearRestCache() {
        [AzState]::InitializeRestCache()
    }

}
