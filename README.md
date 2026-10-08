

# FH2OP Reconstruction & Panorama Memory Tuner

Utility for safely adjusting RAM allocation for DJI FlightHub 2 On-Premises 2D, 3D reconstruction, and Panorama Stitching tasks.

The script locates the `task-scheduler-tasks.json` configuration file, identifies reconstruction and panorama stitching tasks, applies a new RAM value, creates an automatic backup, validates the resulting JSON, restarts relevant services, and verifies whether the new configuration was loaded into the running containers.

## Authors & Collaborators

- **Caio Boa Morte** - Intelbras (Original Author & Core Architecture)
- **Felipe Beserra** - BRASA (Collaborator & Feature Contributor)

---

## Release Notes & Changelog

### Version 1.1.0 - Panorama Stitching & Regex Enhancement

*Contributed by **Felipe Beserra (BRASA / USP)***

- **Feature (Panorama Task Support)**: Expanded memory tuning scope beyond 2D/3D reconstruction to cover panorama stitching tasks (`fh2-pri-pano-stitch` and `fh2-pri-pf-terra-pano-stitch`).
- **Root Cause Resolution**: Identified and fixed silent OOM failures during high-zoom (e.g., 3x zoom) panorama processing by updating JSON task limits.
- **Improved Regex Matching**: Replaced `TASK_PATTERN` with `^fh2-pri-(aec-reconstruction-(2d|3d)|(pf-terra-)?pano-stitch)` to dynamically match both reconstruction and panorama task variants.
- **Enhanced Diagnostics**: Added Kubernetes/k3s diagnostic guidelines and log inspection workflows for `task-scheduler-gpu` pods.

---

## Features

- **Automatic File Discovery**: Searches standard FlightHub 2 paths and container bind mounts for `task-scheduler-tasks.json`.
- **Multi-Task Support**: Detects 2D and 3D reconstruction tasks as well as panorama stitching tasks (`fh2-pri-pano-stitch` and `fh2-pri-pf-terra-pano-stitch`).
- **Batch Modification**: Adjusts RAM allocation uniformly across all matched tasks.
- **Safety & Validation**:
  - Displays current RAM values before applying changes.
  - Requires explicit user confirmation (`APLICAR`).
  - Automatically generates a timestamped backup (`.backup-YYYYMMDD-HHMMSS`).
  - Preserves original file permissions and ownership (`chmod` / `chown`).
  - Validates JSON structure and task count before and after write operations.
  - Automatically rolls back to the backup if post-write validation fails.
- **Container Synchronisation**: Restarts `ts-admin` and `ts-scheduler` containers and verifies `/tmp/tasks.json` inside them.
- **Kubernetes Inspection**: Lists active processing pods in `k3s` upon completion.
- **CLI Flags**: Supports custom file paths (`--file`) and execution without restarting services (`--no-restart`).

---

## Target Tasks

The script modifies tasks matching the regular expression:

```text
^fh2-pri-(aec-reconstruction-(2d|3d)|(pf-terra-)?pano-stitch)
```

Specifically:

* `fh2-pri-aec-reconstruction-2d`
* `fh2-pri-aec-reconstruction-3d`
* `fh2-pri-pano-stitch`
* `fh2-pri-pf-terra-pano-stitch`

All matching tasks receive the updated RAM configuration.

---

## Requirements

Designed for Linux environments running DJI FlightHub 2 On-Premises.

Required commands:

```text
bash, jq, awk, diff, mktemp, stat, find, readlink, tee

```

* **Docker**: Optional for file editing, but required for container restarts and post-change container verification.
* **k3s**: Optional; used to display active processing pods upon script completion.

---

## Installation

Clone the repository:

```bash
git clone <repository-url>
cd fh2op-reconstruction-memory-tuner

```

Make the script executable:

```bash
chmod +x fh2op_reconstruction_memory_tuner.sh

```

Validate Bash syntax:

```bash
bash -n fh2op_reconstruction_memory_tuner.sh

```

*(If the command outputs nothing, syntax validation passed.)*

---

## Usage

Run with administrative privileges:

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh

