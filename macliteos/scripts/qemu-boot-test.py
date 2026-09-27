#!/usr/bin/env python3
"""Run a QEMU boot and require a serial readiness token with active progress."""

import argparse
import json
import os
import pathlib
import shlex
import socket
import subprocess
import sys
import tempfile
import time

FAILURE_MARKERS = (
    "Kernel panic - not syncing",
    "Kernel BUG at",
    "Oops:",
    "No working init found",
    "Failed to execute /init",
    "G1OS_BOOT: fatal",
    "start request repeated too quickly",
    "respawning too fast",
    "segfault at",
    "[FAIL]",
)


class QMP:
    def __init__(self, path, process):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(15)
        deadline = time.monotonic() + 15
        while True:
            try:
                self.socket.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("QEMU QMP monitor did not become available")
                time.sleep(0.1)
        self.stream = self.socket.makefile("rwb", buffering=0)
        self._read_reply()
        self.command("qmp_capabilities")

    def _read_reply(self):
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError("QEMU QMP monitor closed unexpectedly")
            value = json.loads(line)
            if "QMP" in value:
                return value["QMP"]
            if "return" in value:
                return value["return"]
            if "error" in value:
                raise RuntimeError(f"QEMU QMP error: {value['error']}")

    def command(self, name, arguments=None):
        command = {"execute": name}
        if arguments is not None:
            command["arguments"] = arguments
        self.stream.write((json.dumps(command) + "\r\n").encode())
        return self._read_reply()

    def key(self, name):
        self.command(
            "human-monitor-command",
            {"command-line": f"sendkey {name}"},
        )

    def close(self):
        self.stream.close()
        self.socket.close()


def connect_serial(path, process):
    serial = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    deadline = time.monotonic() + 15
    while True:
        try:
            serial.connect(path)
            serial.settimeout(0.2)
            return serial
        except (FileNotFoundError, ConnectionRefusedError):
            if process.poll() is not None or time.monotonic() >= deadline:
                serial.close()
                raise RuntimeError("QEMU serial socket did not become available")
            time.sleep(0.05)


