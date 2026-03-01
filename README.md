<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <img alt="" src="assets/logo-light.png">
  </picture>
</div>

## Description

`supervisor.sh` is a process supervisor inspired by [Supervisord](https://supervisord.org/) written in Bash.
It's a lightweight _almost pure_ Bash solution, providing basic functionality to supervise processes (called jobs). The configuration is done in a YAML configuration file. By default, all jobs are automatically started and, in case of an error (exit code > 0), restarted.

For environments like a Docker container, where minimal overhead is desired, the dependency on `yq` can be removed by converting the YAML configuration to Bash.

### Foreground mode

Without the explicit `start` command, `supervisor.sh` runs in the foreground. It can be stopped by:

1. Pressing CTRL-C.
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
SV_VERSION=0.14

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
  lint             Validate and display the full configuration, including implicit default values.
  log              Show continuously the supervisor.sh log (only for daemon mode)
  logs             Show continuously the supervisor.sh log + job logs.
  convert          Convert the YAML configuration file to Bash.
                   This allows the usage without the 'yq' dependency.

If no command is provided, supervisor.sh will start in foreground.
```

## Configuration file (`supervisor.yaml`)

By default, the configuration is read from `/etc/supervisor.yaml`. You can specify another location with the `--config` option.

### supervisor

Key                    | Required | Default             | Possible Values      | Description
-----------------------|----------|---------------------|----------------------|------------------------------------------------------------------------------------------------
`logfile`              | No       | `/dev/stdout`       | Valid file path      | Log file for supervisor output (only for daemon mode)
`sigterm_grace_period` | No       | `10`                | Any number           | Grace period in seconds until SIGKILL is sent to processes that keeps running after SIGTERM.
`keep_running`         | No       | `off`               | `on`, `off`          | Exit supervisor when all jobs are stopped (`off`) or keep running (`on`).
`color`                | No       |                     | `"\e[0;34m"` (blue)  | Text color defined as [escape sequence](https://gist.github.com/JBlond/2fea43a3049b38287e5e9cefc87b2124) for terminal colors (only foreground mode).
`color_error`          | No       | `"\e[1;31m]"` (red) | `"\e[0;32m"` (green) | Text color for errors defined as [escape sequence](https://gist.github.com/JBlond/2fea43a3049b38287e5e9cefc87b2124) for terminal colors (only foreground mode).
`time_format`          | No       | `%F %T`             | `strftime` format    | Time format that is used for status messages. See [`strftime`](https://linux.die.net/man/3/strftime) for possible values.

### jobs

Key             | Required | Default       | Possible Values      | Description
----------------|----------|---------------|----------------------|------------------------------------------------------------------------------------------
`name`          | Yes      |               | Any string           | Job name
`command`       | Yes      |               | Any string           | Job command
`autostart`     | No       | `on`          | `on`, `off`          | Start the job automatically (`on`) or not (`off`).
`logfile`       | No       | `/dev/stdout` | Valid file path      | Write output to log file.
`restart`       | No       | `error`       | `error`, `on`, `off` | Restart the job if it exits, only on failure (`error`) or always (`on`) or never (`off`).
`restart_limit` | No       | `3`           | Any positive integer | Restart the job only n times. Set 0 for unlimited restarts.
`required`      | No       | `no`          | `no`, `yes`          | When a required job terminates, all remaining jobs and `supervisor.sh` are stopped as well.

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
    logfile: "/var/log/job3.log"

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

## Demo / Tests

See `supervisor.sh` in action [here](assets/demo.gif) and [here](assets/demo-docker.gif).

You can also run the demo locally using `tests/run-tests.sh` or `tests/run-tests-docker.sh`. This will:

- Run some `yq` tests
- Print system environment information
- Start `supervisor.sh` with an [example](https://github.com/casperklein/supervisor.sh/blob/master/tests/supervisor.yaml) configuration.

This includes 4 jobs:

1. parent.sh: A simple bash script that starts a child process (`child.sh`) and then does nothing. When the TERM signal is received, the script terminates. When `child.sh` receives the TERM signal, it will be ignored. When `supervisor.sh` stops this job, it takes care, that the whole process group has terminated. Since child.sh ignores the TERM signal, the process will be killed (SIGKILL) after a grace period.

2. fail.sh: A simple bash script, that fails after 3 seconds. This job will be restarted 2 times on failure. On the third failure, `supervisor.sh` terminates, because the job is configured as _required_.

3. sleep: This job just sleeps for 1 day.

4. prefix: This jobs demonstrated, how to prefix a job output with the current date/time (this can easily match the `time_format` that `supervisor.sh` uses).

## Custom PID directory

By default, `/run/supervisor.sh` is used for storing files needed at runtime. To use another location, you can set the environment variable `PID_DIR`.

```bash
PID_DIR=/home/alice/supervisor.sh supervisor.sh start
```

This is useful when `supervisor.sh` runs rootless.

## Used by these projects

- [Pi-hole for Home Assistant](https://github.com/casperklein/homeassistant-addons/blob/master/pi-hole/README.md)
- [docker-smokeping](https://github.com/casperklein/docker-smokeping)
