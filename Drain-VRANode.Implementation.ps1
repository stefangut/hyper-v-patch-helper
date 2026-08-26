[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceVMHost,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [switch]$PreFlight,

    [Parameter(Mandatory = $false)]
    [switch]$FirstNode
)

function Resolve-SourceVMHost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    $hostObject = Get-SCVMHost -ComputerName $ComputerName -ErrorAction Stop
    if ($null -eq $hostObject) {
        throw "SCVMM host '$ComputerName' was not found."
    }

    return $hostObject
}

function Resolve-HostCluster {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceHost,

        [Parameter(Mandatory = $false)]
        [string]$ExplicitName
    )

    if ($ExplicitName) {
        $cluster = Get-SCVMHostCluster -Name $ExplicitName -ErrorAction Stop
        if ($null -eq $cluster) {
            throw "SCVMM host cluster '$ExplicitName' was not found."
        }

        $clusterHosts = @(Get-SCVMHost -VMHostCluster $cluster -ErrorAction Stop)
        $sourceMatches = @($clusterHosts | Where-Object {
            $_.ID -eq $SourceHost.ID -or $_.ComputerName -eq $SourceHost.ComputerName
        })

        if ($sourceMatches.Count -eq 0) {
            $nodeNames = @($clusterHosts | ForEach-Object { $_.ComputerName }) -join ', '
            throw "Source host '$($SourceHost.ComputerName)' is not in cluster '$ExplicitName'. Cluster nodes: $nodeNames"
        }

        return [pscustomobject]@{
            Cluster = $cluster
            Hosts = $clusterHosts
        }
    }

    if ($null -eq $SourceHost.HostCluster) {
        throw "Source host '$($SourceHost.ComputerName)' has no host cluster."
    }

    $clusterHosts = @(Get-SCVMHost -VMHostCluster $SourceHost.HostCluster -ErrorAction Stop)
    if ($clusterHosts.Count -eq 0) {
        throw "No hosts were returned for cluster '$($SourceHost.HostCluster.Name)'."
    }

    return [pscustomobject]@{
        Cluster = $SourceHost.HostCluster
        Hosts = $clusterHosts
    }
}

function Get-EligibleVMHost {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ClusterHosts,

        [Parameter(Mandatory = $true)]
        [object]$SourceHost
    )

    $eligibleHosts = @($ClusterHosts | Where-Object {
        $_.ID -ne $SourceHost.ID -and $_.ComputerName -ne $SourceHost.ComputerName
    } | Sort-Object ComputerName)

    return $eligibleHosts
}

function Get-VMClassification {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$VirtualMachines
    )

    $migrationCandidates = @()
    $zertoVRA = @()
    $notRunning = @()
    $anomalies = @()

    foreach ($virtualMachine in $VirtualMachines) {
        $nameProperty = $virtualMachine.PSObject.Properties['Name']
        $statusProperty = $virtualMachine.PSObject.Properties['Status']

        if ($null -eq $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            $anomalies += 'A VM object has no usable Name property.'
            continue
        }

        if ($null -eq $statusProperty -or [string]::IsNullOrWhiteSpace([string]$statusProperty.Value)) {
            $anomalies += "VM '$($nameProperty.Value)' has no usable Status property."
            continue
        }

        if ([string]$statusProperty.Value -ne 'Running') {
            $notRunning += $virtualMachine
            continue
        }

        if ([string]$nameProperty.Value -cmatch '^Z-VRA') {
            $zertoVRA += $virtualMachine
            continue
        }

        $migrationCandidates += $virtualMachine
    }

    return [pscustomobject]@{
        MigrationCandidates = $migrationCandidates
        ZertoVRA = $zertoVRA
        NotRunning = $notRunning
        Anomalies = $anomalies
    }
}

