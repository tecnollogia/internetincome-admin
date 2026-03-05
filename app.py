from __future__ import annotations

import json
import os
import re
import shlex
import socket
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, render_template, request

BASE_DIR = Path(__file__).resolve().parent
PROPERTIES_PATH = BASE_DIR / "properties.conf"
PROXIES_PATH = BASE_DIR / "proxies.txt"
LINKS_PATH = BASE_DIR / "earnapp-links.txt"
CONTAINERS_PATH = BASE_DIR / "containernames.txt"
SCRIPT_PATH = BASE_DIR / "internetIncome.sh"
MONITOR_STATE_PATH = BASE_DIR / "monitor-state.json"

CONFIG_KEYS = [
    "DEVICE_NAME",
    "EARNAPP",
    "EARNAPP_IMAGE",
    "TUN_IMAGE",
    "SOCKS5_DNS_IMAGE",
    "USE_PROXIES",
    "USE_SOCKS5_DNS",
    "EARNAPP_CPUS",
    "EARNAPP_MEMORY",
    "TUN_CPUS",
    "TUN_MEMORY",
    "PIDS_LIMIT",
    "EARNAPP_PLATFORM",
    "TUN_PLATFORM",
    "ENABLE_LOGS",
    "TUN_LOG_LEVEL",
    "AUTO_HEAL",
    "AUTO_RESTART_COOLDOWN_SEC",
    "MONITOR_INTERVAL_SEC",
    "PROXY_CHECK_INTERVAL_SEC",
    "CHECK_PROXY_BEFORE_START",
    "DELAY_BETWEEN_TUN_AND_EARNAPP_SEC",
    "START_DELAY_SEC",
    "MAX_STACKS",
    "ENABLE_HOST_GUARD",
    "AUTO_REBOOT_ON_CRITICAL",
    "HOST_ACTION_COOLDOWN_SEC",
    "CPU_CRITICAL_PERCENT",
    "MEM_CRITICAL_PERCENT",
    "DISK_CRITICAL_PERCENT",
    "LOAD_CRITICAL_PER_CPU",
    "CRITICAL_STREAK_THRESHOLD",
]

BOOL_KEYS = {
    "EARNAPP",
    "USE_PROXIES",
    "USE_SOCKS5_DNS",
    "ENABLE_LOGS",
    "AUTO_HEAL",
    "CHECK_PROXY_BEFORE_START",
    "ENABLE_HOST_GUARD",
    "AUTO_REBOOT_ON_CRITICAL",
}

DEFAULT_CONFIG = {
    "DEVICE_NAME": "pi-node",
    "EARNAPP": True,
    "EARNAPP_IMAGE": "fazalfarhan01/earnapp:lite",
    "TUN_IMAGE": "xjasonlyu/tun2socks:v2.6.0",
    "SOCKS5_DNS_IMAGE": "ghcr.io/heiher/hev-socks5-tunnel:latest",
    "USE_PROXIES": True,
    "USE_SOCKS5_DNS": True,
    "EARNAPP_CPUS": "0.35",
    "EARNAPP_MEMORY": "192m",
    "TUN_CPUS": "0.20",
    "TUN_MEMORY": "96m",
    "PIDS_LIMIT": "120",
    "EARNAPP_PLATFORM": "",
    "TUN_PLATFORM": "",
    "ENABLE_LOGS": False,
    "TUN_LOG_LEVEL": "warn",
    "AUTO_HEAL": True,
    "AUTO_RESTART_COOLDOWN_SEC": "120",
    "MONITOR_INTERVAL_SEC": "10",
    "PROXY_CHECK_INTERVAL_SEC": "45",
    "CHECK_PROXY_BEFORE_START": True,
    "DELAY_BETWEEN_TUN_AND_EARNAPP_SEC": "5",
    "START_DELAY_SEC": "4",
    "MAX_STACKS": "",
    "ENABLE_HOST_GUARD": True,
    "AUTO_REBOOT_ON_CRITICAL": False,
    "HOST_ACTION_COOLDOWN_SEC": "600",
    "CPU_CRITICAL_PERCENT": "95",
    "MEM_CRITICAL_PERCENT": "95",
    "DISK_CRITICAL_PERCENT": "95",
    "LOAD_CRITICAL_PER_CPU": "1.6",
    "CRITICAL_STREAK_THRESHOLD": "3",
}

