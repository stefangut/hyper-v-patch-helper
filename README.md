# Drain-VRANode

Drain running workloads from a Hyper-V cluster node through System Center Virtual Machine Manager (SCVMM), while leaving Zerto Virtual Replication Appliances (VRA) in place.

Zerto VRA VMs are identified by a case-sensitive name beginning with `Z-VRA`. They must remain on their current host because Cluster-Aware Updating and similar cluster operations can attempt to move them unexpectedly.

## Requirements

- Windows PowerShell 5.1.
- The SCVMM PowerShell module available on the management host.
- An existing SCVMM connection before running the script, for example:

```powershell
Get-SCVMMServer -ComputerName VMM01
```

- Permissions to query SCVMM hosts and VMs and to start VM migration jobs.

## Implementation

The current implementation is [Drain-VRANode.Implementation.ps1](Drain-VRANode.Implementation.ps1). The files `Drain-VRANode.ps1` and `invoke-queuedexample.ps1` are pre-design proof-of-concept artifacts and are not part of the current implementation.

## Modes

### Pre-flight

Pre-flight performs discovery only and does not start migration jobs. It reports:

- The requested source host.
- The resolved host cluster.
- Eligible destination nodes.
- Running VMs planned for migration and their round-robin destinations.
- Running VMs beginning with `Z-VRA` that will be left in place.
- Non-running VMs that are outside the first-iteration action set.
- Any cluster node that is paused, unavailable, or in maintenance mode.

Example:

```powershell
\.\Drain-VRANode.Implementation.ps1 -SourceVMHost HVNODE01 -PreFlight
```

An explicit cluster can be supplied when required:

```powershell
\.\Drain-VRANode.Implementation.ps1 -SourceVMHost HVNODE01 -ClusterName HVCLUSTER01 -PreFlight
```

### Execution

After reviewing pre-flight output, execute the drain:

```powershell
\.\Drain-VRANode.Implementation.ps1 -SourceVMHost HVNODE01
```

The script requests one confirmation for the complete migration set and starts asynchronous `Move-SCVirtualMachine` jobs. It tracks SCVMM jobs, limits active migrations to the smallest `LiveMigrationMaximum` value across the source and eligible destinations, and continues processing if an individual trigger fails.

For the first node in a patch cycle, use `-FirstNode` to distribute migrations round-robin across healthy destinations:

```powershell
.\Drain-VRANode.Implementation.ps1 -SourceVMHost HVNODE01 -FirstNode
```

For subsequent nodes, omit `-FirstNode`. The script selects one healthy destination with the fewest running VMs. Ties are resolved by greatest `AvailableMemory`, then alphabetically by hostname:

```powershell
.\Drain-VRANode.Implementation.ps1 -SourceVMHost HVNODE02
```

Use PowerShell's standard preview mode to display actions without starting them:

```powershell
\.\Drain-VRANode.Implementation.ps1 -SourceVMHost HVNODE01 -WhatIf
```

## Operator runbook

Run the commands from Windows PowerShell 5.1 on a host with the SCVMM module loaded. The script assumes an existing SCVMM connection and does not establish one:

```powershell
Get-SCVMMServer -ComputerName VMM01
```

1. Run pre-flight and review the complete migration plan:

```powershell
$result = .\Drain-VRANode.Implementation.ps1 -SourceVMHost HVNODE01 -PreFlight
```

2. Add `-FirstNode` for the first node in the patch cycle; omit it for subsequent nodes.
3. Run with `-WhatIf` if an additional no-start preview is required.
4. Run the implementation without `-PreFlight` and answer the single confirmation prompt.
5. Review the reported SCVMM job IDs and inspect job state when required:

```powershell
Get-SCJob | Format-Table ID, Status, Description
```

### Runtime caveats

- The script starts asynchronous SCVMM jobs and may return while the last migration is still running.
- It exits when all planned VMs have been submitted; it does not wait for already-started asynchronous jobs after the queue is empty.
- Verify the VM's current host and SCVMM job state before rerunning the drain against the same source host.
- The first execution should target a non-production cluster and a small migration set.
- The effective global limit is the minimum `LiveMigrationMaximum` reported by the source and eligible destination hosts. If a value is unavailable or invalid, the operator must provide a positive fallback limit.
- The script does not perform capacity, compatibility, or live-migration viability checks.
- VMs whose names begin with case-sensitive `^Z-VRA` are left in place and are never submitted for migration.
- Availability checks use the SCVMM host properties `MaintenanceHost`, `AvailableForPlacement`, `CommunicationState`, `ClusterNodeStatus`, and `HyperVState`. Missing or unhealthy values block execution.

## Safety behavior

- Only running VMs are migration candidates.
- VMs whose names match `^Z-VRA` are never selected.
- The source host is never selected as a destination.
- Destinations are selected from other nodes in the source host's cluster, sorted alphabetically, and assigned round-robin.
- If an explicit `-ClusterName` does not contain the source host, the script lists the cluster nodes and exits without migration.
- If any cluster node is paused, unavailable, or in maintenance mode, the script reports the condition and does not start moves.
- The script does not wait for asynchronous migration jobs to complete after the submission queue is empty.

## Scope limitations

This first iteration does not perform placement-capacity or migration-viability validation. The environment is assumed to be right-sized and appropriately configured for live migration.

Future revisions may consider allowing a defined number of paused or maintenance nodes, improving completion reporting, and adding structured logging.

## SCVMM operation

Migration is delegated to the native SCVMM cmdlet:

```powershell
Move-SCVirtualMachine -VM $VM -VMHost $DestinationHost -RunAsynchronously
```

SCVMM selects the appropriate transfer method for the clustered Hyper-V environment. The script does not use Hyper-V remoting or direct cluster-management cmdlets.