function Test-VMHostAvailability {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ClusterHosts
    )

    $hostResults = @()
    $anomalies = @()

    foreach ($clusterHost in $ClusterHosts) {
        $hostName = [string]$clusterHost.ComputerName
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            $anomalies += 'A cluster host object has no usable ComputerName property.'
            continue
        }

        $maintenanceProperty = $clusterHost.PSObject.Properties['MaintenanceHost']
        $placementProperty = $clusterHost.PSObject.Properties['AvailableForPlacement']
        $communicationProperty = $clusterHost.PSObject.Properties['CommunicationState']
        $clusterNodeProperty = $clusterHost.PSObject.Properties['ClusterNodeStatus']
        $hyperVProperty = $clusterHost.PSObject.Properties['HyperVState']

        $missingProperties = @(
            @(
                @{ Name = 'MaintenanceHost'; Property = $maintenanceProperty }
                @{ Name = 'AvailableForPlacement'; Property = $placementProperty }
                @{ Name = 'CommunicationState'; Property = $communicationProperty }
                @{ Name = 'ClusterNodeStatus'; Property = $clusterNodeProperty }
                @{ Name = 'HyperVState'; Property = $hyperVProperty }
            ) | Where-Object { $null -eq $_.Property } | ForEach-Object { $_.Name }
        )

        if ($missingProperties.Count -gt 0) {
            $anomalies += "Host '$hostName' is missing availability properties: $($missingProperties -join ', ')."
            continue
        }

        $reasons = @()
        if ($null -ne $maintenanceProperty -and [bool]$maintenanceProperty.Value) {
            $reasons += 'maintenance mode'
        }
        if ($placementProperty.Value -eq $false) {
            $reasons += 'unavailable'
        }
        if ([string]$communicationProperty.Value -cne 'Responding') {
            $reasons += "communication state: $($communicationProperty.Value)"
        }
        if ([string]$clusterNodeProperty.Value -cne 'Running') {
            $reasons += "cluster node status: $($clusterNodeProperty.Value)"
        }
        if ([string]$hyperVProperty.Value -cne 'Running') {
            $reasons += "Hyper-V state: $($hyperVProperty.Value)"
        }

        $hostResults += [pscustomobject]@{
            Host = $clusterHost
            IsHealthy = ($reasons.Count -eq 0)
            Reasons = @($reasons | Select-Object -Unique)
        }

        if ($reasons.Count -gt 0) {
            $anomalies += "Host '$hostName' is not available: $((@($reasons | Select-Object -Unique)) -join ', ')."
        }
    }

    return [pscustomobject]@{
        Hosts = $hostResults
        Anomalies = $anomalies
        IsHealthy = ($anomalies.Count -eq 0 -and @($hostResults | Where-Object { -not $_.IsHealthy }).Count -eq 0)
    }
}

function Resolve-MigrationLimit {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Hosts,

        [Parameter(Mandatory = $false)]
        [switch]$PromptForFallback
    )

    $hostLimits = @()
    $anomalies = @()

    foreach ($hostObject in $Hosts) {
        $hostName = [string]$hostObject.ComputerName
        $limitProperty = $hostObject.PSObject.Properties['LiveMigrationMaximum']
        $limit = $null
        $isValid = $false

        if ($null -eq $limitProperty) {
            $anomalies += "Host '$hostName' has no LiveMigrationMaximum property."
        } else {
            try {
                $limit = [int]$limitProperty.Value
                $isValid = ($limit -gt 0 -and [string]$limitProperty.Value -notmatch '\.')
            } catch {
                $anomalies += "Host '$hostName' has an invalid LiveMigrationMaximum value: '$($limitProperty.Value)'."
            }

            if (-not $isValid -and $anomalies -notcontains "Host '$hostName' has an invalid LiveMigrationMaximum value: '$($limitProperty.Value)'.") {
                $anomalies += "Host '$hostName' has an invalid LiveMigrationMaximum value: '$($limitProperty.Value)'."
            }
        }

        $hostLimits += [pscustomobject]@{
            Host = $hostObject
            HostName = $hostName
            Value = $limit
            IsValid = $isValid
        }
    }

    $validLimits = @($hostLimits | Where-Object { $_.IsValid } | ForEach-Object { $_.Value })
    $effectiveLimit = $null
    if ($anomalies.Count -eq 0 -and $validLimits.Count -eq $Hosts.Count -and $validLimits.Count -gt 0) {
        $effectiveLimit = ($validLimits | Measure-Object -Minimum).Minimum
    } elseif ($PromptForFallback) {
        do {
            $fallbackInput = Read-Host 'Enter a positive global migration limit'
            $fallbackLimit = 0
            $fallbackIsValid = [int]::TryParse($fallbackInput, [ref]$fallbackLimit) -and $fallbackLimit -gt 0
            if (-not $fallbackIsValid) {
                Write-Warning 'Migration limit must be a positive integer.'
            }
        } while (-not $fallbackIsValid)

        $effectiveLimit = $fallbackLimit
    }

    return [pscustomobject]@{
        EffectiveLimit = $effectiveLimit
        HostLimits = $hostLimits
        Anomalies = $anomalies
        UsedFallback = ($PromptForFallback -and $anomalies.Count -gt 0)
    }
}

