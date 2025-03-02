# supervisor.sh

## Description

`supervisor.sh` is a lightweight Bash script for managing processes based on a YAML configuration file. It runs in foreground or as a daemon, handling the starting, stopping, and monitoring of multiple programs or scripts. This makes it useful for systems where a simple, standalone process manager is needed, or for containerized environments where minimal overhead is desired.

## Dependencies

- Bash >= 5.1
- [yq](https://github.com/mikefarah/yq) - a lightweight and portable command-line YAML processor

The `yq` dependency can be removed. See [below](#run-without-the-yq-dependency).

## Usage

```text
Usage:
  supervisor.sh [OPTION] [COMMAND]

Options:
  -c, --config  Specify config file, e.g. 'supervisor.sh -c /path/to/supervisor.yaml'.
  -h, --help    Show this help.

Commands:
  start           Start supervisor.sh as daemon.
  start <job>     Start job.
  stop            Stop supervisor.sh.
  stop  <job>     Stop job.
  restart         Restart daemon.
  restart <job>   Restart job.
  status          Show process status.
  log             Show continuously the supervisor.sh log.
  logs            Show continuously the supervisor.sh log + job logs.
  convert         Convert the YAML config to Bash. This allows the usage without the 'yq' binary,
                  e.g. inside a Docker container where 'yq' is not available.

If no command is provided, supervisor.sh will start in foreground.
```

## Configuration file (`supervisor.yaml`)

### supervisor

Key                    | Required | Default       | Possible Values | Description
-----------------------|----------|---------------|-----------------|--------------------------------------------------------------------------------------------
`logfile`              | No       | `/dev/stdout` | Valid file path | Log file for output (only for daemon mode)
`sigterm_grace_period` | No       | `2`           | Any number      | Grace period in seconds until SIGKILL is send to processes that keeps running after SIGTERM
`keep_running`         | No       | `off`         | `on`, `off`     | Exit supervisor when all jobs are stopped (`off`) or keep running (`on`)

### jobs

Key         | Required | Default       | Possible Values      | Description
------------|----------|---------------|----------------------|---------------------------------------------------------------------------------
`name`      | Yes      |               | Any string           | Job name
`command`   | Yes      |               | Any string           | Job command
`autostart` | No       | `on`          | `on`, `off`          | Start job automatically (`on`) or not (`off`)
`restart`   | No       | `error`       | `error`, `on`, `off` | Restart a job if it exits, only on failure (`error`) or always (`on`) or never (`off`)
`logfile`   | No       | `/dev/stdout` | Valid file path      | Log file for output

## Example

```yaml
supervisor:
  logfile: "/var/log/supervisor.log"
  sigterm_grace_period: 2
  keep_running: "off"

jobs:
  - name: "job1"
    command: "echo 'I will fail soon. But supervisor will restart me'; sleep 10; exit 1"
    autostart: "on"
    restart: "error"
    logfile: "/var/log/job1.log"

  - name: "job2"
    command: "echo 'No restart for me on failure'; sleep 3; exit 1"
    restart: "off"
    logfile: /var/log/job2.log

  - name: "job3"
    command: "echo 'This output goes to the supervisor log file'"

  - name: "job4"
    command: "echo 'I was started manually'"
    autostart: "off"
    logfile: "/var/log/job4.log"
```

## Run without the 'yq' dependency

If you want to remove the `yq` dependency, you can convert the YAML configuration to Bash. However, this conversion must be done in an environment where `yq` is available.

```bash
supervisor.sh -c /etc/supervisor.yaml convert

# Now you can use supervisor.sh without the 'yq' dependency
supervisor.sh -c /etc/supervisor.yaml.sh <command>
```