app = Flask(__name__)
command_lock = threading.Lock()
recent_commands: deque[dict[str, Any]] = deque(maxlen=30)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def shell_escape_single(value: str) -> str:
    return value.replace("'", "'\"'\"'")


def parse_bool(value: str) -> bool:
    return value.strip().lower() == "true"


def normalize_value(key: str, value: Any):
    if key in BOOL_KEYS:
        if isinstance(value, bool):
            return value
        return parse_bool(str(value))
    return "" if value is None else str(value)


def parse_proxy_line(line: str) -> dict[str, str] | None:
    raw = line.strip()
    if not raw or raw.startswith("#"):
        return None

    if "://" in raw:
        m = re.match(r"^(?P<scheme>https?|socks[45])://(?:(?P<user>[^:@]+):(?P<pwd>[^@]+)@)?(?P<host>[^:]+):(?P<port>\d+)$", raw)
        if not m:
            return None
        d = m.groupdict()
        scheme = d["scheme"]
        user = d.get("user") or ""
        pwd = d.get("pwd") or ""
        host = d["host"]
        port = d["port"]
    else:
        parts = raw.split(":")
        if len(parts) != 4:
            return None
        host, port, user, pwd = parts
        scheme = "http"

    auth = f"{user}:{pwd}@" if user else ""
    url = f"{scheme}://{auth}{host}:{port}"
    return {
        "raw": raw,
        "scheme": scheme,
        "host": host,
        "port": str(port),
        "user": user,
        "password": pwd,
        "url": url,
    }


def read_properties() -> dict[str, Any]:
    data = DEFAULT_CONFIG.copy()
    if not PROPERTIES_PATH.exists():
        return data

    for line in PROPERTIES_PATH.read_text(encoding="utf-8", errors="ignore").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, raw_val = stripped.split("=", 1)
        key = key.strip()
        if key not in data:
            continue
        value = raw_val.strip()
        if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
            value = value[1:-1]
        data[key] = normalize_value(key, value)

    return data