function Get-MigrationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$VirtualMachines,

        [Parameter(Mandatory = $true)]
        [object[]]$DestinationHosts
    )

    $plan = @()
    for ($index = 0; $index -lt $VirtualMachines.Count; $index++) {
        $destination = $DestinationHosts[$index % $DestinationHosts.Count]
        $plan += [pscustomobject]@{
            Sequence = $index + 1
            VM = $VirtualMachines[$index]
            VMName = [string]$VirtualMachines[$index].Name
            DestinationHost = $destination
            DestinationHostName = [string]$destination.ComputerName
        }
    }

    return $plan
}

function Get-VMHostWorkload {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Hosts
    )

    $workload = @()
    foreach ($hostObject in $Hosts) {
        $virtualMachines = @(Get-SCVirtualMachine -VMHost $hostObject -ErrorAction Stop)
        $runningCount = @($virtualMachines | Where-Object {
            $statusProperty = $_.PSObject.Properties['Status']
            $statusProperty -ne $null -and [string]$statusProperty.Value -eq 'Running'
        }).Count
        $memoryProperty = $hostObject.PSObject.Properties['AvailableMemory']
        $availableMemory = $null
        if ($null -ne $memoryProperty) {
            try {
                $availableMemory = [int64]$memoryProperty.Value
            } catch {
                $availableMemory = $null
            }
        }

        $workload += [pscustomobject]@{
            Host = $hostObject
            HostName = [string]$hostObject.ComputerName
            RunningVMCount = $runningCount
            AvailableMemory = $availableMemory
        }
    }

    return $workload
}

function Resolve-MigrationPlacement {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$VirtualMachines,

        [Parameter(Mandatory = $true)]
        [object[]]$DestinationHosts,

        [Parameter(Mandatory = $false)]
        [switch]$UseFirstNode
    )

    if ($DestinationHosts.Count -eq 0) {
        throw 'No eligible destination hosts are available for placement.'
    }

    if ($UseFirstNode) {
        return [pscustomobject]@{
            Mode = 'FirstNode'
            SelectedHost = $null
            Workload = @()
            Plan = @(Get-MigrationPlan -VirtualMachines $VirtualMachines -DestinationHosts $DestinationHosts)
        }
    }

    $workload = @(Get-VMHostWorkload -Hosts $DestinationHosts)
    $selected = $workload | Sort-Object RunningVMCount, @{ Expression = { if ($null -eq $_.AvailableMemory) { [int64]::MinValue } else { -1 * $_.AvailableMemory } } }, HostName | Select-Object -First 1
    $plan = @()
    foreach ($virtualMachine in $VirtualMachines) {
        $plan += [pscustomobject]@{
            Sequence = $plan.Count + 1
            VM = $virtualMachine
            VMName = [string]$virtualMachine.Name
            DestinationHost = $selected.Host
            DestinationHostName = $selected.HostName
        }
    }

    return [pscustomobject]@{
        Mode = 'SubsequentNode'
        SelectedHost = $selected.Host
        Workload = $workload
        Plan = $plan
    }
}

