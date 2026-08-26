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
9. Resolve the Hyper-V live-migration maximum for the source host and each eligible destination host.
10. Set the global migration concurrency limit to the smallest resolved value across the source host and eligible destination hosts. If a value cannot be resolved or is invalid, prompt the operator for a replacement global limit before execution.

Capacity, compatibility, and other migration-viability checks are deliberately outside this contract. Live-migration maximums are used only for throttling.

## VM classification

- Action candidates are running VMs only.
- A VM is a Zerto VRA when its SCVMM name matches the case-sensitive regular expression `^Z-VRA`.
- Zerto VRA VMs are reported as leave-in-place and are never passed to `Move-SCVirtualMachine`.
- Non-running VMs are reported separately in pre-flight and are not processed.
- Unexpected or incomplete SCVMM object data is reported as an anomaly rather than silently ignored.

PowerShell's default `-match` operator is case-insensitive; implementation must use a case-sensitive comparison such as `-cmatch '^Z-VRA'`.

## Destination assignment

Eligible destinations are all healthy cluster nodes other than the source host. They are sorted by a stable host-name property, then assigned to action candidates in round-robin order:

```text
VM 1 -> destination 1
VM 2 -> destination 2
...
VM N -> destination ((N - 1) modulo destination count) + 1
```

The first iteration does not rebalance based on capacity or existing workload.

## Migration queue and throttling

- The first iteration processes one source host per script invocation, so one global migration queue and one global active-job count are sufficient.
- The queue contains the planned action candidates in their existing destination-assignment order.
- The script must never have more active SCVMM migration jobs than the effective global concurrency limit.
- The effective limit is the minimum of the source host's and eligible destination hosts' Hyper-V maximum live-migration settings.
- When the configured maximum cannot be queried or is invalid, prompt the operator for a positive integer limit. Do not silently use a default.
- Each asynchronous `Move-SCVirtualMachine` result must be tracked as an SCVMM job.
- While queued candidates remain, query tracked SCVMM job state and release a slot when a job reaches a terminal state, including success or failure. A released slot may be used for the next queued candidate.
- A trigger exception is reported as an anomaly and immediately releases its slot so independent queued candidates can continue.
- The script exits after the queue length reaches zero; it does not wait for already-started asynchronous jobs to complete after all candidates have been submitted.
- The queue is a scheduling mechanism only. It does not create destination-specific queues or change the round-robin destination assignments.

## Pre-flight contract

Pre-flight is read-only. It must display:

- Source host.
- Cluster name.
- Eligible destinations.
- `MIGRATE`: running non-Z-VRA VMs and assigned destinations.
- `LEAVE - ZERTO`: running VMs matching `^Z-VRA`.
- `LEAVE - NOT RUNNING`: VMs that are not running.
- Anomalies and blocking conditions.

Pre-flight must not invoke `Move-SCVirtualMachine`.

## Execution contract

1. Perform the same discovery and classification used by pre-flight.
2. Print the planned migration set, including source and destination hosts.
3. Resolve the effective global migration concurrency limit before starting migration. If prompting is required, obtain the operator's replacement limit.
4. Request one confirmation for the complete set through `ShouldProcess`.
5. Fill and service the global queue without exceeding the effective concurrency limit. For each action candidate released from the queue, invoke native SCVMM migration asynchronously:

```powershell
Move-SCVirtualMachine -VM $VM -VMHost $DestinationHost -RunAsynchronously
```

6. Track the returned SCVMM job and report every migration trigger attempted and its job identity or result.
7. Continue after an individual trigger exception and report the exception as an anomaly.
8. While candidates remain queued, poll tracked SCVMM jobs to determine when slots become available. Do not wait for already-started jobs after the queue is empty.

The script should return a failure indication when trigger errors, invalid operator input, or blocking anomalies occur, while preserving fail-forward processing for independent VMs.

## Explicit non-goals

- Migrating or stopping Zerto VRA VMs.
- Direct Hyper-V, Failover Clustering, or Zerto Manager control.
- Capacity or live-migration viability testing.
- Waiting for asynchronous migration jobs after the submission queue is empty.
- Automatically tolerating paused, unavailable, or maintenance-mode nodes.
- Establishing SCVMM connections.

## Deferred decisions

Future versions may:

- Allow a configured number of paused or maintenance nodes.
- Add configurable destination ordering or balancing.
- Add capacity and compatibility validation.
- Add structured logging or an exportable report.