```

### Script Execution Flow

1. Searches for `task-scheduler-tasks.json`.
2. Displays all detected reconstruction and panorama tasks with current RAM allocations.
3. Prompts for the new RAM value (in GiB).
4. Displays a diff of proposed JSON changes.
5. Requires explicit user confirmation (type `APLICAR`).
6. Creates an atomic, timestamped backup file.
7. Applies and validates the JSON configuration.
8. Restarts scheduler containers (`ts-admin` and `ts-scheduler`).
9. Confirms that containers loaded the updated configuration in `/tmp/tasks.json`.
10. Lists active related Kubernetes pods (`k3s kubectl`).

---

## Example Output

```text
[OK] Arquivo validado:
/fhop-install/install/conf/self-service/task-scheduler/task-scheduler-tasks.json

Tarefas que receberao o mesmo parametro de RAM:

  - fh2-pri-aec-reconstruction-2d | RAM atual: 32Gi
  - fh2-pri-aec-reconstruction-3d | RAM atual: 32Gi
  - fh2-pri-pano-stitch | RAM atual: 32Gi
  - fh2-pri-pf-terra-pano-stitch | RAM atual: 32Gi

Total encontrado: 4 tarefa(s).

Informe a nova memoria em GiB (ex.: 20, 24, 32 ou 64): 20

```

To confirm and write changes:

```text
APLICAR

```

*(No files are modified prior to entering this exact string.)*

---

## Command-Line Options

### Specify Configuration File Manually

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh \
  --file /path/to/task-scheduler-tasks.json

```

### Apply Without Restarting Containers

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh --no-restart

```

### Display Help

```bash
./fh2op_reconstruction_memory_tuner.sh --help

```

---

## Practical Insights & Root Cause Analysis

1. **Task Requests vs. Allocation Limits**:
   Setting memory limits too low (e.g., `2Gi`) causes the engine or container to fail immediately at startup due to heap allocation overhead or kernel `OOMKilled` termination. Increasing the requirement (e.g., to `20Gi` or `24Gi`) ensures Kubernetes schedules pods with guaranteed resources to complete processing.
2. **High-Zoom Panorama Stitching (`pano-stitch`)**:
   Panorama generation tasks (especially panoramic shots with 3x or higher zoom levels) process high-resolution image matrices during alignment and stitching. Standard factory defaults often cause `fh2-pri-pf-terra-pano-stitch` and `fh2-pri-pano-stitch` tasks to fail due to memory exhaustion. Updating these task limits alongside 2D/3D reconstruction tasks resolves OOM errors during high-zoom panorama generation.

---

## Relevant Diagnostic Commands

Commands for troubleshooting task execution and mapping job creation within the cluster:

### 1. General Cluster Status

Check overall pod status and identify node scheduling issues:

```bash
sudo k3s kubectl get pods -A -o wide

```

### 2. Identify Mapping / Job Events

Map task requests to created Kubernetes jobs in the GPU scheduler namespace:

```bash
sudo k3s kubectl get events -n task-scheduler-gpu --sort-by='.metadata.creationTimestamp'

```

### 3. Inspect Task Container Logs

Retrieve execution logs for a specific pod ID (e.g., `fh2-pri-pano-stitch-*` or `fh2-pri-pf-terra-pano-stitch-*`):

```bash
sudo k3s kubectl logs -n task-scheduler-gpu <POD_ID>

```

*Tip: If the pod was terminated due to an OOM error, use the `-p` (`--previous`) flag:*

```bash
sudo k3s kubectl logs -n task-scheduler-gpu <POD_ID> -p

```

### 4. Verify Allocated Pod Limits

Confirm the active resource limits and requests of a running pod:

```bash
sudo k3s kubectl describe pod -n task-scheduler-gpu <POD_ID> | grep -A 5 -i "Limits\|Requests"

```

---

## Backup & Rollback

### Rollback Procedure

To restore a backup created by the script:

```bash
sudo cp -a \
  /path/to/task-scheduler-tasks.json.backup-YYYYMMDD-HHMMSS \
  /path/to/task-scheduler-tasks.json

```

Restart services to apply the original configuration:

```bash
sudo docker restart ts-admin ts-scheduler

```

---

## Scope & Limitations

This script updates the RAM memory configuration parameter in FlightHub 2 task definitions.

It does **not** modify:

* CPU allocation or GPU binding.
* Kubernetes node capacity or host system RAM.
* Core DJI Terra reconstruction binaries.
* Already running or past Kubernetes Jobs/Pods (changes apply exclusively to newly spawned jobs).

---

## Disclaimer

This utility is an independent administrative script and is not an official DJI product. Test all configuration changes in a non-production environment before applying them to critical infrastructure. Always maintain valid system backups.

```

```
