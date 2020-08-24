############################################
# Custom enum data sets used within module #
############################################

enum SkipCache {
    SkipCache
}

enum Release {
    stable
    latest
}

#####################################
# Custom classes used within module #
#####################################

# AzStateProviders class is used to create cache of latest API version for all Azure Providers
# This can be used to dynamically retrieve the latest or stable API version in string format
# Can also output the API version as a param string for use within a Rest API request
# To minimise the number of Rest API requests needed, this class creates a cache and populates
# it with all results from the request. The cache is then used to return the requested result.
class AzStateProviders {

    # Public class properties
    [String]$Provider
    [String]$ResourceType
    [String]$Type
    [String]$ApiVersion
    [Release]$Release

    # Static properties
    hidden static [String]$ProvidersApiVersion = "2020-06-01"

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
        return [AzStateProviders]::GetApiVersionByType($Type, "stable")
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
        return [AzStateProviders]::SearchCache($Type, "stable")
    }

    # Static method to show all entries in Cache matching the specified type using the specified release type
    static [AzStateProviders[]] SearchCache([String]$Type, [Release]$Release) {
        return [AzStateProviders]::Cache["$Type ($Release)"]
    }

    # Static method to return [Boolean] for Resource Type in Cache query using default stable release type
    static [Boolean] InCache([String]$Type) {
        return [AzStateProviders]::InCache($Type, "stable")
    }

    # Static method to return [Boolean] for Resource Type in Cache query using the specified release type
    static [Boolean] InCache([String]$Type, [Release]$Release) {
        if ([AzStateProviders]::Cache) {
            $private:InCache = ([AzStateProviders]::Cache).ContainsKey("$Type ($Release)")
            if ($private:InCache) {
                Write-Verbose "Resource Type [$Type] ($Release) found in AzStateProviders cache."
            }
            else {
                Write-Verbose "Resource Type [$Type] ($Release) not found in AzStateProviders cache."
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
            Write-Verbose "Processing Provider Namespace [$($private:Provider.namespace)]"
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
        Write-Debug "Adding [$($Provider)/$($ResourceType)] to cache with $Release Api-Version [$ApiVersion]"
        $private:AzStateProviderObject = [PsCustomObject]@{
            Provider     = "$Provider"
            ResourceType = "$ResourceType"
            Type         = "$Provider/$ResourceType"
            ApiVersion   = "$ApiVersion"
            Release      = "$Release"
        }
        $private:KeyToAdd = "$Provider/$ResourceType ($Release)"
        $private:ValueToAdd = [AzStateProviders]::new($private:AzStateProviderObject)
        $private:TryAdd = ([AzStateProviders]::Cache).TryAdd($private:KeyToAdd, $private:ValueToAdd)
        if ($private:TryAdd) {
            Write-Verbose "Added Resource Type to AzStateProviders Cache [$private:KeyToAdd]"
        }
    }

    # Static method to initialize Cache
    # Will also reset cache if exists
    static [Void] InitializeCache() {
        Write-Verbose "Initializing AzStateProviders cache (Empty)"
        [AzStateProviders]::Cache = [System.Collections.Concurrent.ConcurrentDictionary[String, AzStateProviders]]::new()
    }

    # Static method to initialize Cache from copy of cache stored in input variable
    static [Void] InitializeCache([System.Collections.Concurrent.ConcurrentDictionary[String, AzStateProviders]]$AzStateProvidersCache) {
        Write-Verbose "Initializing AzStateProviders Cache (From Copy)"
        [AzState]::Cache = $AzStateProvidersCache
    }

    # Static method to clear all entries from Cache
    static [Void] ClearCache() {
        [AzStateProviders]::InitializeCache()
    }

}

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

class AzStateIAM {

    # Public class properties
    [AzStateSimple[]]$RoleDefinitions = @()
    [AzStateSimple[]]$RoleAssignments = @()

    AzStateIAM() {
        $this.RoleDefinitions = @()
        $this.RoleAssignments = @()
    }

}

# class AzStateCache {

# For future use

#     # Static properties
#     static [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]$AzStateCache = [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]::new()
#     static [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]$AzStateProvidersCache = [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]::new()


# }

# AzState class used to create and update new AsOpsState objects
# This is the primary module class containing all logic for managing AzState for Azure Resources
class AzState {

    # Public class properties
    [String]$Id
    [String]$Type
    [String]$Name
    [Object]$Properties
    [Object]$ExtendedProperties
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
    hidden static [String[]]$DefaultProperties = "Id", "Type", "Name", "Properties"

    # Regex patterns for use within methods
    hidden static [Regex]$RegexBeforeLastForwardSlash = "(?i)^.*(?=\/)"
    hidden static [Regex]$RegexIsGuid = "[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}"
    hidden static [Regex]$RegexProviderTypeFromId = "(?i)(?<=\/providers\/)(?!.*\/providers\/)[^\/]+\/[\w-]+"
    hidden static [Regex]$RegexIsSubscription = "(?i)(\/subscriptions)(?!\/.*\/)"
    hidden static [Regex]$RegexIsResourceGroup = "(?i)(\/resourceGroups)(?!\/.*\/)"
    hidden static [Regex]$RegexIsResource = "(?i)(\/resources)(?!\/.*\/)"
    hidden static [Regex]$RegexExtractSubscriptionId = "(?i)^(\/subscriptions\/)[^\/]{36}((?![^\/])|$)"
    hidden static [Regex]$RegexExtractResourceGroupId = "(?i)^(\/subscriptions\/)[^\/]{36}(\/resourceGroups\/)[^\/]+((?![^\/])|$)"

    # Static method to return list of policy types supported by Resource
    hidden static [String[]] PolicyResourceTypes($Type) {
        switch ($Type) {
            { $Type -in "Microsoft.Management/managementGroups", "Microsoft.Resources/subscriptions" } {
                $private:PolicyResourceTypes = @(
                    "Microsoft.Authorization/policyDefinitions"
                    "Microsoft.Authorization/policySetDefinitions"
                    # "Microsoft.Authorization/policyAssignments"
                    # "Microsoft.Authorization/roleDefinitions"
                    # "Microsoft.Authorization/roleAssignments"
                )
            }
            "Microsoft.Resources/resourceGroups" {
                $private:PolicyResourceTypes = @(
                    # "Microsoft.Authorization/policyAssignments"
                    # "Microsoft.Authorization/roleDefinitions"
                    # "Microsoft.Authorization/roleAssignments"
                )
            }
            Default {
                $private:PolicyResourceTypes = @(
                    # "Microsoft.Authorization/policyAssignments"
                    # "Microsoft.Authorization/roleDefinitions"
                    # "Microsoft.Authorization/roleAssignments"
                )
            }
        }
        return $private:PolicyResourceTypes
    }

    # Static method to return list of Access control (IAM) types supported by Resource
    hidden static [String[]] IamResourceTypes($Type) {
        switch ($Type) {
            { $Type -in "Microsoft.Management/managementGroups", "Microsoft.Resources/subscriptions" } {
                $private:IamResourceTypes = @(
                    "Microsoft.Authorization/roleDefinitions"
                    "Microsoft.Authorization/roleAssignments"
                )
            }
            "Microsoft.Resources/resourceGroups" {
                $private:IamResourceTypes = @(
                    # "Microsoft.Authorization/roleDefinitions"
                    # "Microsoft.Authorization/roleAssignments"
                )
            }
            Default {
                $private:IamResourceTypes = @(
                    # "Microsoft.Authorization/roleDefinitions"
                    # "Microsoft.Authorization/roleAssignments"
                )
            }
        }
        return $private:IamResourceTypes
    }

    # Default empty constructor
    AzState() {
    }

    # Default constructor with Resource Id input
    # Uses Update() method to auto-populate from Resource Id if resource not found in Cache
    AzState([String]$Id) {
        if ([AzState]::InCache($Id)) {
            Write-Verbose "New-AzState (FROM CACHE) [$Id]"
            $private:CachedResource = [AzState]::SearchCache($Id)
            $this.Initialize($private:CachedResource, $true)
        }
        else {
            $private:GetAzConfig = [AzState]::GetAzConfig($Id)
            if ($private:GetAzConfig.Count -eq 1) {
                $this.Initialize($private:GetAzConfig[0], $false)
                Write-Verbose "New-AzState (FROM API)  [$Id]"
            }
            else {
                Write-Error "Unable to process [$Id]. Found multiple items. Please update ID to specific resource instance or use [AzState]::FromScope() method."
                break
            }
        }
    }

    # Default constructor with Resource Id and IgnoreCache input
    # Uses Update() method to auto-populate from Resource Id
    # Ignores Cache for Resource Id only (parent and child resources still pulled from cache if present)
    AzState([String]$Id, [SkipCache]$SkipCache) {
        $this.Update($Id)
    }

    AzState([PSCustomObject]$PSCustomObject) {
        foreach ($property in [AzState]::DefaultProperties) {
            $this.$property = $PSCustomObject.$property
        }
        $this.Initialize()
    }

    AzState([AzState]$AzState) {
        foreach ($property in [AzState]::DefaultProperties) {
            $this.$property = $AzState.$property
        }
        $this.Initialize()
    }

    [Void] Initialize() {
        # Used to set values on variables which require internal methods
        $this.SetProvider()
        $this.SetPolicy()
        $this.SetChildren()
        $this.SetParent()
        $this.SetParents()
        $this.SetResourcePath()
        # After the state object is initialized, add to the Cache array
        [AzState]::AddToCache($this)
    }

    [Void] Initialize([PsCustomObject]$PsCustomObject) {
        $this.Initialize($PsCustomObject, $false)
    }

    [Void] Initialize([PsCustomObject]$PsCustomObject, [Boolean]$UsingCache) {
        # Using a foreach loop to set all properties dynamically
        if ($UsingCache) {
            foreach ($property in $this.psobject.Properties.Name) {
                $this.$property = $PsCustomObject.$property
            }    
        }
        else {
            $this.SetDefaultProperties($PsCustomObject)    
            $this.Initialize()
        }  
    }

    # Update method used to update existing [AzState] object using the existing Resource Id
    [Void] Update() {
        if ($this.Id) {
            $this.Update($this.Id)            
        }
        else {
            Write-Error "Unable to update AzState. Please set a valid resource Id in the AzState object, or provide as an argument."
        }
    }

    # Update method used to update existing [AzState] object using the provided Resource Id
    # IMPROVEMENT - need to investigate how to handle multiple resources in scope of Id
    [Void] Update([String]$Id) {
        $private:GetAzConfig = [AzState]::GetAzConfig($Id)
        if ($private:GetAzConfig.Count -eq 1) {
            $this.Initialize($private:GetAzConfig[0], $false)
        }
        else {
            Write-Error "Unable to update multiple items. Please update ID to specific resource instance."
            break
        }
    }

    # Method to set default properties in AzState from input object
    hidden [Void] SetDefaultProperties([PsCustomObject]$PsCustomObject) {
        foreach ($private:Property in [AzState]::DefaultProperties) {
            $this.$private:Property = $PSCustomObject.$private:Property
        }
        switch -regex ($PsCustomObject.Id) {
            # ([AzState]::RegexProviderTypeFromId).ToString() { <# pending development #> }
            # ([AzState]::RegexIsResourceGroup).ToString() { <# pending development #> }
            ([AzState]::RegexIsSubscription).ToString() {
                $this.Type = [AzState]::GetTypeFromId($PsCustomObject.Id)
                $this.Name = $PsCustomObject.displayName
                $this.ExtendedProperties = $PsCustomObject
            }
            Default {
                $this.ExtendedProperties = [PsCustomObject]@{}
                foreach ($private:Property in $PsCustomObject.psobject.Properties) {
                    if ($private:Property -notin [AzState]::DefaultProperties) {
                        $this.ExtendedProperties | Add-Member -NotePropertyName $private:Property.Name -NotePropertyValue $private:Property.Value
                    }
                }
            }
        }
    }

    # Method to set Provider value based on Resource Type of object
    hidden [Void] SetProvider() {
        $this.Provider = ([AzStateProviders]::SearchCache($this.Type)).Provider
    }

    # Method to get Children based on Resource Type of object
    # Uses GetAzConfig to prevent circular loop caused by FromScope
    hidden [Object[]] GetChildren() {
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:children = [AzState]::GetAzConfig("$($this.Id)/descendants")
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

    # Method to get Policy configuration based on Resource Type of object
    hidden [AzStatePolicy] GetPolicy() {
        $private:AzStatePolicy = [AzStatePolicy]::new()
        foreach ($private:ChildType in [AzState]::PolicyResourceTypes($this.Type)) {
            $private:PolicyPath = $this.Id + "/providers/" + $private:ChildType
            $private:PolicyType = Split-Path $private:ChildType -Leaf
            $private:PolicyItems = [AzState]::GetAzConfig($private:PolicyPath)
            $private:AzStatePolicy.$private:PolicyType = [AzStateSimple]::Convert($private:PolicyItems)
        }
        return $private:AzStatePolicy
    }

    # Method to set Policy configuration based on Resource Type of object
    hidden [Void] SetPolicy() {
        $private:Policy = $this.GetPolicy()
        $this.Policy = $private:Policy
    }

    # Method to determine the parent resource for the current AzState instance
    # Different resource types use different methods to determine the parent
    hidden [AzStateSimple] GetParent() {
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:parentId = $this.Properties.details.parent.id
                if ($private:parentId) {
                    $private:parent = [PsCustomObject]@{
                        Id   = $this.Properties.details.parent.id
                        Type = "Microsoft.Management/managementGroups"
                    }
                }
            }
            "Microsoft.Resources/subscriptions" {
                $private:managementGroups = [AzState]::FromScope("/providers/Microsoft.Management/managementGroups")
                $private:searchParent = $private:managementGroups | Where-Object { $_.Children.Id -Contains "$($this.Id)" }
                $private:parent = [AzStateSimple]::new($private:searchParent)
            }
            "Microsoft.Resources/resourceGroups" {
                $private:parent = [PsCustomObject]@{
                    Id   = [AzState]::RegexExtractSubscriptionId.Match($this.Id).value
                    Type = "Microsoft.Resources/subscriptions"
                }
            }
            Default {
                $private:parent = [PsCustomObject]@{
                    Id   = [AzState]::RegexExtractResourceGroupId.Match($this.Id).value
                    Type = "Microsoft.Resources/resourceGroups"
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
        [String]$private:parentPath = ""
        foreach ($parent in $private:parents.Id) {
            $private:parentPath = $private:parentPath + [AzState]::RegexBeforeLastForwardSlash.Replace($parent, "")
        }
        $this.ParentPath = $private:parentPath.ToString()
    }

    hidden [String] GetResourcePath() {
        $private:ResourcePath = $this.ParentPath + "/" + $this.Name
        return $private:ResourcePath
    }

    hidden [Void] SetResourcePath() {
        $this.ResourcePath = $this.GetResourcePath().ToString()
    }

    hidden [AzState[]] GetChildrenByType([String]$Type) {
        $private:ChildrenScope = $this.Id + "/providers/" + $Type
        $private:GetChildrenByType = [AzState]::GetAzConfig($private:ChildrenScope)
        Write-Verbose "Found [$($private:GetChildrenByType.Count)] Child Resources in scope [$private:ChildrenScope]"
        foreach ($private:ChildByType in $private:GetChildrenByType) {
            Write-Verbose "Found [$($Type)] Child Resource [$($private:ChildByType.Id)]"
        }        
        return $private:GetChildrenByType
    }

    hidden [Void] SetChildrenByType($Type) {
        # Create array of objects containing required properties from GetChildrenByType() response
        $private:SetChildrenByType = $this.GetChildrenByType($Type) `
        | Select-Object -Property name, id, type, properties
        # Add to $this.Children if not already exists
        foreach ($private:Child in $private:SetChildrenByType) {
            $private:ChildNotSet = $private:Child.Id -notin $this.Children.Id
            $private:ChildInScope = $private:Child.Id -ilike "$($this.Id)/providers/$($Type)"
            # Need to consider how to handle update scenarios where a child item may need to be removed from Children or LinkedResources
            if ($private:ChildNotSet -and $private:ChildInScope) {
                $this.Children += $private:Child
            }
            $private:LinkedResourceNotSet = $private:Child.Id -notin $this.LinkedResources.Id
            if ($private:LinkedResourceNotSet) {
                $this.LinkedResources += $private:Child                
            }
        }
    }

    # IMPROVEMENT: Consider moving to new class for [Terraform]
    hidden [String] Terraform() {
        $private:dotTf = @()
        switch ($this.Type) {
            "Microsoft.Management/managementGroups" {
                $private:subscriptions = $this.Children `
                | Where-Object { $_.type -match "/subscriptions$" }
                $private:dotTf += "resource `"azurerm_management_group`" `"{0}`" {{" -f $this.Id -replace "/", "_"
                $private:dotTf += "  display_name = `"{0}`"" -f $this.Name
                $private:dotTf += ""
                if ($this.Parent.Id) {
                    $private:dotTf += "  parent_management_group_id = `"{0}`"" -f $this.Parent.Id
                    $private:dotTf += ""                    
                }
                if ($private:subscriptions) {
                    $private:dotTf += "  subscription_ids = ["
                    foreach ($private:subscription in $private:subscriptions) {
                        $private:dotTf += "    `"{0}`"" -f $private:subscription.Id
                    }
                    $private:dotTf += "  ]"
                }
                $private:dotTf += "}"
                $private:dotTf += ""
            }
            "Microsoft.Resources/subscriptions" {
                $private:dotTf += "data `"azurerm_subscription`" `"{0}`" {{" -f $this.Id -replace "/", "_"
                $private:dotTf += "  subscription_id = `"{0}`"" -f $this.ExtendedProperties.subscriptionId
                $private:dotTf += "}"
                $private:dotTf += ""
            }
            "Microsoft.Resources/resourceGroups" {
                $private:subscriptions = $this.Children `
                | Where-Object { $_.type -match "/subscriptions$" }
                $private:dotTf += "resource `"azurerm_resource_group`" `"{0}`" {{" -f $this.Id -replace "/", "_"
                $private:dotTf += "  name     = `"{0}`"" -f $this.Name
                $private:dotTf += "  location = `"{0}`"" -f $this.ExtendedProperties.Location
                if ($this.ExtendedProperties.Tags.psobject.properties.count -ge 1) {
                    $private:dotTf += ""
                    $private:dotTf += "  tags = {"
                    foreach ($Tag in $this.ExtendedProperties.Tags.psobject.properties) {
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

    [Void] SaveTerraform([String]$Path) {
        # WIP: Requires additional work
        if (-not (Test-Path -Path $Path -PathType Container)) {
            $this.Terraform() | Out-File -FilePath $Path -Encoding "UTF8" -NoClobber            
        }
    }

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

    # Static method to get "Path" value from Id and Type, for use with Invoke-AzRestMethod
    # Relies on the following additional static methods:
    #  -- [AzStateProviders]::GetApiParamsByType(Id, Type)
    hidden static [String] GetAzRestMethodPath([String]$Id, [String]$Type) {
        $private:AzRestMethodPath = $Id + [AzStateProviders]::GetApiParamsByType($Type)
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

    # Static method to simplify running Invoke-AzRestMethod using provided Id only
    # Relies on the following additional static methods:
    #  -- [AzState]::GetAzRestMethodPath(Id)
    #    |-- [AzState]::GetTypeFromId(Id)
    #       |-- [AzState]::GetAzRestMethodPath(Id, Type)
    #          |-- [AzStateProviders]::GetApiParamsByType(Id, Type)
    hidden static [PsCustomObject] GetAzRestMethod([String]$Id) {
        $private:PSHttpResponse = Invoke-AzRestMethod -Method GET -Path ([AzState]::GetAzRestMethodPath($Id))
        if ($private:PSHttpResponse.StatusCode -ne 200) {
            $private:ErrorBody = ($private:PSHttpResponse.Content | ConvertFrom-Json).error
            Write-Error "Invalid response from API:`n StatusCode=$($private:PSHttpResponse.StatusCode)`n ErrorCode=$($private:ErrorBody.code)`n ErrorMessage=$($private:ErrorBody.message)"
            break
        }
        return $private:PSHttpResponse
    }

    # Static method to return Resource configuration from Azure using provided Id to modify scope
    # Will return multiple items for IDs scoped at a Resource Type level (e.g. "/subscriptions")
    # Will return a single item for IDs scoped at a Resource level (e.g. "/subscriptions/{subscription_id}")
    # Relies on the following additional static methods:
    #  -- [AzState]::GetAzRestMethod(Id)
    #    |-- [AzState]::GetAzRestMethodPath(Id)
    #       |-- [AzState]::GetTypeFromId(Id)
    #          |-- [AzState]::GetAzRestMethodPath(Id, Type)
    #             |-- [AzStateProviders]::GetApiParamsByType(Id, Type)
    hidden static [PSCustomObject[]] GetAzConfig([String]$Id) {
        $private:AzConfigJson = ([AzState]::GetAzRestMethod($Id)).Content
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

    # Static method to support returning multiple AzState objects from defined scope
    static [AzState[]] FromScope([String]$Scope) {
        $private:FromScope = @()
        $private:AzConfigAtScope = [AzState]::GetAzConfig($Scope)
        foreach ($private:Config in $private:AzConfigAtScope) {
            $private:FromScope += [AzState]::new($private:Config.Id)
        }
        return $private:FromScope
    }

    # Static method to support returning multiple AzState objects from defined scope
    # using multiple thread jobs to enable parallel processing
    static [AzState[]] FromScopeParallel([String]$Scope) {
        # The AzStateThrottleLimit variable can be set to allow
        # performance tuning based on system resources
        if (-not $AzStateThrottleLimit) {
            $AzStateThrottleLimit = 10
        }
        Write-Verbose "Setting Throttle Limit to [$AzStateThrottleLimit]"
        # Get the item(s) to process from the provided Scope value
        $private:AzConfigAtScope = [AzState]::GetAzConfig($Scope)
        # Set up and run the parallel processing runspace
        $ThreadSafeAzState = [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]::new()
        $ParallelJobs = $private:AzConfigAtScope.Id | ForEach-Object {
            Start-ThreadJob -Name $_ `
            -ThrottleLimit $AzStateThrottleLimit `
            -ArgumentList $_ `
            -ScriptBlock {
                [CmdletBinding()]
                param ([Parameter()][String]$ScopeId)
                Write-Host "[$($ScopeId)] AzState discovery [Starting]"
                $private:AzStateObject = New-AzState -Id $ScopeId
                $AzStateTracker = $using:threadSafeAzState
                $AzStateTracker.TryAdd($private:AzStateObject.Id, $private:AzStateObject)
            }
        }
        $ParallelJobs | Receive-Job -Wait -AutoRemoveJob
        # Finally return the array of AzState values from the threadsafe dictionary
        return $ThreadSafeAzState.Values
    }

    # Static property to store cache of AzState using a threadsafe
    # dictionary variable to allow caching across parallel jobs
    # https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/foreach-object#example-14--using-thread-safe-variable-references
    static [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]$Cache

    # Static method to show all entries in Cache
    static [AzState[]] ShowCache() {
        return ([AzState]::Cache).Values
    }

    # Static method to show all entries in Cache matching the specified resource Id
    static [AzState[]] SearchCache([String]$Id) {
        return [AzState]::Cache[$Id]
    }

    # Static method to return [Boolean] for Resource in Cache query
    static [Boolean] InCache([String]$Id) {
        if ([AzState]::Cache) {
            return ([AzState]::Cache).ContainsKey($Id)            
        }
        else {
            # The following prevents needing to initialize the cache
            # manually if not exist on first attempt to use
            [AzState]::InitializeCache()
            return $false
        }
    }

    # Static method to update all entries in Cache
    static [Void] UpdateCache() {
        $private:IdListFromCache = [AzState]::ShowCache().Id
        [AzState]::ClearCache()
        foreach ($private:Id in $private:IdListFromCache) {
            [AzState]::new($private:Id)
        }
    }

    # Static method to add AzState object to Cache
    static [Void] AddToCache([AzState[]]$AddToCache) {
        # The following prevents needing to initialize the cache
        # manually if not exist on first attempt to use
        if (-not [AzState]::Cache) {
            [AzState]::InitializeCache()
        }
        foreach ($AzState in $AddToCache) {
            $AddedToCache = [AzState]::Cache.TryAdd($AzState.Id, $AzState)
            if ($AddedToCache) {
                Write-Verbose "Added Resource to AzState Cache [$($AzState.Id)]"
            }
        }
    }

    # Static method to initialize Cache
    # Will also reset cache if exists
    static [Void] InitializeCache() {
        Write-Verbose "Initializing AzState cache (Empty)"
        [AzState]::Cache = [System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]::new()
    }

    # Static method to initialize Cache from copy of cache stored in input variable
    static [Void] InitializeCache([System.Collections.Concurrent.ConcurrentDictionary[String, AzState]]$AzStateCache) {
        Write-Verbose "Initializing AzState Cache (From Copy)"
        [AzState]::Cache = $AzStateCache
    }

    # Static method to clear all entries from Cache
    static [Void] ClearCache() {
        [AzState]::InitializeCache()
    }
    
}
