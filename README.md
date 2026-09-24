# FH2OP Reconstruction Memory Tuner

Utility for safely adjusting RAM allocation for DJI FlightHub 2 On-Premises 2D and 3D reconstruction tasks.

The script locates the `task-scheduler-tasks.json` configuration file, identifies reconstruction tasks, applies a new RAM value, creates a backup, validates the resulting JSON, restarts the relevant services, and verifies whether the new configuration was loaded.

## Features

- Automatically searches for `task-scheduler-tasks.json`
- Detects 2D and 3D reconstruction tasks
- Changes RAM allocation in batch
- Shows current RAM values before modification
- Requires explicit confirmation before applying changes
- Creates an automatic timestamped backup
- Preserves original file permissions and ownership
- Validates JSON before and after modification
- Restarts `ts-admin` and `ts-scheduler`
- Verifies `/tmp/tasks.json` inside the containers
- Displays the final reconstruction task configuration
- Shows active reconstruction-related Kubernetes pods when `k3s` is available
- Supports manual configuration file selection
- Supports execution without restarting containers

## Target Tasks

The script modifies tasks whose names match:

```text
fh2-pri-aec-reconstruction-2d*
fh2-pri-aec-reconstruction-3d*
```

All matching tasks receive the same RAM configuration.

## Requirements

The script is designed for Linux environments running DJI FlightHub 2 On-Premises.

Required commands:

```text
bash
jq
awk
diff
mktemp
stat
find
readlink
tee
```

Docker is optional for the configuration change itself, but required for automatic container restart and post-change validation.

`k3s` is optional and is only used to display reconstruction-related pods at the end of the process.

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

Validate the Bash syntax:

```bash
bash -n fh2op_reconstruction_memory_tuner.sh
```

If the command produces no output, the syntax validation passed.

## Usage

Run normally:

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh
```

The script will:

1. Search for `task-scheduler-tasks.json`
2. Display the detected reconstruction tasks
3. Show their current RAM allocation
4. Ask for the new RAM value
5. Show the proposed changes
6. Require confirmation
7. Create a backup
8. Apply and validate the configuration
9. Restart the scheduler containers
10. Validate the configuration loaded by the containers

## Example

```text
[OK] Arquivo validado:
/fhop-install/install/conf/self-service/task-scheduler/task-scheduler-tasks.json

Tarefas que receberao o mesmo parametro de RAM:

  - fh2-pri-aec-reconstruction-2d | RAM atual: 32Gi
  - fh2-pri-aec-reconstruction-3d | RAM atual: 32Gi

Total encontrado: 2 tarefa(s).

Informe a nova memoria em GiB (ex.: 20, 24 ou 28): 20
```

The script then displays the proposed modification.

To continue, enter:

```text
APLICAR
```

No configuration change is performed before this confirmation.

## Command-Line Options

### Specify the Configuration File Manually

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh \
  --file /path/to/task-scheduler-tasks.json
```

This is useful when the FlightHub 2 installation uses a non-standard directory.

### Apply Without Restarting Containers

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh --no-restart
```

The configuration file will be modified and validated, but `ts-admin` and `ts-scheduler` will not be restarted.

### Combine Options

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh \
  --file /path/to/task-scheduler-tasks.json \
  --no-restart
```

### Help

```bash
./fh2op_reconstruction_memory_tuner.sh --help
```

## Configuration File Discovery

The script first attempts to identify the file through the Docker mounts of:

```text
ts-admin
ts-scheduler
```

It looks specifically for the host source mounted as:

```text
/tmp/tasks.json
```

It also checks known FlightHub 2 locations, including:

```text
/fhop-install/install/conf/self-service/task-scheduler/task-scheduler-tasks.json
/fhop-install/install/conf/middleware-service/task-scheduler/task-scheduler-tasks.json
```

Additional searches are performed under:

```text
/fhop-install
/data
/dados
/opt
/terra-install
/fh2-install
```

If no configuration file is found, the script asks the user to provide the path manually.

## RAM Input

RAM is entered as an integer representing GiB.

Examples:

```text
20
24
28
32
```

The script automatically converts the value to the format expected by FlightHub 2:

```text
20Gi
24Gi
28Gi
32Gi
```

Values between `1` and `512` GiB are accepted.

For values below `20Gi`, an additional confirmation is required because the probability of reconstruction jobs being terminated by `OOMKilled` increases significantly.

## Backup

Before modifying the original configuration file, the script creates a timestamped backup.

Example:

```text
task-scheduler-tasks.json.backup-20260923-224500
```

The backup is stored in the same directory as the original configuration file.

At the end of execution, the exact backup path is displayed.

