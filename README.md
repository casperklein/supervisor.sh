<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <img alt="" src="assets/logo-light.png">
  </picture>
</div>

## Description

`supervisor.sh` is a process supervisor inspired by [Supervisord](https://supervisord.org/) written in Bash.
It's a lightweight _pure_ Bash solution, providing basic functionality to supervise processes (called jobs). The configuration is done in a YAML configuration file. By default, all jobs are automatically started and in case of an error (exit code > 0) restarted.

For environments like Docker container, where minimal overhead is desired, the dependency on `yq` can be removed by converting the YAML configuration to Bash.

### Foreground mode

Without the explicit `start` command, `supervisor.sh` runs in the foreground. It can be stopped by:

1. Pressing CTRL-C, which is equivalent to the SIGINT signal.
2. Running `supervisor.sh stop` in another session.

### Daemon mode

To run the supervisor in daemon mode, use `supervisor.sh start`.

## Dependencies

- Bash >= 5.1
- [yq](https://github.com/mikefarah/yq) - a lightweight and portable command-line YAML processor
- The following core utilities: cat mkdir readlink rm setsid sleep tail

The `yq` dependency can be removed. See [below](#run-without-the-yq-dependency).

## Installation

```bash
SV_VERSION=latest

# Supervisor
curl -sSLf -o /usr/bin/supervisor.sh "https://raw.githubusercontent.com/casperklein/supervisor.sh/refs/tags/$SV_VERSION/supervisor.sh"
chmod +x /usr/bin/supervisor.sh

# Bash completion (optional)
curl -sSLf -o /etc/bash_completion.d/supervisor.sh "https://raw.githubusercontent.com/casperklein/supervisor.sh/refs/tags/$SV_VERSION/supervisor-completion.bash"
```

## Usage

```text
Usage:
  supervisor.sh [OPTION] [COMMAND]

Configuration file:
  By default, the configuration is read from '/etc/supervisor.yaml'.
  If 'yq' is not available, '/etc/supervisor.yaml.sh' will be used instead.
  Provide '--config' to specify a custom configuration file.

Options:
  -c, --config     Specify configuration file, e.g. 'supervisor.sh -c /path/config.yaml'.
  -h, --help       Show this help.
  -n, --no-color   Disable color usage.
  -v, --version    Show version.

Commands:
  start            Start supervisor.sh as daemon.
  start <job>      Start job.
  stop             Stop supervisor.sh.
  stop  <job>      Stop job.
  restart          Restart daemon.
  restart <job>    Restart job.
  status           Show process states.
  fix              Fix unclean shutdown.
  log              Show continuously the supervisor.sh log (only for daemon mode)
  logs             Show continuously the supervisor.sh log + job logs.
  convert          Convert the YAML configuration file to Bash. This allows the
                   usage without the 'yq' dependency.

If no command is provided, supervisor.sh will start in foreground.
```

## Configuration file (`supervisor.yaml`)

By default, the configuration is read from `/etc/supervisor.yaml`. You can specify another location with the `--config` option.

### supervisor

Key                    | Required | Default       | Possible Values | Description
-----------------------|----------|---------------|-----------------|---------------------------------------------------------------------------------------------
`logfile`              | No       | `/dev/stdout` | Valid file path | Log file for supervisor output (only for daemon mode)
`sigterm_grace_period` | No       | `10`          | Any number      | Grace period in seconds until SIGKILL is send to processes that keeps running after SIGTERM.
`keep_running`         | No       | `off`         | `on`, `off`     | Exit supervisor when all jobs are stopped (`off`) or keep running (`on`).
`color`                | No       |               | e.g. `\e[0;34m` | Sets the text color using an escape sequence for terminal colors (only for forground mode).

### jobs

Key             | Required | Default       | Possible Values      | Description
----------------|----------|---------------|----------------------|------------------------------------------------------------------------------------------
`name`          | Yes      |               | Any string           | Job name
`command`       | Yes      |               | Any string           | Job command
`autostart`     | No       | `on`          | `on`, `off`          | Start the job automatically (`on`) or not (`off`).
`logfile`       | No       | `/dev/stdout` | Valid file path      | Write output to log file.
`restart`       | No       | `error`       | `error`, `on`, `off` | Restart the job if it exits, only on failure (`error`) or always (`on`) or never (`off`).
`restart_limit` | No       | `3`           | Any positive integer | Restart the job only n times. Set 0 for unlimited restarts.
`required`      | No       | `no`          | `no`, `yes`          | When a required job stops, all remaining jobs and the supervisor are stopped as well.

## Example

```yaml
supervisor:
  logfile: "/var/log/supervisor.log"
  sigterm_grace_period: 10
  keep_running: "off"
  color: "\e[0;34m" # blue text color

jobs:
  - name: "job1-restart"
    command: "echo 'Job 1: I will fail in 4 seconds. But supervisor will restart me 3 times.'; sleep 4; exit 1"
    autostart: "on"
    restart: "error"

  - name: "job2-no-restart"
    command: "echo 'Job 2: No restart for me on failure in 3 seconds.'; sleep 3; exit 1"
    restart: "off"

  - name: "job3-no-autostart"
    command: "echo 'Job 3: I was started manually'"
    autostart: "off"
    logfile: "/var/log/job4.log"

  - name: "job4-required"
    command: "echo 'Job 4: I am required. When I stop in 20 seconds, supervisor will stop too.'; sleep 20"
    restart: "off"
    required: "yes"

  - name: "job5-ignore-SIGTERM"
    command: "trap true SIGTERM; echo 'Job 5: I will ignore SIGTERM.'; while :; do sleep 1d; done"
```

## Bash completion

If you have [`bash-completion`](https://github.com/scop/bash-completion) installed, simply copy `supervisor-completion.bash` to `/etc/bash_completion.d/`.

Otherwise, you can source `supervisor-completion.bash` in your `.bashrc`.

## Run without the 'yq' dependency

If you want to remove the `yq` dependency, you can convert the YAML configuration to Bash. This conversion must be done in an environment where `yq` is available.

```bash
supervisor.sh -c /etc/supervisor.yaml convert

# Now you can use supervisor.sh without the 'yq' dependency
supervisor.sh -c /etc/supervisor.yaml.sh <command>
```

### Convert using Docker

```bash
docker run --rm -v "${PWD}":/workdir -u root --entrypoint /bin/sh mikefarah/yq -c "apk add bash; bash -c './supervisor.sh -c supervisor.yaml convert'"
```

## Used by these projects

- [Pi-hole for Home Assistant](https://github.com/casperklein/homeassistant-addons/blob/master/pi-hole/README.md)
- [docker-smokeping](https://github.com/casperklein/docker-smokeping)