def write_properties(data: dict[str, Any]) -> None:
    cleaned = {k: normalize_value(k, data.get(k, DEFAULT_CONFIG[k])) for k in CONFIG_KEYS}
    lines = ["######################### EarnApp-Only Configuration #########################", ""]

    lines.extend(
        [
            "# Device label used as prefix in containers",
            f"DEVICE_NAME='{shell_escape_single(cleaned['DEVICE_NAME'])}'",
            "",
            "# EarnApp and Docker images",
            "# Leave defaults unless you need a custom tag",
            f"EARNAPP={'true' if cleaned['EARNAPP'] else 'false'}",
            f"EARNAPP_IMAGE='{shell_escape_single(cleaned['EARNAPP_IMAGE'])}'",
            f"TUN_IMAGE='{shell_escape_single(cleaned['TUN_IMAGE'])}'",
            f"SOCKS5_DNS_IMAGE='{shell_escape_single(cleaned['SOCKS5_DNS_IMAGE'])}'",
            "",
            "# Proxy mode",
            "# true  -> one EarnApp + one tun2socks per proxy listed in proxies.txt",
            "# false -> single EarnApp using direct internet",
            f"USE_PROXIES={'true' if cleaned['USE_PROXIES'] else 'false'}",
            f"USE_SOCKS5_DNS={'true' if cleaned['USE_SOCKS5_DNS'] else 'false'}",
            "",
            "# Performance tuning for Raspberry Pi / low-end PCs",
            "# Leave empty to disable each limit",
            f"EARNAPP_CPUS='{shell_escape_single(cleaned['EARNAPP_CPUS'])}'",
            f"EARNAPP_MEMORY='{shell_escape_single(cleaned['EARNAPP_MEMORY'])}'",
            f"TUN_CPUS='{shell_escape_single(cleaned['TUN_CPUS'])}'",
            f"TUN_MEMORY='{shell_escape_single(cleaned['TUN_MEMORY'])}'",
            f"PIDS_LIMIT='{shell_escape_single(cleaned['PIDS_LIMIT'])}'",
            "",
            "# Optional platform override (keep empty for auto)",
            "# Example: 'linux/amd64' or 'linux/arm64'",
            f"EARNAPP_PLATFORM='{shell_escape_single(cleaned['EARNAPP_PLATFORM'])}'",
            f"TUN_PLATFORM='{shell_escape_single(cleaned['TUN_PLATFORM'])}'",
            "",
            "# Logging",
            "# false is recommended for lower CPU and disk usage",
            f"ENABLE_LOGS={'true' if cleaned['ENABLE_LOGS'] else 'false'}",
            "",
            "# TUN log level when logs are enabled: debug|info|warn|error|silent",
            f"TUN_LOG_LEVEL='{shell_escape_single(cleaned['TUN_LOG_LEVEL'])}'",
            "",
            "# Reliability and automation",
            f"AUTO_HEAL={'true' if cleaned['AUTO_HEAL'] else 'false'}",
            f"AUTO_RESTART_COOLDOWN_SEC='{shell_escape_single(cleaned['AUTO_RESTART_COOLDOWN_SEC'])}'",
            f"MONITOR_INTERVAL_SEC='{shell_escape_single(cleaned['MONITOR_INTERVAL_SEC'])}'",
            f"PROXY_CHECK_INTERVAL_SEC='{shell_escape_single(cleaned['PROXY_CHECK_INTERVAL_SEC'])}'",
            f"CHECK_PROXY_BEFORE_START={'true' if cleaned['CHECK_PROXY_BEFORE_START'] else 'false'}",
            f"DELAY_BETWEEN_TUN_AND_EARNAPP_SEC='{shell_escape_single(cleaned['DELAY_BETWEEN_TUN_AND_EARNAPP_SEC'])}'",
            f"START_DELAY_SEC='{shell_escape_single(cleaned['START_DELAY_SEC'])}'",
            f"MAX_STACKS='{shell_escape_single(cleaned['MAX_STACKS'])}'",
            f"ENABLE_HOST_GUARD={'true' if cleaned['ENABLE_HOST_GUARD'] else 'false'}",
            f"AUTO_REBOOT_ON_CRITICAL={'true' if cleaned['AUTO_REBOOT_ON_CRITICAL'] else 'false'}",
            f"HOST_ACTION_COOLDOWN_SEC='{shell_escape_single(cleaned['HOST_ACTION_COOLDOWN_SEC'])}'",
            f"CPU_CRITICAL_PERCENT='{shell_escape_single(cleaned['CPU_CRITICAL_PERCENT'])}'",
            f"MEM_CRITICAL_PERCENT='{shell_escape_single(cleaned['MEM_CRITICAL_PERCENT'])}'",
            f"DISK_CRITICAL_PERCENT='{shell_escape_single(cleaned['DISK_CRITICAL_PERCENT'])}'",
            f"LOAD_CRITICAL_PER_CPU='{shell_escape_single(cleaned['LOAD_CRITICAL_PER_CPU'])}'",
            f"CRITICAL_STREAK_THRESHOLD='{shell_escape_single(cleaned['CRITICAL_STREAK_THRESHOLD'])}'",
            "",
            "######################### End Configuration ##################################",
            "",
        ]
    )

    PROPERTIES_PATH.write_text("\n".join(lines), encoding="utf-8")


def read_proxy_objects() -> list[dict[str, str]]:
    if not PROXIES_PATH.exists():
        return []
    out: list[dict[str, str]] = []
    for line in PROXIES_PATH.read_text(encoding="utf-8", errors="ignore").splitlines():
        parsed = parse_proxy_line(line)
        if parsed:
            out.append(parsed)
    return out


def write_proxies(raw_proxies: list[str]) -> None:
    out = []
    for line in raw_proxies:
        p = parse_proxy_line(str(line))
        if p:
            out.append(p["url"])
    body = "\n".join(out)
    if body:
        body += "\n"
    PROXIES_PATH.write_text(body, encoding="utf-8")


def read_links() -> list[str]:
    if not LINKS_PATH.exists():
        return []
    return [line.strip() for line in LINKS_PATH.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()]


def list_known_containers() -> list[str]:
    if not CONTAINERS_PATH.exists():
        return []
    return [line.strip() for line in CONTAINERS_PATH.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()]


def run_cmd(cmd: list[str], timeout: int = 8) -> tuple[int, str, str]:
    try:
        result = subprocess.run(cmd, cwd=BASE_DIR, text=True, capture_output=True, timeout=timeout, check=False)
        return result.returncode, result.stdout, result.stderr
    except Exception as exc:
        return 1, "", str(exc)


