import json
import os

OK = "ok"
FAILED = "failed"


def append(sink, route, outcome):
    with open(sink, "a") as fh:
        fh.write(json.dumps({"route": route, "outcome": outcome}) + "\n")


def summarise(sink):
    out = {"qmd_calls": 0, "graph_calls": 0, "route_failed": 0}
    if not sink or not os.path.exists(sink):
        return out
    with open(sink) as fh:
        for line in fh:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("route") == "qmd":
                out["qmd_calls"] += 1
            elif row.get("route") == "graph":
                out["graph_calls"] += 1
            if row.get("outcome") != OK:
                out["route_failed"] += 1
    return out