function Test-MigrationJobTerminal {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Job
    )

    $state = [string]$Job.Status
    if ([string]::IsNullOrWhiteSpace($state)) {
        $state = [string]$Job.State
    }

    return ($state -in @('Completed', 'Failed', 'Canceled', 'Cancelled', 'Stopped'))
}

function Get-MigrationJobState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TrackedJob
    )

    $jobId = $TrackedJob.Job.ID
    if ($null -eq $jobId) {
        throw "SCVMM migration job for VM '$($TrackedJob.VMName)' has no ID."
    }

    return Get-SCJob -ID $jobId -ErrorAction Stop
}

function Start-MigrationJob {
    param(
        [Parameter(Mandatory = $true)]
        [object]$MigrationPlanItem,

        [Parameter(Mandatory = $true)]
        [int]$Sequence
    )

    $jobVariableName = "DrainMigrationJob_$Sequence"
    try {
        $null = Move-SCVirtualMachine -VM $MigrationPlanItem.VM -VMHost $MigrationPlanItem.DestinationHost -RunAsynchronously -JobVariable $jobVariableName -ErrorAction Stop
        $scvmmJob = Get-Variable -Name $jobVariableName -ValueOnly -ErrorAction Stop
        if ($null -eq $scvmmJob) {
            throw "Move-SCVirtualMachine did not provide an SCVMM job."
        }

        return [pscustomobject]@{
            VMName = $MigrationPlanItem.VMName
            DestinationHostName = $MigrationPlanItem.DestinationHostName
            Job = $scvmmJob
            JobId = $scvmmJob.ID
            Started = Get-Date
        }
    } finally {
        Remove-Variable -Name $jobVariableName -ErrorAction SilentlyContinue
    }
}

function Get-MigrationJobLabel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Job
    )

    foreach ($propertyName in @('Name', 'Description', 'ID')) {
        $property = $Job.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return '<unknown SCVMM job>'
}

function Invoke-MigrationQueue {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$MigrationPlan,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MigrationLimit
    )

    $queue = New-Object System.Collections.Queue
    foreach ($planItem in $MigrationPlan) {
        $queue.Enqueue($planItem)
    }

    $activeJobs = @()
    $reports = @()
    $anomalies = @()
    $sequence = 0

    while ($queue.Count -gt 0) {
        while ($queue.Count -gt 0 -and $activeJobs.Count -lt $MigrationLimit) {
            $planItem = $queue.Dequeue()
            $sequence++
            try {
                $trackedJob = Start-MigrationJob -MigrationPlanItem $planItem -Sequence $sequence
                $activeJobs += $trackedJob
                $jobLabel = Get-MigrationJobLabel -Job $trackedJob.Job
                Write-Host "SUBMITTED: $($trackedJob.VMName) -> $($trackedJob.DestinationHostName) | SCVMM job: $jobLabel"
                $reports += [pscustomobject]@{
                    VMName = $trackedJob.VMName
                    DestinationHostName = $trackedJob.DestinationHostName
                    JobId = $trackedJob.JobId
                    JobLabel = $jobLabel
                    Event = 'Migration started'
                    Status = 'Started'
                }
            } catch {
                $anomalies += "Migration trigger failed for VM '$($planItem.VMName)' to '$($planItem.DestinationHostName)': $($_.Exception.Message)"
                $reports += [pscustomobject]@{
                    VMName = $planItem.VMName
                    DestinationHostName = $planItem.DestinationHostName
                    JobId = $null
                    Event = 'Migration trigger failed'
                    Status = 'Failed'
                }
            }
        }

        if ($activeJobs.Count -eq 0) {
            continue
        }

        $remainingJobs = @()
        foreach ($trackedJob in $activeJobs) {
            try {
                $currentJob = Get-MigrationJobState -TrackedJob $trackedJob
                if (Test-MigrationJobTerminal -Job $currentJob) {
                    $reports += [pscustomobject]@{
                        VMName = $trackedJob.VMName
                        DestinationHostName = $trackedJob.DestinationHostName
                        JobId = $trackedJob.JobId
                        Event = 'Migration job completed'
                        Status = [string]$currentJob.Status
                    }
                } else {
                    $remainingJobs += $trackedJob
                }
            } catch {
                $anomalies += "Unable to query migration job '$($trackedJob.JobId)' for VM '$($trackedJob.VMName)': $($_.Exception.Message)"
                $remainingJobs += $trackedJob
            }
        }

        $activeJobs = @($remainingJobs)
        if ($queue.Count -gt 0 -and $activeJobs.Count -ge $MigrationLimit) {
            Start-Sleep -Seconds 1
        }
    }

    return [pscustomobject]@{
        Reports = $reports
        Anomalies = $anomalies
        RemainingJobs = $activeJobs
    }
}