def missing_ordered_stages(text, stages):
    offset = 0
    missing = []
    for stage in stages:
        found = text.find(stage, offset)
        if found < 0:
            missing.append(stage)
        else:
            offset = found + len(stage)
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial-log", required=True)
    parser.add_argument("--qemu-log", required=True)
    parser.add_argument("--command-log", required=True)
    parser.add_argument("--ready-token", required=True)
    parser.add_argument("--require-stage", action="append", default=[])
    parser.add_argument("--menu-steps", type=int, default=0)
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--stall-timeout", type=int, default=60)
    parser.add_argument("--shutdown-on-ready", action="store_true")
    parser.add_argument("qemu", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.qemu[1:] if args.qemu and args.qemu[0] == "--" else args.qemu
    if not command:
        parser.error("provide the QEMU command after --")
    if args.menu_steps < 0 or args.timeout <= 0 or args.stall_timeout <= 0:
        parser.error("timeouts must be positive and menu steps cannot be negative")

    serial_path = pathlib.Path(args.serial_log).resolve()
    qemu_path = pathlib.Path(args.qemu_log).resolve()
    command_path = pathlib.Path(args.command_log).resolve()
    for output in (serial_path, qemu_path, command_path):
        output.parent.mkdir(parents=True, exist_ok=True)
    serial_path.unlink(missing_ok=True)
    qemu_path.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="g1os-qmp-") as temporary:
        qmp_path = os.path.join(temporary, "monitor.sock")
        serial_socket_path = os.path.join(temporary, "serial.sock")
        full_command = command + [
            "-chardev", f"socket,id=g1os_serial,path={serial_socket_path},server=on,wait=on",
            "-serial", "chardev:g1os_serial",
            "-monitor", "none",
            "-qmp", f"unix:{qmp_path},server=on,wait=off",
        ]
        command_path.write_text(shlex.join(full_command) + "\n", encoding="utf-8")
        print(f"QEMU command: {shlex.join(full_command)}", flush=True)
        print(f"Serial log: {serial_path}", flush=True)
        print(f"QEMU log: {qemu_path}", flush=True)

        with qemu_path.open("wb") as qemu_log, serial_path.open("wb") as serial_log:
            process = subprocess.Popen(full_command, stdout=qemu_log, stderr=subprocess.STDOUT)
            try:
                serial_socket = connect_serial(serial_socket_path, process)
                qmp = QMP(qmp_path, process)
            except Exception as error:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                print(f"ERROR: {error}", file=sys.stderr)
                return 1

            started = time.monotonic()
            last_progress = started
            serial_text = ""
            serial_pending = ""
            last_stage = "none"
            menu_selected = args.menu_steps == 0
            error_message = None

            try:
                while process.poll() is None:
                    now = time.monotonic()
                    try:
                        chunk_bytes = serial_socket.recv(65536)
                    except socket.timeout:
                        chunk_bytes = b""
                    if chunk_bytes:
                        serial_log.write(chunk_bytes)
                        serial_log.flush()
                        chunk = chunk_bytes.decode("utf-8", errors="replace")
                        serial_text += chunk
                        serial_pending += chunk
                        if chunk.strip():
                            last_progress = now
                        lines = serial_pending.splitlines(keepends=True)
                        serial_pending = ""
                        if lines and not lines[-1].endswith(("\n", "\r")):
                            serial_pending = lines.pop()
                        for line in lines:
                            if "G1OS_BOOT:" in line:
                                last_stage = line.split("G1OS_BOOT:", 1)[1].strip()
                                print(f"Boot progress: {last_stage}", flush=True)
                        for marker in FAILURE_MARKERS:
                            if marker.lower() in serial_text.lower():
                                error_message = f"guest reported failure marker: {marker}"
                                break

                    if error_message:
                        break

                    if not menu_selected and "G1OS (Safe Graphics - Default" in serial_text:
                        for _ in range(args.menu_steps):
                            qmp.key("down")
                            time.sleep(0.15)
                        qmp.key("ret")
                        menu_selected = True
                        print(f"Selected GRUB entry offset {args.menu_steps}", flush=True)

                    if args.ready_token in serial_text:
                        missing = missing_ordered_stages(serial_text, args.require_stage)
                        if missing:
                            error_message = "readiness reached without required stages: " + ", ".join(missing)
                            break
                        print(f"Readiness token reached: {args.ready_token}", flush=True)
                        if args.shutdown_on_ready:
                            qmp.command("quit")
                            break

                    if now - started > args.timeout:
                        error_message = f"overall timeout after {args.timeout}s; last boot stage: {last_stage}"
                        break
                    if now - last_progress > args.stall_timeout:
                        error_message = f"no serial progress for {args.stall_timeout}s; last boot stage: {last_stage}"
                        break
                    time.sleep(0.2)

                if process.poll() is None:
                    process.terminate()
                try:
                    return_code = process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    return_code = process.wait()
            finally:
                qmp.close()
                serial_socket.close()

    serial_text = serial_path.read_text(encoding="utf-8", errors="replace")
    missing = missing_ordered_stages(serial_text, args.require_stage)
    if error_message:
        print(f"ERROR: {error_message}", file=sys.stderr)
    if not menu_selected:
        print("ERROR: GRUB menu was not detected; requested graphics mode was not selected", file=sys.stderr)
        error_message = error_message or "GRUB menu selection failed"
    if args.ready_token not in serial_text:
        print(f"ERROR: readiness token not reached: {args.ready_token}; last stage: {last_stage}", file=sys.stderr)
        error_message = error_message or "readiness token missing"
    if missing:
        print("ERROR: missing required boot stages: " + ", ".join(missing), file=sys.stderr)
        error_message = error_message or "required boot stage missing"
    if return_code != 0:
        print(f"ERROR: QEMU exited with status {return_code}", file=sys.stderr)
        error_message = error_message or "QEMU exited unsuccessfully"
    if error_message:
        try:
            tail = serial_path.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]
            print("---- serial log tail ----", file=sys.stderr)
            print("\n".join(tail), file=sys.stderr)
            print("---- QEMU log tail ----", file=sys.stderr)
            print("\n".join(qemu_path.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]), file=sys.stderr)
        except OSError:
            pass
        return 1
    print(f"PASS: QEMU reached {args.ready_token} and exited cleanly (last stage: {last_stage})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
