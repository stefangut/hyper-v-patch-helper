# Drain-VRANode Design Contract

## Purpose

Drain running workloads from one SCVMM-managed Hyper-V cluster node while leaving Zerto VRA VMs on that node. The script runs on the SCVMM management host with the SCVMM PowerShell module loaded.

## First-iteration interface

### Parameters

- `-SourceVMHost` (required): SCVMM host name that defines the drain operation and is echoed in pre-flight and execution output.
- `-ClusterName` (optional): explicit SCVMM host-cluster name.
- `-PreFlight` (switch): performs discovery and reporting only.
- Standard common parameters supplied by `[CmdletBinding(SupportsShouldProcess)]`, including `-WhatIf` and `-Confirm`.

The script assumes an existing SCVMM connection. It does not call `Get-SCVMMServer` to establish one or select a VMM server.

## Discovery and validation

1. Resolve `-SourceVMHost` using `Get-SCVMHost`.
2. Resolve the source host's cluster, unless `-ClusterName` is supplied.
3. If the explicit cluster does not contain the source host, display the cluster nodes and exit without attempting migration.
4. Enumerate cluster nodes through SCVMM.
5. Sort destination nodes alphabetically and remove the source host.
6. Inspect node availability state.
7. If any cluster node is paused, unavailable, or in maintenance mode, report the anomaly and exit without starting moves.
8. Query VMs deployed on the source host with `Get-SCVirtualMachine -VMHost`.

Capacity, compatibility, and migration-viability checks are deliberately outside this contract.

## VM classification

- Action candidates are running VMs only.
- A VM is a Zerto VRA when its SCVMM name matches the case-sensitive regular expression `^ZVRA`.
- Zerto VRA VMs are reported as leave-in-place and are never passed to `Move-SCVirtualMachine`.
- Non-running VMs are reported separately in pre-flight and are not processed.
- Unexpected or incomplete SCVMM object data is reported as an anomaly rather than silently ignored.

PowerShell's default `-match` operator is case-insensitive; implementation must use a case-sensitive comparison such as `-cmatch '^ZVRA'`.

## Destination assignment

Eligible destinations are all healthy cluster nodes other than the source host. They are sorted by a stable host-name property, then assigned to action candidates in round-robin order:

```text
VM 1 -> destination 1
VM 2 -> destination 2
...
VM N -> destination ((N - 1) modulo destination count) + 1
```

The first iteration does not rebalance based on capacity or existing workload.

## Pre-flight contract

Pre-flight is read-only. It must display:

- Source host.
- Cluster name.
- Eligible destinations.
- `MIGRATE`: running non-ZVRA VMs and assigned destinations.
- `LEAVE - ZERTO`: running VMs matching `^ZVRA`.
- `LEAVE - NOT RUNNING`: VMs that are not running.
- Anomalies and blocking conditions.

Pre-flight must not invoke `Move-SCVirtualMachine`.

## Execution contract

1. Perform the same discovery and classification used by pre-flight.
2. Print the planned migration set, including source and destination hosts.
3. Request one confirmation for the complete set through `ShouldProcess`.
4. For each action candidate, invoke native SCVMM migration asynchronously:

```powershell
Move-SCVirtualMachine -VM $VM -VMHost $DestinationHost -RunAsynchronously
```

5. Report every migration trigger attempted and its result.
6. Continue after an individual trigger exception and report the exception as an anomaly.
7. Do not wait for asynchronous SCVMM jobs to complete.

The script should return a failure indication when trigger errors or blocking anomalies occur, while preserving fail-forward processing for independent VMs.

## Explicit non-goals

- Migrating or stopping Zerto VRA VMs.
- Direct Hyper-V, Failover Clustering, or Zerto Manager control.
- Capacity or live-migration viability testing.
- Waiting for or polling asynchronous migration jobs.
- Automatically tolerating paused, unavailable, or maintenance-mode nodes.
- Establishing SCVMM connections.

## Deferred decisions

Future versions may:

- Allow a configured number of paused or maintenance nodes.
- Add SCVMM job tracking and completion reporting.
- Add configurable destination ordering or balancing.
- Add capacity and compatibility validation.
- Add structured logging or an exportable report.