function Write-DrainReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Discovery
    )

    Write-Host "SOURCE: $($Discovery.SourceHost.ComputerName)"
    Write-Host "CLUSTER: $($Discovery.Cluster.Name)"
    Write-Host 'DESTINATIONS:'
    foreach ($destinationHost in $Discovery.EligibleHosts) {
        Write-Host "  $($destinationHost.ComputerName)"
    }

    Write-Host 'LIVE MIGRATION MAXIMUMS:'
    foreach ($hostLimit in $Discovery.MigrationLimit.HostLimits) {
        $limitValue = if ($hostLimit.IsValid) { $hostLimit.Value } else { '<invalid>' }
        Write-Host "  $($hostLimit.HostName): $limitValue"
    }
    if ($null -ne $Discovery.MigrationLimit.EffectiveLimit) {
        Write-Host "  EFFECTIVE GLOBAL LIMIT: $($Discovery.MigrationLimit.EffectiveLimit)"
    }

    Write-Host "PLACEMENT MODE: $($Discovery.Placement.Mode)"
    if ($Discovery.Placement.Mode -eq 'SubsequentNode') {
        foreach ($hostWorkload in $Discovery.Placement.Workload) {
            Write-Host "  $($hostWorkload.HostName): $($hostWorkload.RunningVMCount) running VM(s), AvailableMemory $($hostWorkload.AvailableMemory)"
        }
        Write-Host "  SELECTED DESTINATION: $($Discovery.Placement.SelectedHost.ComputerName)"
    }

    Write-Host 'MIGRATE:'
    foreach ($planItem in $Discovery.MigrationPlan) {
        Write-Host "  $($planItem.VMName) -> $($planItem.DestinationHostName)"
    }

    Write-Host 'LEAVE - ZERTO:'
    foreach ($virtualMachine in $Discovery.ZertoVRA) {
        Write-Host "  $($virtualMachine.Name)"
    }

    Write-Host 'LEAVE - NOT RUNNING:'
    foreach ($virtualMachine in $Discovery.NotRunning) {
        Write-Host "  $($virtualMachine.Name)"
    }

    if ($Discovery.Anomalies.Count -gt 0) {
        Write-Host 'ANOMALIES:'
        foreach ($anomaly in $Discovery.Anomalies) {
            Write-Host "  $anomaly"
        }
    }
}

function Test-DrainSafety {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Discovery
    )

    $blockingAnomalies = @($Discovery.Anomalies | Where-Object {
        $_ -notin $Discovery.MigrationLimit.Anomalies
    })

    if ($Discovery.EligibleHosts.Count -eq 0) {
        $blockingAnomalies += "No eligible destination hosts were found for source host '$($Discovery.SourceHost.ComputerName)'."
    }

    return @($blockingAnomalies | Select-Object -Unique)
}

