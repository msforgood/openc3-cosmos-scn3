"""Run in the 6.10.1 Script Runner image with --network none; no deployment IO."""
import ast
import importlib.metadata
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import cfs_scenario_runner
import openc3.script
from openc3.script.script_runner import script_run
from openc3.utilities.running_script import RunningScript
from openc3.utilities.script_instrumentor import ScriptInstrumentor

assert importlib.metadata.version("openc3") == "6.10.1"

# Exercise the real 6.10.1 AST instrumentation and exception handling. Stub only
# output/state IO so this cannot touch Redis, buckets, APIs, or any target.
running = object.__new__(RunningScript)
running.exceptions = None
running.script_status = SimpleNamespace(errors=None)
running.use_instrumentation = True
running.line_offset = 0
running.continue_after_error = True
running.retry_needed = False
running.handle_output_io = lambda *a: None
running.pre_line_instrumentation = lambda *a: None
running.post_line_instrumentation = lambda *a: None
running.mark_error = lambda: (_ for _ in ()).throw(AssertionError("native pause attempted"))
running.wait_for_go_or_stop_or_retry = lambda *a: (_ for _ in ()).throw(AssertionError("native prompt attempted"))
RunningScript.instance = running
RunningScript.error = None
RunningScript.pause_on_error = True
source = (ROOT / "targets/SCENARIO_RUNNER/procedures/run_scenario.py").read_text()
source += "\nmarkers.append('later-line')\n"
tree = ast.fix_missing_locations(ScriptInstrumentor("SCENARIO_RUNNER/procedures/run_scenario.py").visit(ast.parse(source)))
markers = []
with patch.object(cfs_scenario_runner, "run_from_environment", side_effect=cfs_scenario_runner.ScenarioError("command_error")), patch("openc3.utilities.running_script.Logger", SimpleNamespace(error=lambda *args: None)):
    try:
        exec(compile(tree, "run_scenario.py", "exec"), {"RunningScript": RunningScript, "markers": markers})
        raise AssertionError("failure continued")
    except cfs_scenario_runner.ScenarioError as error:
        assert str(error) == "command_error"
assert not markers
assert RunningScript.pause_on_error is False
assert running.continue_after_error is False
assert len(running.exceptions) == 1

# Real script_run must use the documented environment array, never generated
# source, argv, or an authentication field inside that array.
requests = []
def request(*args, **kwargs):
    requests.append((args, kwargs))
    return SimpleNamespace(status_code=200, text="17")
with patch.object(openc3.script, "SCRIPT_RUNNER_API_SERVER", SimpleNamespace(request=request)):
    result = script_run("SCENARIO_RUNNER/procedures/run_scenario.py", environment={"SCENARIO_RUN_ID": "run17"}, scope="DEFAULT")
assert result == 17
assert requests[0][0] == ("post", "/script-api/scripts/SCENARIO_RUNNER/procedures/run_scenario.py/run")
assert requests[0][1]["data"] == {"environment": [{"key": "SCENARIO_RUN_ID", "value": "run17"}]}
print("OpenC3 6.10.1: real instrumentation stops on exception without pause/continue; script_run environment encoding verified")
