# Drain-VRANode

Drain running workloads from a Hyper-V cluster node through System Center Virtual Machine Manager (SCVMM), while leaving Zerto Virtual Replication Appliances (VRA) in place.

Zerto VRA VMs are identified by a case-sensitive name beginning with `ZVRA`. They must remain on their current host because Cluster-Aware Updating and similar cluster operations can attempt to move them unexpectedly.

## Requirements

- Windows PowerShell 5.1.
- The SCVMM PowerShell module available on the management host.
- An existing SCVMM connection before running the script, for example:

```powershell
Get-SCVMMServer -ComputerName VMM01
```

- Permissions to query SCVMM hosts and VMs and to start VM migration jobs.

## Modes

### Pre-flight

Pre-flight performs discovery only and does not start migration jobs. It reports:

- The requested source host.
- The resolved host cluster.
- Eligible destination nodes.
- Running VMs planned for migration and their round-robin destinations.
- Running VMs beginning with `ZVRA` that will be left in place.
- Non-running VMs that are outside the first-iteration action set.
- Any cluster node that is paused, unavailable, or in maintenance mode.

Example:

```powershell
.\Drain-VRANode.ps1 -SourceVMHost HVNODE01 -PreFlight
```

An explicit cluster can be supplied when required:

```powershell
.\Drain-VRANode.ps1 -SourceVMHost HVNODE01 -ClusterName HVCLUSTER01 -PreFlight
```

### Execution

After reviewing pre-flight output, execute the drain:

```powershell
.\Drain-VRANode.ps1 -SourceVMHost HVNODE01
```

The script requests one confirmation for the complete migration set and starts asynchronous `Move-SCVirtualMachine` jobs. It reports each attempted migration and continues processing if an individual trigger fails.

Use PowerShell's standard preview mode to display actions without starting them:

```powershell
.\Drain-VRANode.ps1 -SourceVMHost HVNODE01 -WhatIf
```

## Safety behavior

- Only running VMs are migration candidates.
- VMs whose names match `^ZVRA` are never selected.
- The source host is never selected as a destination.
- Destinations are selected from other nodes in the source host's cluster, sorted alphabetically, and assigned round-robin.
- If an explicit `-ClusterName` does not contain the source host, the script lists the cluster nodes and exits without migration.
- If any cluster node is paused, unavailable, or in maintenance mode, the script reports the condition and does not start moves.
- The script does not wait for asynchronous migration jobs to complete.

## Scope limitations

This first iteration does not perform placement-capacity or migration-viability validation. The environment is assumed to be right-sized and appropriately configured for live migration.

Future revisions may consider allowing a defined number of paused or maintenance nodes and evaluating SCVMM job completion.

## SCVMM operation

Migration is delegated to the native SCVMM cmdlet:

```powershell
Move-SCVirtualMachine -VM $VM -VMHost $DestinationHost -RunAsynchronously
```

SCVMM selects the appropriate transfer method for the clustered Hyper-V environment. The script does not use Hyper-V remoting or direct cluster-management cmdlets.