function Invoke-DrainExecution {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Discovery
    )

    $limitResult = Resolve-MigrationLimit -Hosts (@($Discovery.SourceHost) + $Discovery.EligibleHosts) -PromptForFallback
    $blockingAnomalies = @(Test-DrainSafety -Discovery $Discovery | Where-Object {
        $_ -notin $Discovery.MigrationLimit.Anomalies
    })
    $blockingAnomalies += $limitResult.Anomalies | Where-Object {
        $_ -notin $Discovery.MigrationLimit.Anomalies -or $null -eq $limitResult.EffectiveLimit
    }

    if ($blockingAnomalies.Count -gt 0) {
        foreach ($anomaly in @($blockingAnomalies | Select-Object -Unique)) {
            Write-Error $anomaly
        }
        return [pscustomobject]@{
            Reports = @()
            Anomalies = @($blockingAnomalies | Select-Object -Unique)
            RemainingJobs = @()
        }
    }

    $plan = @($Discovery.MigrationPlan)
    $actionDescription = "Migrate $($plan.Count) VM(s) from $($Discovery.SourceHost.ComputerName)"
    if (-not $PSCmdlet.ShouldProcess($actionDescription, 'Start asynchronous SCVMM migrations')) {
        return [pscustomobject]@{
            Reports = @()
            Anomalies = @()
            RemainingJobs = @()
            Skipped = $true
        }
    }

    return Invoke-MigrationQueue -MigrationPlan $plan -MigrationLimit $limitResult.EffectiveLimit
}

function Get-DrainDiscovery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [string]$ExplicitClusterName
    )

    $sourceHost = Resolve-SourceVMHost -ComputerName $ComputerName
    $clusterResult = Resolve-HostCluster -SourceHost $sourceHost -ExplicitName $ExplicitClusterName
    $candidateHosts = @(Get-EligibleVMHost -ClusterHosts $clusterResult.Hosts -SourceHost $sourceHost)
    $anomalies = @()
    $virtualMachines = @(Get-SCVirtualMachine -VMHost $sourceHost -ErrorAction Stop)
    $classification = Get-VMClassification -VirtualMachines $virtualMachines
    $availability = Test-VMHostAvailability -ClusterHosts $clusterResult.Hosts
    $healthyHostNames = @($availability.Hosts | Where-Object { $_.IsHealthy } | ForEach-Object { $_.Host.ComputerName })
    $eligibleHosts = @($candidateHosts | Where-Object { $healthyHostNames -contains $_.ComputerName })
    $placement = Resolve-MigrationPlacement -VirtualMachines $classification.MigrationCandidates -DestinationHosts $eligibleHosts -UseFirstNode:$FirstNode
    $limitResult = Resolve-MigrationLimit -Hosts (@($sourceHost) + $eligibleHosts)

    $anomalies += $classification.Anomalies
    $anomalies += $availability.Anomalies
    $anomalies += $limitResult.Anomalies

    if ($eligibleHosts.Count -eq 0) {
        $anomalies += "No eligible destination hosts were found for source host '$ComputerName'."
    }

    return [pscustomobject]@{
        SourceHost = $sourceHost
        Cluster = $clusterResult.Cluster
        ClusterHosts = @($clusterResult.Hosts)
        EligibleHosts = $eligibleHosts
        VirtualMachines = $virtualMachines
        MigrationCandidates = @($classification.MigrationCandidates)
        MigrationPlan = @($placement.Plan)
        Placement = $placement
        ZertoVRA = @($classification.ZertoVRA)
        NotRunning = @($classification.NotRunning)
        HostAvailability = $availability
        MigrationLimit = $limitResult
        Anomalies = $anomalies
        PreFlight = [bool]$PreFlight
    }
}

$discovery = Get-DrainDiscovery -ComputerName $SourceVMHost -ExplicitClusterName $ClusterName
Write-DrainReport -Discovery $discovery

if ($PreFlight) {
    return $discovery
}

Invoke-DrainExecution -Discovery $discovery
