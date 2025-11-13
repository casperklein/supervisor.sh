_supervisor_sh() {
	local cur=${COMP_WORDS[COMP_CWORD]}
	local prev=${COMP_WORDS[COMP_CWORD-1]}
	local prev2=${COMP_WORDS[COMP_CWORD-2]}

	local options="-c --config -h --help -n --no-color -v --version"
	local commands="start stop restart status fix log logs convert"
	local args="$options $commands"

	if (( COMP_CWORD == 1 )); then
		mapfile -t COMPREPLY < <(compgen -W "$args" -- "$cur")
	elif [[ "$prev2" =~ ^(start|stop|restart)$ ]]; then
		return 0
	else
		local i name jobs basename pid_dir="/var/run/supervisor.sh"

		case "$prev" in
			start)
				for i in "$pid_dir"/*.pid; do
					basename=${i##*/}
					name="${basename:0:-4}"
					if [[ "$name" != "*" && "$name" != "supervisor.sh" && -f "$i.stopped" ]]; then
						jobs+="$name "
					fi
				done
				mapfile -t COMPREPLY < <(compgen -W "$jobs" -- "$cur")
				;;

			stop|restart)
				for i in "$pid_dir"/*.pid; do
					basename=${i##*/}
					name="${basename:0:-4}"
					if [[ "$name" != "*" && "$name" != "supervisor.sh" && ! -f "$i.stopped" ]]; then
						jobs+="$name "
					fi
				done
				mapfile -t COMPREPLY < <(compgen -W "$jobs" -- "$cur")
				;;

			-h|--help|-v|--version|status|fix|log|logs|convert)
				return 0
				;;

			-c|--config)
				mapfile -t COMPREPLY < <(compgen -f -- "$cur")
				;;

			*)
				mapfile -t COMPREPLY < <(compgen -W "$args" -- "$cur")
				;;
		esac
	fi
	return 0
}

complete -F _supervisor_sh supervisor.sh
