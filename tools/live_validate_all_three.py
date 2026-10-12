#!/usr/bin/env python3
"""Run one installed fixed cFS scenario through the live Scenario API.

Execute inside an OpenC3 service container, where the existing service
credential is available. This helper never prints the credential or key bytes.
"""

import argparse
import json
import os
import sys
import time
import uuid

import requests


BASE = "http://scenario-api:2910/scenario-api"
TERMINAL = {"succeeded", "failed", "stopped"}


def request(method, path, **kwargs):
    response = requests.request(
        method, BASE + path,
        headers={"Authorization": os.environ["OPENC3_SERVICE_PASSWORD"]},
        timeout=15,
        **kwargs,
    )
    if not response.ok:
        raise RuntimeError(f"{method} {path}: HTTP {response.status_code}: {response.text[:500]}")
    return response.json()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manual", action="store_true",
                        help="Advance each pending step through the same API call as Run step")
    parser.add_argument("scenario_id")
    parser.add_argument("target", choices=("CFS-1_QEMU", "CFS-1_BBB"))
    args = parser.parse_args()
    catalog = request("GET", "/scenarios", params={"scope": "DEFAULT"})["items"]
    definition = next((entry for entry in catalog if entry["id"] == args.scenario_id), None)
    if definition is None or args.target not in definition["supportedTargets"]:
        raise RuntimeError("scenario or target is not installed")
    payload = {
        "scope": "DEFAULT",
        "scenario_id": definition["id"],
        "definition_version": definition["version"],
        "definition_hash": definition["definition_hash"],
        "target": args.target,
        "request_id": str(uuid.uuid4()),
    }
    if args.manual:
        payload["execution_mode"] = "manual"
    run = request("POST", "/runs", json=payload)
    run_id = run["id"]
    print(f"started {args.scenario_id} {args.target} run={run_id}", flush=True)
    deadline = time.monotonic() + (300 if args.manual else 180)
    answered = set()
    while time.monotonic() < deadline:
        run = request("GET", f"/runs/{run_id}", params={"scope": "DEFAULT"})
        prompt = run.get("prompt")
        if (args.manual and prompt and prompt.get("status") == "pending" and
                prompt["prompt_id"] not in answered):
            request("POST", f"/runs/{run_id}/prompt", json={
                "scope": "DEFAULT", "prompt_id": prompt["prompt_id"], "answer": "continue",
            })
            answered.add(prompt["prompt_id"])
        if run["state"] in TERMINAL:
            events, cursor = [], 0
            while True:
                page = request("GET", f"/runs/{run_id}/events",
                               params={"scope": "DEFAULT", "after": cursor, "limit": 100})
                events.extend(page["items"])
                cursor = page["next_cursor"]
                if len(page["items"]) < 100:
                    break
            commands = [event["data"] for event in events if event["type"] == "command"]
            if args.manual:
                step_ids = {step["id"] for step in definition["steps"]}
                if not commands or any(
                    command.get("step_id") not in step_ids or
                    not isinstance(command.get("packet"), str) or
                    not isinstance(json.loads(command.get("parameters_json", "null")), dict)
                    for command in commands
                ):
                    raise RuntimeError("manual run has incomplete TC command audit")
            print(f"TC command audit events={len(commands)}", flush=True)
            for event in events:
                if event["type"] == "step":
                    data = event["data"]
                    if data.get("status") in TERMINAL:
                        print(f"  {data.get('step_id')}: {data['status']} {data.get('message', '')}")
            # CRC results contain the recovered lab key. Keep helper output
            # to status fields so the terminal does not retain key material.
            print(f"result run={run_id} state={run['state']} error={run.get('error')} "
                  f"result_status={(run.get('result') or {}).get('status')}", flush=True)
            return 0 if run["state"] == "succeeded" else 1
        time.sleep(1)
    print(f"poll deadline reached for run={run_id}; inspect it in Scenario Runner", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