def get_container_status(names: list[str]) -> dict[str, Any]:
    if not names:
        return {"running": [], "stopped": [], "missing": []}

    rc, out, err = run_cmd(["docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}"], timeout=8)
    if rc != 0:
        return {"running": [], "stopped": [], "missing": names, "error": err.strip()}

    all_status = {}
    for row in out.splitlines():
        if "|" not in row:
            continue
        name, status = row.split("|", 1)
        all_status[name.strip()] = status.strip()

    running, stopped, missing = [], [], []
    for name in names:
        status = all_status.get(name)
        if not status:
            missing.append(name)
        elif status.lower().startswith("up"):
            running.append({"name": name, "status": status})
        else:
            stopped.append({"name": name, "status": status})

    return {"running": running, "stopped": stopped, "missing": missing}


def get_host_metrics() -> dict[str, Any]:
    cpu = 0.0
    mem_pct = 0.0
    uptime = ""

    rc, out, _ = run_cmd(["sh", "-c", "LANG=C top -bn1 | grep 'Cpu(s)' | head -n1"], timeout=4)
    if rc == 0 and out:
        m = re.search(r"([0-9]+\.[0-9]+) id", out)
        if m:
            cpu = max(0.0, 100.0 - float(m.group(1)))

    rc, out, _ = run_cmd(["sh", "-c", "free -m | awk '/Mem:/ {print $3,$2}'"], timeout=4)
    if rc == 0 and out.strip():
        used, total = out.strip().split()
        total_f = float(total)
        if total_f > 0:
            mem_pct = (float(used) / total_f) * 100

    rc, out, _ = run_cmd(["uptime", "-p"], timeout=4)
    if rc == 0:
        uptime = out.strip()

    disk_pct = 0.0
    rc, out, _ = run_cmd(["sh", "-c", "df -P / | awk 'NR==2 {gsub(\"%\",\"\",$5); print $5}'"], timeout=4)
    if rc == 0 and out.strip():
        try:
            disk_pct = float(out.strip())
        except ValueError:
            disk_pct = 0.0

    load1 = 0.0
    rc, out, _ = run_cmd(["sh", "-c", "cat /proc/loadavg | awk '{print $1}'"], timeout=4)
    if rc == 0 and out.strip():
        try:
            load1 = float(out.strip())
        except ValueError:
            load1 = 0.0

    cpu_count = os.cpu_count() or 1

    return {
        "cpu_percent": round(cpu, 2),
        "mem_percent": round(mem_pct, 2),
        "disk_percent": round(disk_pct, 2),
        "load1": round(load1, 2),
        "cpu_count": cpu_count,
        "uptime": uptime,
    }


def get_container_usage(names: list[str]) -> list[dict[str, Any]]:
    if not names:
        return []

    rc, out, _ = run_cmd(["docker", "stats", "--no-stream", "--format", "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}"], timeout=8)
    if rc != 0:
        return []

    index = {n: True for n in names}
    usage = []
    for row in out.splitlines():
        parts = row.split("|")
        if len(parts) != 4:
            continue
        name = parts[0].strip()
        if name not in index:
            continue
        usage.append(
            {
                "name": name,
                "cpu": parts[1].strip(),
                "mem_usage": parts[2].strip(),
                "mem_percent": parts[3].strip(),
            }
        )
    return usage


def get_container_env_map(names: list[str], keys: set[str]) -> dict[str, dict[str, str]]:
    if not names or not keys:
        return {}

    rc, out, _ = run_cmd(["docker", "inspect", "--format", "{{.Name}}|{{json .Config.Env}}", *names], timeout=20)
    if rc != 0:
        return {}

    env_map: dict[str, dict[str, str]] = {}
    for row in out.splitlines():
        if "|" not in row:
            continue
        raw_name, raw_env = row.split("|", 1)
        name = raw_name.strip().lstrip("/")
        try:
            env_list = json.loads(raw_env.strip())
        except Exception:
            continue
        if not isinstance(env_list, list):
            continue

        picked: dict[str, str] = {}
        for item in env_list:
            if not isinstance(item, str) or "=" not in item:
                continue
            k, v = item.split("=", 1)
            if k in keys:
                picked[k] = v
        env_map[name] = picked
    return env_map


