#!/opt/ont/minknow/ont-python/bin/python
"""Run an isolated, hardware-free MinKNOW for TUI development (Linux)."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("MINKNOW_PLAYBACK_ROOT", PROJECT / ".playback")).resolve()
INSTALL = Path("/opt/ont/minknow")
PYTHON = INSTALL / "ont-python/bin/python"
CONF = ROOT / "conf"
PID = ROOT / "manager.pid"
CA = ROOT / "data/rpc-certs/minknow/ca.crt"


def prepare():
    CONF.mkdir(parents=True, exist_ok=True)
    for name in ("data", "logs"):
        (ROOT / name).mkdir(exist_ok=True)
    for source in (INSTALL / "conf").iterdir():
        target = CONF / source.name
        if source.name not in ("app_conf", "user_conf") and not target.exists():
            target.symlink_to(source)
    user = json.loads((INSTALL / "conf/user_conf").read_text())
    dirs = user["user"]["output_dirs"]
    dirs["base"]["value0"] = str(ROOT / "data")
    dirs["logs"]["value0"] = str(ROOT / "logs")
    (CONF / "user_conf").write_text(json.dumps(user, indent=2) + "\n")
    app = json.loads((INSTALL / "conf/app_conf").read_text())
    basecaller = app["application"]["basecaller"]
    basecaller["server_config"]["log_path"]["value0"] = str(ROOT / "logs/dorado")
    basecaller["server_config"]["gpu_calling"] = False
    basecaller["server_config"]["server_model_download_path"]["value0"] = str(ROOT / "data/models")
    basecaller["connection"]["server_ipc_file"]["value0"] = str(ROOT / "data/dorado.sock")
    basecaller["start_basecaller_from_minknow"] = True
    (CONF / "app_conf").write_text(json.dumps(app, indent=2) + "\n")
    if not CA.exists():
        subprocess.run([str(INSTALL / "bin/rpc_certs_gen"),
                        "--minknow-out-dir", str(CA.parent),
                        "--mooneye-out-dir", str(CA.parent.parent / "mooneye")], check=True)


def owned_pid():
    if PID.exists():
        pid = int(PID.read_text().strip())
        try:
            command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            if str(CONF).encode() in command and str(INSTALL / "bin/mk_manager_svc").encode() in command:
                return pid
        except FileNotFoundError:
            pass
    return None


def manager():
    if not owned_pid():
        raise RuntimeError("This playback manager is not running; use start first.")
    os.environ["MINKNOW_TRUSTED_CA"] = str(CA)
    from minknow_api.manager import Manager
    return Manager(host="localhost", port=9501)


def position():
    m = manager()
    p = next((p for p in m.flow_cell_positions() if p.name == "MS00000" and p.is_simulated), None)
    if p is None:
        raise RuntimeError("The dedicated simulated MS00000 position is not ready.")
    return p


def start():
    if owned_pid():
        print(f"Already running: PID {owned_pid()}")
        return
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 9501)) == 0:
            raise RuntimeError("Port 9501 is occupied. Stop the other manager before starting this environment.")
    prepare()
    with (ROOT / "manager-console.log").open("a") as log:
        process = subprocess.Popen([str(INSTALL / "bin/mk_manager_svc"), "--config", str(CONF),
                                    "--no-hardware", "--simulated-minion-devices", "1", "--print-rpc-ports"],
                                   cwd=INSTALL, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
    PID.write_text(str(process.pid) + "\n")
    deadline = time.monotonic() + 120
    last_error = "not ready"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Manager exited; see {ROOT / 'manager-console.log'}")
        try:
            # Each attempt gets fresh API credentials. A probe before startup
            # completes can otherwise cache an unauthenticated connection.
            probe = subprocess.run([str(PYTHON), str(Path(__file__).resolve()), "status"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                   text=True, timeout=5)
            if probe.returncode:
                raise RuntimeError(probe.stderr.strip())
            print(f"Ready: localhost:9501 / MS00000 / PID {process.pid}")
            return
        except Exception as error:
            last_error = str(error)
            time.sleep(1)
    raise RuntimeError(f"Startup not ready after 120s: {last_error}; see {ROOT / 'logs'} (manager left running).")


def run(args):
    bulk = Path(args.bulk).resolve()
    if not bulk.is_file():
        raise RuntimeError(f"Bulk FAST5 not found: {bulk}")
    c = position().connect()
    import grpc
    try:
        current = c.protocol.get_current_protocol_run()
        if not current.end_time.seconds:
            raise RuntimeError(f"A protocol is already active: {current.run_id}")
    except grpc.RpcError as error:
        if error.code() != grpc.StatusCode.FAILED_PRECONDITION:
            raise
    command = [str(PYTHON), "-m", "minknow_api.examples.start_protocol", "--host", "localhost", "--port", "9501",
               "--position", "MS00000", "--kit", args.kit, "--product-code", args.product,
               "--sample-id", "tui-playback", "--experiment-group", "tui-validation", "--pod5",
               "--experiment-duration", str(args.minutes / 60), "--simulation", str(bulk)]
    if args.basecalling:
        command += ["--basecalling", "--basecall-simplex-model", args.model, "--fastq"]
    subprocess.run(command, check=True)


def status():
    c = position().connect()
    import grpc
    result = {"endpoint": "localhost:9501", "position": "MS00000", "simulated": True}
    for key, call in (("protocol", c.protocol.get_current_protocol_run),
                      ("acquisition", c.acquisition.get_current_acquisition_run)):
        try:
            value = call()
            from google.protobuf.json_format import MessageToDict
            result[key] = MessageToDict(value._message)
        except grpc.RpcError as error:
            if error.code() != grpc.StatusCode.FAILED_PRECONDITION:
                raise
            result[key] = {"status": error.code().name, "details": error.details()}
    print(json.dumps(result, indent=2))


def stop():
    pid = owned_pid()
    if not pid:
        print("Already stopped; output and logs retained.")
        return
    # Stop acquisition before shutting down Dorado and the manager.
    with socket.socket() as probe:
        listening = probe.connect_ex(("127.0.0.1", 9501)) == 0
    if listening:
        import grpc
        c = position().connect()
        try:
            c.protocol.stop_protocol(_timeout=5)
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                try:
                    if c.protocol.get_current_protocol_run(_timeout=2).end_time.seconds:
                        break
                except grpc.RpcError as error:
                    if error.code() == grpc.StatusCode.FAILED_PRECONDITION:
                        break
                    raise
                time.sleep(0.5)
            else:
                raise RuntimeError("Protocol is still finishing; manager left running. Retry stop after basecalling and output finish.")
        except grpc.RpcError as error:
            if error.code() != grpc.StatusCode.FAILED_PRECONDITION:
                raise
    subprocess.run([str(INSTALL / "bin/mk_manager_svc"), "--close", str(pid)], check=True)
    deadline = time.monotonic() + 30
    while owned_pid() and time.monotonic() < deadline:
        time.sleep(0.5)
    if owned_pid():
        raise RuntimeError("Manager is still shutting down; no processes were forcibly terminated. See the playback logs.")
    print("Stopped; output and logs retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "start", "status", "stop", "stop-run", "tui"):
        sub.add_parser(name)
    replay = sub.add_parser("run")
    replay.add_argument("--bulk", default="/srv/nanopore-data/r10_5khz.fast5")
    replay.add_argument("--minutes", type=float, default=15)
    replay.add_argument("--kit", default="SQK-LSK114")
    replay.add_argument("--product", default="FLO-MIN114")
    replay.add_argument("--basecalling", action="store_true")
    replay.add_argument("--model", default="dna_r10.4.1_e8.2_400bps_fast@v5.2.0")
    args = parser.parse_args()
    if args.command == "run":
        if args.minutes <= 0:
            parser.error("--minutes must be positive")
        run(args)
    elif args.command == "stop":
        stop()
    elif args.command == "stop-run":
        position().connect().protocol.stop_protocol()
    elif args.command == "tui":
        manager()
        os.execv(str(PROJECT / "bin/minknow-tui"), ["minknow-tui", "--host", "localhost", "--port", "9501"])
    else:
        globals()[args.command]()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
