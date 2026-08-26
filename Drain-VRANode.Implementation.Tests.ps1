$implementationPath = Join-Path $PSScriptRoot 'Drain-VRANode.Implementation.ps1'

function New-TestDiscovery {
    param(
        [object[]]$Anomalies = @(),
        [object[]]$MigrationLimitAnomalies = @()
    )

    $cluster = [pscustomobject]@{ Name = 'CL01' }
    $sourceHost = [pscustomobject]@{
        ID = 'S1'
        ComputerName = 'HV01'
        HostCluster = $cluster
        MaintenanceHost = $false
        AvailableForPlacement = $true
        CommunicationState = 'Responding'
        ClusterNodeStatus = 'Running'
        HyperVState = 'Running'
        LiveMigrationMaximum = 2
    }
    $destinationHost = [pscustomobject]@{
        ID = 'D1'
        ComputerName = 'HV02'
        MaintenanceHost = $false
        AvailableForPlacement = $true
        CommunicationState = 'Responding'
        ClusterNodeStatus = 'Running'
        HyperVState = 'Running'
        LiveMigrationMaximum = 2
    }

    return [pscustomobject]@{
        SourceHost = $sourceHost
        Cluster = $cluster
        EligibleHosts = @($destinationHost)
        MigrationCandidates = @(
            [pscustomobject]@{ Name = 'APP01'; Status = 'Running' }
        )
        ZertoVRA = @()
        NotRunning = @()
        HostAvailability = [pscustomobject]@{
            Anomalies = @()
            IsHealthy = $true
        }
        MigrationLimit = [pscustomobject]@{
            Anomalies = $MigrationLimitAnomalies
            EffectiveLimit = 2
        }
        Placement = [pscustomobject]@{
            Mode = 'SubsequentNode'
            SelectedHost = $destinationHost
            Workload = @([pscustomobject]@{
                Host = $destinationHost
                HostName = 'HV02'
                RunningVMCount = 0
                AvailableMemory = 100
            })
        }
        MigrationPlan = @([pscustomobject]@{
            Sequence = 1
            VM = [pscustomobject]@{ Name = 'APP01'; Status = 'Running' }
            VMName = 'APP01'
            DestinationHost = $destinationHost
            DestinationHostName = 'HV02'
        })
        Anomalies = $Anomalies
    }
}