def build_earnapp_stack_rows(known: list[str], monitor_state: dict[str, Any], links: list[str]) -> list[dict[str, Any]]:
    status_by_name: dict[str, str] = {}
    for item in monitor_state.get("containers", {}).get("running", []):
        status_by_name[item.get("name", "")] = item.get("status", "running")
    for item in monitor_state.get("containers", {}).get("stopped", []):
        status_by_name[item.get("name", "")] = item.get("status", "stopped")
    for name in monitor_state.get("containers", {}).get("missing", []):
        status_by_name[name] = "missing"

    env_map = get_container_env_map(known, {"EARNAPP_UUID", "PROXY"})

    links_by_uuid: dict[str, str] = {}
    for link in links:
        m = re.search(r"/r/([^/\s]+)$", link)
        if m:
            links_by_uuid[m.group(1)] = link

    stacks: dict[tuple[str, int], dict[str, Any]] = {}
    for name in known:
        m = re.match(r"^(earnapp|tun)([a-f0-9]+)_(\d+)$", name)
        if not m:
            continue
        kind, session, idx_raw = m.groups()
        idx = int(idx_raw)
        key = (session, idx)
        row = stacks.setdefault(
            key,
            {
                "session": session,
                "index": idx,
                "earnapp_container": "",
                "earnapp_status": "",
                "tun_container": "",
                "tun_status": "",
                "proxy": "",
                "earnapp_uuid": "",
                "earnapp_link": "",
            },
        )
        if kind == "earnapp":
            row["earnapp_container"] = name
            row["earnapp_status"] = status_by_name.get(name, "unknown")
            uuid = env_map.get(name, {}).get("EARNAPP_UUID", "")
            if uuid:
                row["earnapp_uuid"] = uuid
                row["earnapp_link"] = links_by_uuid.get(uuid, f"https://earnapp.com/r/{uuid}")
        else:
            row["tun_container"] = name
            row["tun_status"] = status_by_name.get(name, "unknown")
            row["proxy"] = env_map.get(name, {}).get("PROXY", "")

    rows = list(stacks.values())
    rows.sort(key=lambda r: (r["session"], r["index"]))
    return rows


@dataclass
class ProxyRuntime:
    key: str
    offline_since: float | None = None
    total_offline_sec: int = 0
    last_seen_online: float | None = None
    checks: int = 0
    fails: int = 0