## Rollback

To manually restore a backup:

```bash
sudo cp -a \
  /path/to/task-scheduler-tasks.json.backup-YYYYMMDD-HHMMSS \
  /path/to/task-scheduler-tasks.json
```

Then restart the relevant services:

```bash
sudo docker restart ts-admin ts-scheduler
```

## Validation

Before applying any modification, the script verifies that the configuration file contains a valid JSON array.

The generated temporary configuration is checked to confirm that:

- the JSON remains valid
- the number of reconstruction tasks is unchanged
- every matching reconstruction task contains the requested RAM value

After replacing the original file, validation is performed again.

If validation fails after the write operation, the script automatically restores the backup.

## Container Restart

Unless `--no-restart` is specified, the script attempts to restart:

```text
ts-admin
ts-scheduler
```

Equivalent command:

```bash
docker restart ts-admin ts-scheduler
```

If one of these containers does not exist, the script displays a warning and continues.

## Container Validation

After restarting a container, the script checks whether:

```text
/tmp/tasks.json
```

exists inside it.

The loaded configuration is then compared against the expected RAM value.

A successful validation appears similar to:

```text
[OK] ts-admin leu 2 tarefa(s) com memory=20Gi
[OK] ts-scheduler leu 2 tarefa(s) com memory=20Gi
```

## Kubernetes Jobs

The configuration change affects new reconstruction tasks created after the modification.

An already-created Job or Pod keeps the resource configuration with which it was originally created.

If `k3s` is installed, the script displays pods related to:

```text
reconstruction
terra
aec
```

This makes it easier to identify jobs that may still be running with the previous RAM allocation.

## Important

This script changes the FlightHub 2 task scheduler configuration directly.

DJI documentation recommends 32 GB or more for the model reconstruction service.

Reducing the task-level RAM requirement can allow reconstruction workloads to be scheduled on systems with less available memory, but it does not reduce the actual memory consumption required by a specific reconstruction job.

Large 2D or 3D reconstruction workloads may still fail due to insufficient RAM.

Typical symptoms include:

```text
OOMKilled
Out of memory
Pod terminated
Job failed
```

## Recommended Workflow

Before modifying a production environment:

```bash
bash -n fh2op_reconstruction_memory_tuner.sh
```

Check the existing reconstruction configuration:

```bash
jq '
  .[]
  | select(
      (.task_name // "")
      | test("^fh2-pri-aec-reconstruction-(2d|3d)"; "i")
    )
  | {
      task_name,
      cpu,
      memory,
      disk,
      executor_name
    }
' /path/to/task-scheduler-tasks.json
```

Then run the tuner:

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh
```

For systems with limited RAM, a starting value such as:

```text
20Gi
```

may be tested depending on workload size and available system resources.

Monitor reconstruction jobs after the change.

## Troubleshooting

### `choose_memory: command not found`

Example:

```text
line 2: choose_memory: command not found
```

This normally means the script file is incomplete or truncated.

Verify the beginning of the file:

```bash
head -20 fh2op_reconstruction_memory_tuner.sh
```

The first line should be:

```bash
#!/usr/bin/env bash
```

Validate the file:

```bash
bash -n fh2op_reconstruction_memory_tuner.sh
```

### `jq: command not found`

Install `jq`:

```bash
sudo apt update
sudo apt install -y jq
```

### Configuration File Not Found

Search manually:

```bash
sudo find / \
  -type f \
  -name 'task-scheduler-tasks.json' \
  2>/dev/null
```

Then run:

```bash
sudo ./fh2op_reconstruction_memory_tuner.sh \
  --file /full/path/task-scheduler-tasks.json
```

### Check Docker Mounts

```bash
sudo docker inspect ts-admin \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

```bash
sudo docker inspect ts-scheduler \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Look for:

```text
-> /tmp/tasks.json
```

The path on the left is the host configuration file.

### Check Current Container Status

```bash
sudo docker ps -a | grep -E 'ts-admin|ts-scheduler'
```

### Check Reconstruction Pods

```bash
sudo k3s kubectl get pods -A -o wide | \
grep -Ei 'reconstruction|terra|aec'
```

## Scope

This project changes only the RAM parameter of FlightHub 2 reconstruction task definitions.

It does not modify:

```text
CPU allocation
Disk allocation
GPU configuration
Docker resource limits
Host RAM
Kubernetes node resources
Terra reconstruction binaries
FlightHub 2 license configuration
```

## Disclaimer

This is an independent administrative utility and is not an official DJI tool.

Changes to FlightHub 2 On-Premises internal configuration should be tested before use in production environments.

Always keep a valid backup before modifying deployment configuration.
