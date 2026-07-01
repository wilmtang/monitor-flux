#!/usr/bin/env python3
"""Zoom mechanism test driver.

For each mode: launches the prototype app, steps through zoom levels, screenshots
the window, locates the color-marked probes, clicks them at their *visual*
positions via the app's synthetic-event command channel, and records which
control actions actually fired. Prints a pass/fail matrix.

Usage: driver.py <workdir> [mode ...]
"""
import json, os, subprocess, sys, time, shutil

REPO = os.path.dirname(os.path.abspath(__file__))
SHOT = os.path.join(os.path.dirname(REPO), "script", "_shot_sck.swift")
ANALYZE = os.path.join(REPO, "analyze.swift")
BINARY = os.path.join(REPO, ".build", "debug", "ZoomMatrix")

ZOOMS = [1.0, 1.5, 2.0]
# probe -> expected hit-log prefix
PROBES = [
    ("btn-top", "btn-top"),
    ("toggle-a", "toggle-a="),
    ("btn-trailing", "btn-trailing"),
    ("btn-bottom", "btn-bottom"),
    ("nav-schedule", "nav-schedule"),
    ("nav-general", "nav-general"),
]


class Session:
    def __init__(self, workdir, mode):
        self.dir = os.path.join(workdir, mode)
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.mode = mode
        self.n = 0
        env = dict(os.environ, PROTO_DIR=self.dir, ZOOM_MODE=mode)
        self.log = open(os.path.join(self.dir, "app.log"), "w")
        self.proc = subprocess.Popen([BINARY], env=env, stdout=self.log, stderr=self.log)
        self.state = self.wait_for_state()

    def wait_for_state(self, timeout=15):
        path = os.path.join(self.dir, "state.json")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(path):
                time.sleep(0.2)
                with open(path) as f:
                    return json.load(f)
            time.sleep(0.2)
        raise RuntimeError(f"state.json never appeared for {self.mode}")

    def cmd(self, text, timeout=10):
        self.n += 1
        n = self.n
        with open(os.path.join(self.dir, f"cmd-{n}.txt"), "w") as f:
            f.write(text + "\n")
        ack = os.path.join(self.dir, f"ack-{n}.txt")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(ack):
                return
            time.sleep(0.05)
        raise RuntimeError(f"no ack for '{text}' in {self.mode}")

    def read_hits(self):
        path = os.path.join(self.dir, "hits.log")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [line.strip() for line in f if line.strip()]

    def screenshot(self, tag):
        with open(os.path.join(self.dir, "state.json")) as f:
            self.state = json.load(f)
        png = os.path.join(self.dir, f"shot-{tag}.png")
        r = subprocess.run(["swift", SHOT, str(self.state["windowID"]), png],
                           capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise RuntimeError(f"screenshot failed: {r.stdout} {r.stderr}")
        out = os.path.join(self.dir, f"probes-{tag}.json")
        r = subprocess.run(["swift", ANALYZE, png, out], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"analyze failed: {r.stdout} {r.stderr}")
        with open(out) as f:
            return json.load(f)

    def quit(self):
        try:
            self.cmd("quit", timeout=3)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()
        self.log.close()


def to_window(state, blobs, px, py):
    frame = state["frame"]
    k = blobs["imgW"] / frame["w"]  # px per point (from any blob entry)
    return px / k, frame["h"] - py / k


def run_mode(workdir, mode):
    s = Session(workdir, mode)
    results = {}
    try:
        for zoom in ZOOMS:
            s.cmd(f"zoom {zoom}")
            time.sleep(0.6)
            blobs = s.screenshot(f"z{zoom}")
            if "calib" not in blobs:
                results[zoom] = {"error": "calibration marker not found"}
                continue
            calib = blobs["calib"]
            cwx, cwy = to_window(s.state, calib, calib["cx"], calib["cy"])
            offx = s.state["calib"]["x"] - cwx
            offy = s.state["calib"]["y"] - cwy
            zres = {"_offset": (round(offx, 1), round(offy, 1))}
            for probe, expect in PROBES:
                if probe not in blobs:
                    zres[probe] = "MARKER-MISSING"
                    continue
                b = blobs[probe]
                if probe == "toggle-a":
                    # switch sits near the trailing edge of the colored row strip;
                    # in semantic mode the switch keeps its native (unscaled) size
                    ex, ey = to_window(s.state, b, b["maxX"], (b["minY"] + b["maxY"]) / 2)
                    ex -= 24 if mode == "semantic" else 24 * zoom
                else:
                    ex, ey = to_window(s.state, b, b["cx"], b["cy"])
                before = len(s.read_hits())
                s.cmd(f"click {ex + offx:.1f} {ey + offy:.1f}")
                new = s.read_hits()[before:]
                hit = any(line.split(" ", 1)[1].startswith(expect) for line in new if " " in line)
                zres[probe] = "PASS" if hit else f"FAIL({';'.join(x.split(' ',1)[1] for x in new) or 'no-hit'})"
            results[zoom] = zres
    finally:
        s.quit()
    return results


def main():
    workdir = sys.argv[1]
    modes = sys.argv[2:] or ["bounds", "magnify", "scaleeffect", "semantic"]
    all_results = {}
    for mode in modes:
        print(f"=== {mode} ===", flush=True)
        try:
            all_results[mode] = run_mode(workdir, mode)
        except Exception as e:
            all_results[mode] = {"error": str(e)}
        print(json.dumps(all_results[mode], indent=1, default=str), flush=True)
    with open(os.path.join(workdir, "matrix.json"), "w") as f:
        json.dump(all_results, f, indent=1, default=str)
    # summary table
    print("\n===== MATRIX =====")
    for mode, res in all_results.items():
        for zoom, zres in (res.items() if isinstance(res, dict) else []):
            if not isinstance(zres, dict):
                continue
            row = " ".join(f"{p}:{'✓' if zres.get(p)=='PASS' else '✗'}" for p, _ in PROBES)
            print(f"{mode:12s} z={zoom}: {row}")


if __name__ == "__main__":
    main()