class MonitorService:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.state: dict[str, Any] = {
            "last_cycle": None,
            "host": {},
            "proxies": [],
            "containers": {"running": [], "stopped": [], "missing": []},
            "usage": [],
            "events": [],
        }
        self.proxy_runtime: dict[str, ProxyRuntime] = {}
        self.last_restart: dict[str, float] = {}
        self.last_guard_actions: dict[str, float] = {}
        self.guard_level = 0
        self.critical_streak = 0
        self.last_critical_reasons: list[str] = []
        self.last_proxy_check = 0.0
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.run_loop, daemon=True)
        self.load_state()

    def start(self) -> None:
        self.thread.start()

    def load_state(self) -> None:
        if not MONITOR_STATE_PATH.exists():
            return
        try:
            raw = json.loads(MONITOR_STATE_PATH.read_text(encoding="utf-8"))
            for item in raw.get("proxy_runtime", []):
                key = item.get("key")
                if not key:
                    continue
                self.proxy_runtime[key] = ProxyRuntime(
                    key=key,
                    offline_since=item.get("offline_since"),
                    total_offline_sec=int(item.get("total_offline_sec", 0)),
                    last_seen_online=item.get("last_seen_online"),
                    checks=int(item.get("checks", 0)),
                    fails=int(item.get("fails", 0)),
                )
        except Exception:
            pass

    def persist_state(self) -> None:
        payload = {
            "proxy_runtime": [
                {
                    "key": p.key,
                    "offline_since": p.offline_since,
                    "total_offline_sec": p.total_offline_sec,
                    "last_seen_online": p.last_seen_online,
                    "checks": p.checks,
                    "fails": p.fails,
                }
                for p in self.proxy_runtime.values()
            ]
        }
        MONITOR_STATE_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def event(self, msg: str) -> None:
        with self.lock:
            events = self.state.setdefault("events", [])
            events.insert(0, f"{now_iso()} | {msg}")
            self.state["events"] = events[:100]

    def _to_int(self, value: Any, default: int) -> int:
        try:
            return int(str(value))
        except Exception:
            return default

    def _to_float(self, value: Any, default: float) -> float:
        try:
            return float(str(value))
        except Exception:
            return default

    def evaluate_host_critical(self, cfg: dict[str, Any], host: dict[str, Any]) -> tuple[bool, list[str]]:
        reasons: list[str] = []
        cpu_limit = self._to_float(cfg.get("CPU_CRITICAL_PERCENT", "95"), 95.0)
        mem_limit = self._to_float(cfg.get("MEM_CRITICAL_PERCENT", "95"), 95.0)
        disk_limit = self._to_float(cfg.get("DISK_CRITICAL_PERCENT", "95"), 95.0)
        load_per_cpu = self._to_float(cfg.get("LOAD_CRITICAL_PER_CPU", "1.6"), 1.6)

        cpu = float(host.get("cpu_percent", 0.0) or 0.0)
        mem = float(host.get("mem_percent", 0.0) or 0.0)
        disk = float(host.get("disk_percent", 0.0) or 0.0)
        load1 = float(host.get("load1", 0.0) or 0.0)
        cpu_count = int(host.get("cpu_count", 1) or 1)
        load_limit = max(0.5, load_per_cpu * max(1, cpu_count))

        if cpu >= cpu_limit:
            reasons.append(f"cpu={cpu:.1f}%>={cpu_limit:.1f}%")
        if mem >= mem_limit:
            reasons.append(f"mem={mem:.1f}%>={mem_limit:.1f}%")
        if disk >= disk_limit:
            reasons.append(f"disk={disk:.1f}%>={disk_limit:.1f}%")
        if load1 >= load_limit:
            reasons.append(f"load1={load1:.2f}>={load_limit:.2f}")

        return (len(reasons) > 0), reasons

    def _run_host_action(self, action: str, cmd: list[str], timeout: int = 900) -> bool:
        rc, out, err = run_cmd(cmd, timeout=timeout)
        ok = rc == 0
        details = out.strip() if ok else err.strip()
        self.event(f"host-guard {action} {'ok' if ok else 'fail'} | {details or 'no output'}")
        if ok:
            self.last_guard_actions[action] = time.time()
        return ok

    def _can_run_action(self, action: str, cooldown: int) -> bool:
        now = time.time()
        last = self.last_guard_actions.get(action, 0.0)
        return (now - last) >= cooldown

    def host_guard_escalation(self, cfg: dict[str, Any], critical: bool) -> None:
        if not cfg.get("ENABLE_HOST_GUARD", True):
            self.guard_level = 0
            return

        if not critical:
            self.guard_level = 0
            return

        streak_threshold = self._to_int(cfg.get("CRITICAL_STREAK_THRESHOLD", "3"), 3)
        cooldown = self._to_int(cfg.get("HOST_ACTION_COOLDOWN_SEC", "600"), 600)
        auto_reboot = bool(cfg.get("AUTO_REBOOT_ON_CRITICAL", False))

        if self.critical_streak < max(1, streak_threshold):
            return

        # Level 1: recycle stack (delete + start) if no user command is currently running.
        if self.guard_level <= 0 and self._can_run_action("stack_recycle", cooldown):
            if command_lock.locked():
                self.event("host-guard skip stack_recycle: ui command lock is active")
            else:
                ok_delete = self._run_host_action("stack_delete", ["bash", str(SCRIPT_PATH), "--delete"], timeout=900)
                time.sleep(3)
                ok_start = self._run_host_action("stack_start", ["bash", str(SCRIPT_PATH), "--start"], timeout=1800)
                if ok_delete or ok_start:
                    self.last_guard_actions["stack_recycle"] = time.time()
                    self.guard_level = 1
                    return

        # Level 2: restart docker service.
        if self.guard_level <= 1 and self._can_run_action("docker_restart", cooldown):
            ok = self._run_host_action("docker_restart", ["sh", "-c", "sudo systemctl restart docker || systemctl restart docker"], timeout=180)
            if ok:
                self.guard_level = 2
                return

        # Level 3: host reboot (optional).
        if auto_reboot and self.guard_level <= 2 and self._can_run_action("host_reboot", cooldown):
            ok = self._run_host_action(
                "host_reboot",
                ["sh", "-c", "sudo shutdown -r +1 'internetincome host guard critical' || shutdown -r +1 'internetincome host guard critical'"],
                timeout=30,
            )
            if ok:
                self.guard_level = 3

    def check_proxy_online(self, host: str, port: str, timeout: float = 2.5) -> bool:
        try:
            with socket.create_connection((host, int(port)), timeout=timeout):
                return True
        except Exception:
            return False

    def restart_container(self, name: str) -> tuple[bool, str]:
        rc, out, err = run_cmd(["docker", "restart", name], timeout=20)
        if rc == 0:
            return True, out.strip() or name
        return False, err.strip() or f"restart failed for {name}"

    def auto_heal_containers(self, cfg: dict[str, Any], containers: dict[str, Any]) -> None:
        if not cfg.get("AUTO_HEAL", True):
            return

        try:
            cooldown = int(str(cfg.get("AUTO_RESTART_COOLDOWN_SEC", "120") or "120"))
        except ValueError:
            cooldown = 120

        now = time.time()
        for item in containers.get("stopped", []):
            name = item.get("name")
            if not name:
                continue
            last = self.last_restart.get(name, 0.0)
            if now - last < cooldown:
                continue
            ok, msg = self.restart_container(name)
            self.last_restart[name] = now
            self.event(f"auto-heal {'ok' if ok else 'fail'}: {name} | {msg}")

    def refresh_proxy_state(self, proxies: list[dict[str, str]], force: bool = False) -> list[dict[str, Any]]:
        now = time.time()
        cfg = read_properties()
        try:
            interval = int(str(cfg.get("PROXY_CHECK_INTERVAL_SEC", "45") or "45"))
        except ValueError:
            interval = 45

        should_check = force or (now - self.last_proxy_check >= max(10, interval))
        enriched: list[dict[str, Any]] = []

        for idx, px in enumerate(proxies, start=1):
            key = f"{px['host']}:{px['port']}:{idx}"
            rt = self.proxy_runtime.setdefault(key, ProxyRuntime(key=key))

            if should_check:
                online = self.check_proxy_online(px["host"], px["port"])
                rt.checks += 1
                if online:
                    rt.last_seen_online = now
                    if rt.offline_since is not None:
                        rt.total_offline_sec += int(now - rt.offline_since)
                        rt.offline_since = None
                else:
                    rt.fails += 1
                    if rt.offline_since is None:
                        rt.offline_since = now
            else:
                online = rt.offline_since is None

            offline_now = int(now - rt.offline_since) if rt.offline_since else 0
            fail_rate = (rt.fails / rt.checks * 100.0) if rt.checks else 0.0

            enriched.append(
                {
                    "index": idx,
                    "url": px["url"],
                    "host": px["host"],
                    "port": px["port"],
                    "online": online,
                    "checks": rt.checks,
                    "fail_rate_percent": round(fail_rate, 2),
                    "offline_for_sec": offline_now,
                    "total_offline_sec": rt.total_offline_sec + offline_now,
                    "last_seen_online": datetime.fromtimestamp(rt.last_seen_online).isoformat(timespec="seconds") if rt.last_seen_online else None,
                }
            )

        if should_check:
            self.last_proxy_check = now
            self.persist_state()

        return enriched

    def run_loop(self) -> None:
        while not self.stop_event.is_set():
            cfg = read_properties()
            known = list_known_containers()
            containers = get_container_status(known)
            self.auto_heal_containers(cfg, containers)

            proxies = read_proxy_objects()
            proxy_state = self.refresh_proxy_state(proxies)
            host = get_host_metrics()
            usage = get_container_usage(known)
            critical, reasons = self.evaluate_host_critical(cfg, host)
            self.last_critical_reasons = reasons
            if critical:
                self.critical_streak += 1
                self.event(f"host-guard critical streak={self.critical_streak} reasons={'; '.join(reasons)}")
            else:
                self.critical_streak = 0
            self.host_guard_escalation(cfg, critical)

            with self.lock:
                self.state.update(
                    {
                        "last_cycle": now_iso(),
                        "host": host,
                        "proxies": proxy_state,
                        "containers": containers,
                        "usage": usage,
                        "host_guard": {
                            "enabled": bool(cfg.get("ENABLE_HOST_GUARD", True)),
                            "auto_reboot_on_critical": bool(cfg.get("AUTO_REBOOT_ON_CRITICAL", False)),
                            "critical": critical,
                            "critical_streak": self.critical_streak,
                            "guard_level": self.guard_level,
                            "reasons": reasons,
                            "last_actions": self.last_guard_actions,
                        },
                    }
                )

            try:
                sleep_s = int(str(cfg.get("MONITOR_INTERVAL_SEC", "10") or "10"))
            except ValueError:
                sleep_s = 10
            time.sleep(max(3, sleep_s))

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return json.loads(json.dumps(self.state))


