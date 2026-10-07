# Environment arguments are supplied by the management API's fixed run request.
# Failures must neither pause for native input nor continue to another line.
from openc3.utilities.running_script import RunningScript
RunningScript.pause_on_error = False
RunningScript.instance.continue_after_error = False

from cfs_scenario_runner import run_from_environment
run_from_environment()
