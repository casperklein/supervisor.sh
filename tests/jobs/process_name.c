/*
Test program to verify that _get_starttime_from_pid() in supervisor.sh
correctly handles process names containing parentheses.
*/

#include <unistd.h>
#include <sys/prctl.h>

int main(void) {
	// Set the name of the current thread to "a (b) c".
	prctl(PR_SET_NAME, "a (b) c", 0, 0, 0);

	// Wait for 60 seconds and exit the program successfully.
	sleep(60);
	return 0;
}