monitor = MonitorService()
monitor.start()


def execute_script(arg: str) -> dict[str, Any]:
    cmd = ["bash", str(SCRIPT_PATH), arg]
    started_at = now_iso()
    try:
        proc = subprocess.run(
            cmd,
            cwd=BASE_DIR,
            text=True,
            capture_output=True,
            timeout=1800,
            check=False,
        )
        payload = {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": proc.stdout[-12000:],
            "stderr": proc.stderr[-12000:],
            "started_at": started_at,
            "finished_at": now_iso(),
            "command": " ".join(shlex.quote(c) for c in cmd),
        }
    except subprocess.TimeoutExpired as exc:
        payload = {
            "ok": False,
            "returncode": 124,
            "stdout": (exc.stdout or "")[-12000:],
            "stderr": ((exc.stderr or "") + "\nCommand timed out.")[-12000:],
            "started_at": started_at,
            "finished_at": now_iso(),
            "command": " ".join(shlex.quote(c) for c in cmd),
        }

    recent_commands.appendleft(payload)
    monitor.event(f"command {arg}: {'ok' if payload['ok'] else 'fail'} (rc={payload['returncode']})")
    return payload


def build_state() -> dict[str, Any]:
    config = read_properties()
    proxies = read_proxy_objects()
    links = read_links()
    known = list_known_containers()
    monitor_state = monitor.snapshot()
    earnapp_stacks = build_earnapp_stack_rows(known, monitor_state, links)

    running = monitor_state.get("containers", {}).get("running", [])
    stopped = monitor_state.get("containers", {}).get("stopped", [])
    missing = monitor_state.get("containers", {}).get("missing", [])

    return {
        "time": now_iso(),
        "config": config,
        "proxies": [p["url"] for p in proxies],
        "links": links,
        "known_container_count": len(known),
        "proxy_count": len(proxies),
        "earnapp_stacks": earnapp_stacks,
        "busy": command_lock.locked(),
        "recent_commands": list(recent_commands),
        "monitor": monitor_state,
        "summary": {
            "running_containers": len(running),
            "stopped_containers": len(stopped),
            "missing_containers": len(missing),
            "online_proxies": len([p for p in monitor_state.get("proxies", []) if p.get("online")]),
            "offline_proxies": len([p for p in monitor_state.get("proxies", []) if not p.get("online")]),
        },
    }


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/state")
def api_state():
    return jsonify(build_state())


