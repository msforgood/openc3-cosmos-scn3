#!/usr/bin/env python3
"""Run one installed fixed cFS scenario through the live Scenario API.

Execute inside an OpenC3 service container, where the existing service
credential is available. This helper never prints the credential or key bytes.
"""

import argparse
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
    run = request("POST", "/runs", json=payload)
    run_id = run["id"]
    print(f"started {args.scenario_id} {args.target} run={run_id}", flush=True)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        run = request("GET", f"/runs/{run_id}", params={"scope": "DEFAULT"})
        if run["state"] in TERMINAL:
            events = request("GET", f"/runs/{run_id}/events", params={"scope": "DEFAULT", "after": 0, "limit": 100})["items"]
            for event in events:
                if event["type"] == "step":
                    data = event["data"]
                    if data.get("status") in TERMINAL:
                        print(f"  {data.get('step_id')}: {data['status']} {data.get('message', '')}")
            print(f"result run={run_id} state={run['state']} error={run.get('error')} result={run.get('result')}", flush=True)
            return 0 if run["state"] == "succeeded" else 1
        time.sleep(1)
    print(f"poll deadline reached for run={run_id}; inspect it in Scenario Runner", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