Describe 'Drain-VRANode migration execution' {
    BeforeEach {
        $global:drainTestCluster = [pscustomobject]@{ Name = 'CL01' }
        $global:drainTestSourceHost = [pscustomobject]@{
            ID = 'S1'
            ComputerName = 'HV01'
            HostCluster = $global:drainTestCluster
            MaintenanceHost = $false
            AvailableForPlacement = $true
            CommunicationState = 'Responding'
            ClusterNodeStatus = 'Running'
            HyperVState = 'Running'
            LiveMigrationMaximum = 2
        }
        $global:drainTestDestinationHost = [pscustomobject]@{
            ID = 'D1'
            ComputerName = 'HV02'
            HostCluster = $global:drainTestCluster
            MaintenanceHost = $false
            AvailableForPlacement = $true
            CommunicationState = 'Responding'
            ClusterNodeStatus = 'Running'
            HyperVState = 'Running'
            LiveMigrationMaximum = 2
        }
        Mock Get-SCVMHost {
            param($ComputerName, $VMHostCluster)
            if ($VMHostCluster) {
                return @($global:drainTestSourceHost, $global:drainTestDestinationHost)
            }
            return $global:drainTestSourceHost
        }
        Mock Get-SCVirtualMachine {
            param($VMHost)
            if ($global:drainTestPlacementWorkload) {
                if ($VMHost.ComputerName -eq 'HV02') {
                    return @([pscustomobject]@{ Name = 'EXISTING'; Status = 'Running' })
                }
                return @([pscustomobject]@{ Name = 'EXISTING1'; Status = 'Running' }, [pscustomobject]@{ Name = 'EXISTING2'; Status = 'Running' })
            }
            return @([pscustomobject]@{ Name = 'APP01'; Status = 'Running' })
        }
        $implementationSource = Get-Content -Path $implementationPath -Raw
        $implementationSource = ($implementationSource -split '(?m)^function Resolve-SourceVMHost', 2)[1]
        $implementationSource = 'function Resolve-SourceVMHost' + $implementationSource
        $implementationSource = $implementationSource -replace '(?ms)\r?\n\$discovery = Get-DrainDiscovery.*\z', ''
        Invoke-Expression $implementationSource
        Remove-Item Function:\Start-MigrationJob -ErrorAction SilentlyContinue
        $global:drainTestPlacementWorkload = $false
        $global:drainTestStartCalls = 0
        $global:drainTestTriggerFailure = $false
        function global:Start-MigrationJob {
            param($MigrationPlanItem, $Sequence)
            $global:drainTestStartCalls++
            if ($global:drainTestTriggerFailure -and $global:drainTestStartCalls -eq 1) {
                throw 'simulated trigger failure'
            }
            return [pscustomobject]@{
                VMName = $MigrationPlanItem.VMName
                DestinationHostName = $MigrationPlanItem.DestinationHostName
                Job = [pscustomobject]@{ ID = 22; Name = 'Move APP01' ; Status = 'Completed' }
                JobId = 22
            }
        }
        function global:Get-SCJob {
            param($ID)
            return [pscustomobject]@{ ID = $ID; Status = 'Completed' }
        }
    }

    It 'returns skipped and does not trigger a migration for WhatIf' {
        $script:moveCalls = 0
        Mock Move-SCVirtualMachine { $script:moveCalls++ }
        Mock Read-Host { '2' }

        $result = Invoke-DrainExecution -Discovery (New-TestDiscovery) -WhatIf

        $result.Skipped | Should Be $true
        $script:moveCalls | Should Be 0
    }

    It 'blocks execution when discovery has safety anomalies' {
        $script:moveCalls = 0
        Mock Move-SCVirtualMachine { $script:moveCalls++ }
        $discovery = New-TestDiscovery -Anomalies @('Host HV02 is not available.')

        $result = Invoke-DrainExecution -Discovery $discovery -Confirm:$false -ErrorAction SilentlyContinue

        (@($result.Anomalies) -contains 'Host HV02 is not available.') | Should Be $true
        $script:moveCalls | Should Be 0
    }

    It 'reports a trigger failure and continues with the remaining queue' {
        $global:drainTestTriggerFailure = $true

        $plan = @(
            [pscustomobject]@{ VMName = 'APP01'; VM = [pscustomobject]@{ Name = 'APP01' }; DestinationHostName = 'HV02'; DestinationHost = [pscustomobject]@{ ComputerName = 'HV02' } },
            [pscustomobject]@{ VMName = 'APP02'; VM = [pscustomobject]@{ Name = 'APP02' }; DestinationHostName = 'HV02'; DestinationHost = [pscustomobject]@{ ComputerName = 'HV02' } }
        )
        $result = Invoke-MigrationQueue -MigrationPlan $plan -MigrationLimit 1

        (@($result.Anomalies) -contains 'Migration trigger failed for VM ''APP01'' to ''HV02'': simulated trigger failure') | Should Be $true
        @($result.Reports | Where-Object { $_.VMName -eq 'APP02' -and $_.Status -eq 'Started' }).Count | Should Be 1
        $global:drainTestStartCalls | Should Be 2
    }

    It 'recognizes all supported terminal migration job states' {
        @('Completed', 'Failed', 'Canceled', 'Cancelled', 'Stopped') | ForEach-Object {
            Test-MigrationJobTerminal -Job ([pscustomobject]@{ Status = $_ }) | Should Be $true
        }
        Test-MigrationJobTerminal -Job ([pscustomobject]@{ Status = 'Running' }) | Should Be $false
    }

    It 'prefers a job name and falls back to the job ID' {
        (Get-MigrationJobLabel -Job ([pscustomobject]@{ ID = 51; Name = 'Move APP01' })) | Should Be 'Move APP01'
        (Get-MigrationJobLabel -Job ([pscustomobject]@{ ID = 52 })) | Should Be '52'
    }

    It 'uses round-robin placement for FirstNode mode' {
        $virtualMachines = @(
            [pscustomobject]@{ Name = 'APP01' }
            [pscustomobject]@{ Name = 'APP02' }
            [pscustomobject]@{ Name = 'APP03' }
        )
        $hosts = @(
            [pscustomobject]@{ ComputerName = 'HV02' }
            [pscustomobject]@{ ComputerName = 'HV03' }
        )

        $placement = Resolve-MigrationPlacement -VirtualMachines $virtualMachines -DestinationHosts $hosts -UseFirstNode

        $placement.Mode | Should Be 'FirstNode'
        (@($placement.Plan | ForEach-Object { $_.DestinationHostName }) -join ',') | Should Be 'HV02,HV03,HV02'
    }

    It 'selects one least-loaded destination and breaks ties with AvailableMemory' {
        $virtualMachines = @([pscustomobject]@{ Name = 'APP01' })
        $hosts = @(
            [pscustomobject]@{ ComputerName = 'HV02'; AvailableMemory = 100 }
            [pscustomobject]@{ ComputerName = 'HV03'; AvailableMemory = 200 }
        )
        Remove-Item Function:\Get-VMHostWorkload -ErrorAction SilentlyContinue
        function global:Get-VMHostWorkload {
            param($Hosts)
            return @(
                [pscustomobject]@{ Host = $Hosts[0]; HostName = 'HV02'; RunningVMCount = 1; AvailableMemory = 100 }
                [pscustomobject]@{ Host = $Hosts[1]; HostName = 'HV03'; RunningVMCount = 1; AvailableMemory = 200 }
            )
        }

        $placement = Resolve-MigrationPlacement -VirtualMachines $virtualMachines -DestinationHosts $hosts

        $placement.Mode | Should Be 'SubsequentNode'
        $placement.SelectedHost.ComputerName | Should Be 'HV03'
        $placement.Plan[0].DestinationHostName | Should Be 'HV03'
    }

    It 'produces start and completion reports for a successful execution' {
        $result = Invoke-MigrationQueue -MigrationPlan (Get-MigrationPlan -VirtualMachines @([pscustomobject]@{ Name = 'APP01' }) -DestinationHosts @([pscustomobject]@{ ComputerName = 'HV02' })) -MigrationLimit 1

        $reports = @($result.Reports)
        $reports.Count | Should Be 2
        $reports[0].Event | Should Be 'Migration started'
        $reports[1].Event | Should Be 'Migration job completed'
        $reports[0].VMName | Should Be 'APP01'
        $reports[0].DestinationHostName | Should Be 'HV02'
        $reports[0].JobId | Should Be 22
        $reports[0].JobLabel | Should Be 'Move APP01'
    }
}

<##
Manual confirmation-decline check:

1. Run the implementation without `-WhatIf`.
2. When PowerShell prompts for confirmation, answer `N`.
3. Verify no `Move-SCVirtualMachine` call occurs and the result has `Skipped = $true`.

The automated WhatIf test above exercises the non-start branch without requiring
an interactive prompt in the Pester 3 test runner.
#>