@app.post("/api/config")
def api_save_config():
    payload = request.get_json(silent=True) or {}
    incoming = payload.get("config")
    if not isinstance(incoming, dict):
        return jsonify({"ok": False, "error": "config payload missing"}), 400

    current = read_properties()
    for key in CONFIG_KEYS:
        if key in incoming:
            current[key] = normalize_value(key, incoming[key])

    write_properties(current)
    monitor.event("config updated from web UI")
    return jsonify({"ok": True, "config": read_properties()})


@app.post("/api/proxies")
def api_save_proxies():
    payload = request.get_json(silent=True) or {}
    proxies = payload.get("proxies")
    if not isinstance(proxies, list):
        text_block = payload.get("text", "")
        if isinstance(text_block, str):
            proxies = [line.strip() for line in text_block.splitlines() if line.strip()]
        else:
            return jsonify({"ok": False, "error": "proxies must be a list or text"}), 400

    write_proxies([str(item).strip() for item in proxies])
    monitor.event("proxy list updated from web UI")
    return jsonify({"ok": True, "count": len(read_proxy_objects())})


@app.post("/api/proxies/check")
def api_force_proxy_check():
    proxy_state = monitor.refresh_proxy_state(read_proxy_objects(), force=True)
    online = len([p for p in proxy_state if p.get("online")])
    offline = len(proxy_state) - online
    return jsonify({"ok": True, "online": online, "offline": offline})


@app.post("/api/action/<name>")
def api_action(name: str):
    actions = {
        "start": "--start",
        "stop": "--delete",
        "delete": "--delete",
        "cleanup": "--deleteBackup",
    }
    arg = actions.get(name)
    if not arg:
        return jsonify({"ok": False, "error": "unknown action"}), 404

    if command_lock.locked():
        return jsonify({"ok": False, "error": "another command is running"}), 409

    with command_lock:
        result = execute_script(arg)

    status = 200 if result["ok"] else 500
    return jsonify(result), status


if __name__ == "__main__":
    host = os.getenv("WEB_HOST", "0.0.0.0")
    port = int(os.getenv("WEB_PORT", "8080"))
    debug = os.getenv("WEB_DEBUG", "false").lower() == "true"
    app.run(host=host, port=port, debug=debug)
