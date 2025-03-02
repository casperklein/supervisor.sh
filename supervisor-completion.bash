_supervisor_sh() {
	local cur prev args

	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD-1]}

	if (( COMP_CWORD == 1 )); then
		args="-c --config -h --help start stop restart status log logs convert"
		COMPREPLY=( $(compgen -W "$args" -- "$cur") )

	elif (( COMP_CWORD == 2 )); then
		local i name jobs pid_dir="/var/run/supervisor.sh"

		case "$prev" in
			start)
				for i in "$pid_dir"/*.pid; do
					name=$(basename "${i:0:-4}")
					if [[ "$name" != "*" && "$name" != "supervisor.sh" && -f "$pid_dir"/$name.pid.stopped ]]; then
						jobs+="$name "
					fi
				done
				COMPREPLY=( $(compgen -W "$jobs" -- "$cur") )
				;;

			stop|restart)
				for i in "$pid_dir"/*.pid; do
					name=$(basename "${i:0:-4}")
					if [[ "$name" != "*" && "$name" != "supervisor.sh" && ! -f "$pid_dir"/$name.pid.stopped ]]; then
						jobs+="$name "
					fi
				done
				COMPREPLY=( $(compgen -W "$jobs" -- "$cur") )
				;;
		esac
	fi
	return 0
}

complete -F _supervisor_sh supervisor.sh
