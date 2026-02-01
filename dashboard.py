#!/usr/bin/env python3
"""
Talos Cluster Deployment Dashboard
A visual TUI for monitoring cluster deployment progress.

Setup:
  python3 -m venv .venv
  source .venv/bin/activate
  pip install -r requirements.txt

Usage:
  ./dashboard.py              # Live dashboard
  ./dashboard.py --once       # Single check
  ./dashboard.py --refresh 5  # Slower refresh
"""

import subprocess
import json
import time
import sys
import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Callable, List
import threading

try:
    from rich.console import Console
    from rich.table import Table
    from rich.live import Live
    from rich.panel import Panel
    from rich.layout import Layout
    from rich.text import Text
    from rich.style import Style
except ImportError:
    print("Installing rich library...")
    subprocess.run([sys.executable, "-m", "pip", "install", "rich", "-q"])
    from rich.console import Console
    from rich.table import Table
    from rich.live import Live
    from rich.panel import Panel
    from rich.layout import Layout
    from rich.text import Text
    from rich.style import Style

# Background color
BG_COLOR = "#D9D7B6"
BG_STYLE = Style(bgcolor=BG_COLOR)
TEXT_COLOR = "#000000"

# Spinner frames
SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
BLINK_FRAMES = ["◐", "◓", "◑", "◒"]

# BLINKENLIGHTS! More animations!
PULSE_FRAMES = ["○", "◔", "◑", "◕", "●", "◕", "◑", "◔"]
WAVE_FRAMES = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▂"]
RADAR_FRAMES = ["◜ ", " ◝", " ◞", "◟ "]
DOTS_FRAMES = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
CLOCK_FRAMES = ["🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛"]
BOUNCE_FRAMES = ["⠁", "⠂", "⠄", "⠂"]
ARROW_FRAMES = ["←", "↖", "↑", "↗", "→", "↘", "↓", "↙"]
METER_FRAMES = ["▰▱▱▱▱", "▰▰▱▱▱", "▰▰▰▱▱", "▰▰▰▰▱", "▰▰▰▰▰"]
HEART_FRAMES = ["💗", "💖", "💝", "💘"]
FIRE_FRAMES = ["🔥", "🔥", "💥", "✨"]
LIGHTNING_FRAMES = ["⚡", "✨", "⚡", "💫"]
NETWORK_FRAMES = ["◠", "◡", "◠", "◡"]
DISK_FRAMES = ["◴", "◷", "◶", "◵"]
SERVER_FRAMES = ["▣", "▤", "▥", "▦"]
EARTH_FRAMES = ["🌍", "🌎", "🌏", "🌎"]
ROCKET_FRAMES = ["🚀", "🚀", "💨", "🚀"]

# LED colors for blinkenlights panel
LED_COLORS = ["#FF3333", "#33FF33", "#3366FF", "#FFAA33", "#FF33FF", "#33FFFF", "#FFFF33", "#FF6633"]
LED_DIM = "#444444"

# Celebration ASCII art frames for deployment completion!
CELEBRATION_FRAMES = [
    r"""
    ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★
    ╔═══════════════════════════════════════╗
    ║   ██████╗██╗     ██╗   ██╗███████╗   ║
    ║  ██╔════╝██║     ██║   ██║██╔════╝   ║
    ║  ██║     ██║     ██║   ██║███████╗   ║
    ║  ██║     ██║     ██║   ██║╚════██║   ║
    ║  ╚██████╗███████╗╚██████╔╝███████║   ║
    ║   ╚═════╝╚══════╝ ╚═════╝ ╚══════╝   ║
    ║       T E R   R E A D Y ! ! !         ║
    ╚═══════════════════════════════════════╝
    ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆
    """,
    r"""
    ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆
    ╔═══════════════════════════════════════╗
    ║   ██████╗██╗     ██╗   ██╗███████╗   ║
    ║  ██╔════╝██║     ██║   ██║██╔════╝   ║
    ║  ██║     ██║     ██║   ██║███████╗   ║
    ║  ██║     ██║     ██║   ██║╚════██║   ║
    ║  ╚██████╗███████╗╚██████╔╝███████║   ║
    ║   ╚═════╝╚══════╝ ╚═════╝ ╚══════╝   ║
    ║       T E R   R E A D Y ! ! !         ║
    ╚═══════════════════════════════════════╝
    ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★
    """
]

# Fireworks frames
FIREWORK_FRAMES = [
    ["    ", "  * ", " \\|/", "  |  "],
    ["  * ", " *|* ", " /|\\ ", "  |  "],
    [" \\|/ ", " -*-*-", " /|\\|/\\", "  |  "],
    ["*-*-*", "*\\|/*", "-*-*-", " /|\\"]
]

# Activity symbols
ACTIVITY_ON = "●"
ACTIVITY_OFF = "○"

# Box drawing for retro look
BOX_CHARS = {
    "tl": "╔", "tr": "╗", "bl": "╚", "br": "╝",
    "h": "═", "v": "║", "cross": "╬"
}


class Status(Enum):
    PENDING = "pending"
    RUNNING = "running"
    WAITING = "waiting"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"


STATUS_ICONS = {
    Status.PENDING: ("○", "#666666"),
    Status.RUNNING: ("◉", "#CC8800 bold"),
    Status.WAITING: ("◎", "#0066AA bold"),
    Status.SUCCESS: ("●", "#008800 bold"),
    Status.FAILED: ("●", "#CC0000 bold"),
    Status.SKIPPED: ("○", "#666666"),
}

# Spinner frames for active items
SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
BLINK_FRAMES = ["◐", "◓", "◑", "◒"]

CHECKPOINT_STYLES = {
    Status.PENDING: ("□", "#666666"),
    Status.RUNNING: ("▣", "#CC8800"),
    Status.WAITING: ("◧", "#0066AA"),
    Status.SUCCESS: ("■", "#008800"),
    Status.FAILED: ("■", "#CC0000"),
}


@dataclass
class Checkpoint:
    name: str
    status: Status = Status.PENDING
    message: str = ""


@dataclass
class Step:
    name: str
    description: str
    status: Status = Status.PENDING
    message: str = ""
    checkpoints: List[Checkpoint] = field(default_factory=list)
    check_fn: Optional[Callable] = None


class ClusterDashboard:
    def __init__(self, workdir: str = ".", blinkenlicht: bool = False):
        self.console = Console()
        self.workdir = workdir
        self.blinkenlicht = blinkenlicht
        self.kubeconfig = self._find_kubeconfig()
        self.talosconfig = os.path.join(workdir, "talosconfig.yml")
        self.test_results_file = os.path.join(workdir, ".test-results.json")
        self.steps: List[Step] = []
        self.test_results: dict = {}
        self.lock = threading.Lock()
        self.frame = 0  # Animation frame counter
        self.start_time = time.time()  # Track uptime
        self.completion_frame = None  # When did we complete?
        self._init_steps()

    def _find_kubeconfig(self) -> str:
        candidates = [
            os.path.join(self.workdir, "kubeconfig.yml"),
            os.path.join(self.workdir, "kubeconfig.raw.yml"),
            os.path.join(self.workdir, "kubeconfig"),
            os.environ.get("KUBECONFIG", ""),
        ]
        for path in candidates:
            if path and os.path.isfile(path):
                return path
        return os.path.join(self.workdir, "kubeconfig.yml")

    def _init_steps(self):
        self.steps = [
            Step("tfplan", "TF Plan",
                 check_fn=self._check_tf_plan,
                 checkpoints=[Checkpoint("init"), Checkpoint("plan"), Checkpoint("file")]),
            Step("tfapply", "TF Apply",
                 check_fn=self._check_tf_apply,
                 checkpoints=[Checkpoint("state"), Checkpoint("ctrl"), Checkpoint("work")]),
            Step("vms", "VMs",
                 check_fn=self._check_vms,
                 checkpoints=[Checkpoint("ctrl1"), Checkpoint("ctrl2"), Checkpoint("wk1"), Checkpoint("wk2"), Checkpoint("wk3"), Checkpoint("wk4")]),
            Step("talos_cfg", "Talos Cfg",
                 check_fn=self._check_talos_config,
                 checkpoints=[Checkpoint("secrets"), Checkpoint("talosconf"), Checkpoint("kubeconf")]),
            Step("talos_boot", "Talos Boot",
                 check_fn=self._check_talos_bootstrap,
                 checkpoints=[Checkpoint("etcd"), Checkpoint("api"), Checkpoint("sched"), Checkpoint("cm")]),
            Step("nodes", "Nodes",
                 check_fn=self._check_nodes,
                 checkpoints=[Checkpoint("c1"), Checkpoint("c2"), Checkpoint("w1"), Checkpoint("w2"), Checkpoint("w3"), Checkpoint("w4")]),
            Step("cilium", "Cilium",
                 check_fn=self._check_cilium,
                 checkpoints=[Checkpoint("oper"), Checkpoint("ag1"), Checkpoint("ag2"), Checkpoint("ag3"), Checkpoint("ag4"), Checkpoint("ag5"), Checkpoint("ag6")]),
            Step("piraeus", "Piraeus Op",
                 check_fn=self._check_piraeus_operator,
                 checkpoints=[Checkpoint("CRDs"), Checkpoint("oper"), Checkpoint("csi-c"), Checkpoint("csi-n")]),
            Step("linstor", "LINSTOR",
                 check_fn=self._check_linstor_controller,
                 checkpoints=[Checkpoint("ctrl"), Checkpoint("api"), Checkpoint("db")]),
            Step("satellites", "Satellites",
                 check_fn=self._check_linstor_satellites,
                 checkpoints=[Checkpoint("sat1"), Checkpoint("sat2"), Checkpoint("sat3"), Checkpoint("sat4"), Checkpoint("lvm")]),
            Step("storage", "Storage",
                 check_fn=self._check_storage_pools,
                 checkpoints=[Checkpoint("p1"), Checkpoint("p2"), Checkpoint("p3"), Checkpoint("p4"), Checkpoint("cap")]),
            Step("sc", "StorClass",
                 check_fn=self._check_storageclass,
                 checkpoints=[Checkpoint("sc"), Checkpoint("ext4"), Checkpoint("csi")]),
            Step("traefik", "Traefik",
                 check_fn=self._check_traefik,
                 checkpoints=[Checkpoint("dep"), Checkpoint("LB"), Checkpoint("rdy")]),
            Step("certmgr", "CertMgr",
                 check_fn=self._check_certmanager,
                 checkpoints=[Checkpoint("ctl"), Checkpoint("hook"), Checkpoint("inj"), Checkpoint("issu")]),
            Step("monitoring", "Monitor",
                 check_fn=self._check_monitoring,
                 checkpoints=[Checkpoint("prom"), Checkpoint("graf"), Checkpoint("alert"), Checkpoint("node"), Checkpoint("kube")]),
            Step("harbor", "Harbor",
                 check_fn=self._check_harbor,
                 checkpoints=[Checkpoint("pvc"), Checkpoint("db"), Checkpoint("red"), Checkpoint("core"), Checkpoint("reg"), Checkpoint("job"), Checkpoint("tri")]),
            Step("gitea", "Gitea",
                 check_fn=self._check_gitea,
                 checkpoints=[Checkpoint("pvc"), Checkpoint("db"), Checkpoint("app"), Checkpoint("ing")]),
            Step("ingress", "Ingress",
                 check_fn=self._check_ingress,
                 checkpoints=[Checkpoint("cert"), Checkpoint("issuer"), Checkpoint("ing")]),
        ]

    def _kubectl(self, args: List[str], timeout: int = 10) -> tuple:
        try:
            env = os.environ.copy()
            env["KUBECONFIG"] = self.kubeconfig
            result = subprocess.run(["kubectl"] + args, capture_output=True, text=True, timeout=timeout, env=env)
            return result.returncode == 0, result.stdout + result.stderr
        except Exception as e:
            return False, str(e)

    def _linstor(self, args: List[str]) -> tuple:
        return self._kubectl(["-n", "piraeus-datastore", "exec", "deploy/linstor-controller", "--", "linstor"] + args, timeout=30)

    def _check_tf_plan(self) -> tuple:
        """Check terraform init and plan status"""
        step = self._get_step("tfplan")
        checkpoints = step.checkpoints
        
        # Check .terraform directory (init done)
        tf_dir = os.path.join(self.workdir, ".terraform")
        if os.path.isdir(tf_dir):
            checkpoints[0].status = Status.SUCCESS
        
        # Check lock file
        lock_file = os.path.join(self.workdir, ".terraform.lock.hcl")
        if os.path.isfile(lock_file):
            checkpoints[1].status = Status.SUCCESS
        
        # Check plan file
        plan_file = os.path.join(self.workdir, "tfplan")
        if os.path.isfile(plan_file):
            checkpoints[2].status = Status.SUCCESS
            return Status.SUCCESS, "Plan ready"
        
        if checkpoints[0].status == Status.SUCCESS:
            return Status.WAITING, "Planning..."
        return Status.PENDING, "Not init"
    
    def _check_tf_apply(self) -> tuple:
        """Check terraform apply progress"""
        step = self._get_step("tfapply")
        checkpoints = step.checkpoints
        
        tfstate = os.path.join(self.workdir, "terraform.tfstate")
        if not os.path.isfile(tfstate):
            return Status.PENDING, "No state"
        
        checkpoints[0].status = Status.SUCCESS
        
        try:
            with open(tfstate) as f:
                state = json.load(f)
                resources = state.get("resources", [])
                
                # Check for controller VMs
                ctrl_vms = [r for r in resources if "proxmox" in r.get("type", "") and "controller" in r.get("name", "")]
                if ctrl_vms:
                    checkpoints[1].status = Status.SUCCESS
                    checkpoints[1].message = str(len(ctrl_vms))
                
                # Check for worker VMs
                worker_vms = [r for r in resources if "proxmox" in r.get("type", "") and "worker" in r.get("name", "")]
                if worker_vms:
                    checkpoints[2].status = Status.SUCCESS
                    checkpoints[2].message = str(len(worker_vms))
                
                total_vms = len(ctrl_vms) + len(worker_vms)
                if total_vms >= 6:
                    return Status.SUCCESS, f"{total_vms} VMs"
                elif total_vms > 0:
                    return Status.WAITING, f"{total_vms} VMs"
                return Status.WAITING, f"{len(resources)} res"
        except:
            return Status.WAITING, "Parsing"

    def _check_vms(self) -> tuple:
        """Check individual VM status"""
        step = self._get_step("vms")
        checkpoints = step.checkpoints
        
        tfstate = os.path.join(self.workdir, "terraform.tfstate")
        if not os.path.isfile(tfstate):
            return Status.PENDING, "No state"
        
        try:
            with open(tfstate) as f:
                state = json.load(f)
                resources = state.get("resources", [])
                
                vm_names = []
                for r in resources:
                    if "proxmox_virtual_environment_vm" in r.get("type", ""):
                        for inst in r.get("instances", []):
                            name = inst.get("attributes", {}).get("name", "")
                            status = inst.get("attributes", {}).get("started", False)
                            vm_names.append((name, status))
                
                # Map to checkpoints
                cp_map = {
                    "ctrl1": ["ctrl-1", "ctrl1", "controller-1", "cp-1"],
                    "ctrl2": ["ctrl-2", "ctrl2", "controller-2", "cp-2"],
                    "wk1": ["work-1", "worker-1", "wk-1", "wk1"],
                    "wk2": ["work-2", "worker-2", "wk-2", "wk2"],
                    "wk3": ["work-3", "worker-3", "wk-3", "wk3"],
                    "wk4": ["work-4", "worker-4", "wk-4", "wk4"],
                }
                
                running = 0
                for i, cp in enumerate(checkpoints):
                    for vm_name, started in vm_names:
                        for pattern in cp_map.get(cp.name, []):
                            if pattern in vm_name.lower():
                                if started:
                                    cp.status = Status.SUCCESS
                                    running += 1
                                else:
                                    cp.status = Status.WAITING
                                break
                
                if running >= 6:
                    return Status.SUCCESS, f"{running} running"
                elif running > 0:
                    return Status.WAITING, f"{running}/6"
                return Status.WAITING, "Creating"
        except:
            return Status.WAITING, "Parsing"

    def _check_talos_config(self) -> tuple:
        """Check Talos configuration files"""
        step = self._get_step("talos_cfg")
        checkpoints = step.checkpoints
        
        # Machine secrets
        secrets_file = os.path.join(self.workdir, "secrets.yaml")
        if os.path.isfile(secrets_file):
            checkpoints[0].status = Status.SUCCESS
        
        # Talosconfig
        if os.path.isfile(self.talosconfig):
            checkpoints[1].status = Status.SUCCESS
        
        # Kubeconfig
        if os.path.isfile(self.kubeconfig):
            checkpoints[2].status = Status.SUCCESS
            return Status.SUCCESS, "Configured"
        
        if checkpoints[1].status == Status.SUCCESS:
            return Status.WAITING, "Kubeconfig..."
        if checkpoints[0].status == Status.SUCCESS:
            return Status.WAITING, "Talosconf..."
        return Status.PENDING, "No config"

    def _check_talos_bootstrap(self) -> tuple:
        """Check Talos bootstrap and control plane components"""
        step = self._get_step("talos_boot")
        checkpoints = step.checkpoints
        
        if not os.path.isfile(self.kubeconfig):
            return Status.PENDING, "No kubeconfig"
        
        # Check control plane pods
        success, output = self._kubectl(["get", "pods", "-n", "kube-system", "-o", "json"])
        if not success:
            return Status.WAITING, "Connecting..."
        
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            
            components = {
                "etcd": checkpoints[0],
                "kube-apiserver": checkpoints[1],
                "kube-scheduler": checkpoints[2],
                "kube-controller": checkpoints[3],
            }
            
            for pod in pods:
                name = pod.get("metadata", {}).get("name", "")
                phase = pod.get("status", {}).get("phase", "")
                for comp, cp in components.items():
                    if comp in name:
                        if phase == "Running":
                            cp.status = Status.SUCCESS
                        else:
                            cp.status = Status.WAITING
            
            ready = sum(1 for cp in checkpoints if cp.status == Status.SUCCESS)
            if ready == 4:
                return Status.SUCCESS, "Control plane up"
            return Status.WAITING, f"{ready}/4 comps"
        except:
            return Status.WAITING, "Parsing"

    def _check_nodes(self) -> tuple:
        """Check individual node status"""
        step = self._get_step("nodes")
        checkpoints = step.checkpoints
        
        success, output = self._kubectl(["get", "nodes", "-o", "json"])
        if not success:
            return Status.WAITING, "Connecting..."
        
        try:
            data = json.loads(output)
            nodes = data.get("items", [])
            
            cp_map = {
                "c1": ["ctrl-1", "ctrl1", "controller-1", "cp-1"],
                "c2": ["ctrl-2", "ctrl2", "controller-2", "cp-2"],
                "w1": ["work-1", "worker-1", "wk-1", "wk1"],
                "w2": ["work-2", "worker-2", "wk-2", "wk2"],
                "w3": ["work-3", "worker-3", "wk-3", "wk3"],
                "w4": ["work-4", "worker-4", "wk-4", "wk4"],
            }
            
            ready_count = 0
            for node in nodes:
                name = node.get("metadata", {}).get("name", "")
                conditions = node.get("status", {}).get("conditions", [])
                is_ready = any(c["type"] == "Ready" and c["status"] == "True" for c in conditions)
                
                for i, cp in enumerate(checkpoints):
                    for pattern in cp_map.get(cp.name, []):
                        if pattern in name.lower():
                            if is_ready:
                                cp.status = Status.SUCCESS
                                ready_count += 1
                            else:
                                cp.status = Status.WAITING
                            break
            
            total = len(nodes)
            if ready_count >= 6:
                return Status.SUCCESS, f"{ready_count} ready"
            return Status.WAITING, f"{ready_count}/{total}"
        except:
            return Status.WAITING, "Parsing"

    def _get_step(self, name: str) -> Step:
        for s in self.steps:
            if s.name == name:
                return s
        return self.steps[0]

    def _check_terraform(self) -> tuple:
        checkpoints = self.steps[0].checkpoints
        tfstate = os.path.join(self.workdir, "terraform.tfstate")
        if not os.path.isfile(tfstate):
            return Status.PENDING, "No state"
        checkpoints[0].status = Status.SUCCESS
        try:
            with open(tfstate) as f:
                state = json.load(f)
                resources = state.get("resources", [])
                vms = [r for r in resources if "proxmox" in r.get("type", "")]
                if vms:
                    checkpoints[1].status = Status.SUCCESS
                    checkpoints[1].message = str(len(vms))
                if len(resources) > 5:
                    checkpoints[2].status = Status.SUCCESS
                return Status.SUCCESS, f"{len(resources)} res"
        except:
            return Status.WAITING, "Parsing"

    def _check_talos_health(self) -> tuple:
        checkpoints = self.steps[1].checkpoints
        if os.path.isfile(self.talosconfig):
            checkpoints[0].status = Status.SUCCESS
        if not os.path.isfile(self.kubeconfig):
            return Status.WAITING, "No kubeconfig"
        checkpoints[1].status = Status.SUCCESS
        success, output = self._kubectl(["get", "nodes", "-o", "json"])
        if not success:
            return Status.WAITING, "Connecting..."
        try:
            data = json.loads(output)
            nodes = data.get("items", [])
            ready = sum(1 for n in nodes if any(c["type"] == "Ready" and c["status"] == "True" for c in n.get("status", {}).get("conditions", [])))
            total = len(nodes)
            if total > 0:
                checkpoints[2].status = Status.SUCCESS if ready == total else Status.WAITING
                checkpoints[2].message = f"{ready}/{total}"
            if ready == total and total > 0:
                return Status.SUCCESS, f"{ready}/{total} nodes"
            return Status.WAITING, f"{ready}/{total} nodes"
        except:
            return Status.WAITING, "Parsing"

    def _check_cilium(self) -> tuple:
        step = self._get_step("cilium")
        checkpoints = step.checkpoints
        success, output = self._kubectl(["get", "pods", "-n", "kube-system", "-l", "app.kubernetes.io/name=cilium", "-o", "json"])
        if not success:
            return Status.WAITING, "Checking"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            
            # Find operator
            operators = [p for p in pods if "operator" in p.get("metadata", {}).get("name", "")]
            agents = [p for p in pods if "cilium-" in p.get("metadata", {}).get("name", "") and "operator" not in p.get("metadata", {}).get("name", "") and "envoy" not in p.get("metadata", {}).get("name", "")]
            
            def is_running(p): return p.get("status", {}).get("phase") == "Running"
            
            # Operator
            if operators and is_running(operators[0]):
                checkpoints[0].status = Status.SUCCESS
            elif operators:
                checkpoints[0].status = Status.WAITING
            
            # Individual agents (ag1-ag6)
            for i, agent in enumerate(agents[:6]):
                if i + 1 < len(checkpoints):
                    if is_running(agent):
                        checkpoints[i + 1].status = Status.SUCCESS
                    else:
                        checkpoints[i + 1].status = Status.WAITING
            
            running = sum(1 for p in pods if is_running(p))
            if running == len(pods) and len(pods) > 0:
                return Status.SUCCESS, f"{len(pods)} pods"
            return Status.WAITING, f"{running}/{len(pods)}"
        except:
            return Status.FAILED, "Error"

    def _check_piraeus_operator(self) -> tuple:
        step = self._get_step("piraeus")
        checkpoints = step.checkpoints
        
        success, output = self._kubectl(["get", "crd", "-o", "name"])
        if success and "linstor" in output.lower():
            checkpoints[0].status = Status.SUCCESS
        
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-l", "app.kubernetes.io/name=piraeus-operator", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
            if running > 0:
                checkpoints[1].status = Status.SUCCESS
        except:
            pass
        
        # CSI controller
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-l", "app.kubernetes.io/component=linstor-csi-controller", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                pods = data.get("items", [])
                running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
                if running > 0:
                    checkpoints[2].status = Status.SUCCESS
                elif pods:
                    checkpoints[2].status = Status.WAITING
            except:
                pass
        
        # CSI node pods
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-l", "app.kubernetes.io/component=linstor-csi-node", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                pods = data.get("items", [])
                running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
                checkpoints[3].message = f"{running}"
                if running == len(pods) and running > 0:
                    checkpoints[3].status = Status.SUCCESS
                elif running > 0:
                    checkpoints[3].status = Status.WAITING
            except:
                pass
        
        done = sum(1 for cp in checkpoints if cp.status == Status.SUCCESS)
        if done == len(checkpoints):
            return Status.SUCCESS, "Ready"
        return Status.WAITING, f"{done}/{len(checkpoints)}"

    def _check_linstor_controller(self) -> tuple:
        step = self._get_step("linstor")
        checkpoints = step.checkpoints
        
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-l", "app.kubernetes.io/component=linstor-controller", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            for p in pods:
                phase = p.get("status", {}).get("phase")
                containers = p.get("status", {}).get("containerStatuses", [])
                
                if phase == "Running":
                    checkpoints[0].status = Status.SUCCESS
                
                # Check individual containers
                for cs in containers:
                    name = cs.get("name", "")
                    ready = cs.get("ready", False)
                    if "linstor" in name and ready:
                        checkpoints[1].status = Status.SUCCESS
                    if "drbd" in name.lower() or "db" in name.lower():
                        if ready:
                            checkpoints[2].status = Status.SUCCESS
                        else:
                            checkpoints[2].status = Status.WAITING
                
                all_ready = all(cs.get("ready", False) for cs in containers)
                if phase == "Running" and all_ready:
                    return Status.SUCCESS, "Ready"
            return Status.WAITING, "Starting"
        except:
            return Status.FAILED, "Error"

    def _check_linstor_satellites(self) -> tuple:
        step = self._get_step("satellites")
        checkpoints = step.checkpoints
        
        # Check satellite pods
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-l", "app.kubernetes.io/component=linstor-satellite", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                pods = data.get("items", [])
                
                for i, pod in enumerate(pods[:4]):
                    phase = pod.get("status", {}).get("phase")
                    if phase == "Running":
                        checkpoints[i].status = Status.SUCCESS
                    else:
                        checkpoints[i].status = Status.WAITING
            except:
                pass
        
        # Check LVM init
        success, output = self._kubectl(["get", "ds", "-n", "piraeus-datastore", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                for ds in data.get("items", []):
                    name = ds.get("metadata", {}).get("name", "")
                    if "lvm" in name.lower():
                        ready = ds.get("status", {}).get("numberReady", 0)
                        desired = ds.get("status", {}).get("desiredNumberScheduled", 0)
                        if ready == desired and ready > 0:
                            checkpoints[4].status = Status.SUCCESS
                            checkpoints[4].message = f"{ready}"
                        elif ready > 0:
                            checkpoints[4].status = Status.WAITING
                            checkpoints[4].message = f"{ready}/{desired}"
            except:
                pass
        
        # Check LINSTOR node status
        success, output = self._linstor(["node", "list"])
        if not success:
            return Status.WAITING, "Ctrl not ready"
        
        online = output.count("Online")
        if online > 0:
            return Status.SUCCESS, f"{online} online"
        return Status.WAITING, "No nodes"

    def _check_storage_pools(self) -> tuple:
        step = self._get_step("storage")
        checkpoints = step.checkpoints
        
        success, output = self._linstor(["storage-pool", "list"])
        if not success:
            return Status.WAITING, "Checking"
        
        lines = output.split("\n")
        pool_count = 0
        total_gib = 0
        
        for i, line in enumerate(lines):
            if "LVM_THIN" in line:
                pool_count += 1
                # Mark individual pool checkpoints
                if pool_count <= 4:
                    checkpoints[pool_count - 1].status = Status.SUCCESS
                
                # Try to extract capacity
                if "GiB" in line:
                    try:
                        parts = line.split()
                        for j, p in enumerate(parts):
                            if "GiB" in p and j > 0:
                                total_gib += float(parts[j-1].replace(",", "."))
                    except:
                        pass
        
        if total_gib > 0:
            checkpoints[4].status = Status.SUCCESS
            checkpoints[4].message = f"{int(total_gib)}G"
        
        if pool_count > 0:
            return Status.SUCCESS, f"{pool_count} pools"
        return Status.WAITING, "No pools"

    def _check_storageclass(self) -> tuple:
        step = self._get_step("sc")
        checkpoints = step.checkpoints
        
        success, output = self._kubectl(["get", "sc", "linstor-lvm-r1", "-o", "json"])
        if not success:
            return Status.PENDING, "Not created"
        
        checkpoints[0].status = Status.SUCCESS
        
        try:
            data = json.loads(output)
            params = data.get("parameters", {})
            provisioner = data.get("provisioner", "")
            
            if "csi.storage.k8s.io/fstype" in params:
                checkpoints[1].status = Status.SUCCESS
                checkpoints[1].message = params.get("csi.storage.k8s.io/fstype")
            else:
                checkpoints[1].status = Status.FAILED
                return Status.FAILED, "No fstype!"
            
            if "linstor" in provisioner:
                checkpoints[2].status = Status.SUCCESS
            
            return Status.SUCCESS, "Ready"
        except:
            return Status.FAILED, "Error"

    def _check_traefik(self) -> tuple:
        step = self._get_step("traefik")
        checkpoints = step.checkpoints
        
        success, output = self._kubectl(["get", "pods", "-n", "traefik", "-l", "app.kubernetes.io/name=traefik", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            if not pods:
                return Status.PENDING, "Not installed"
            
            checkpoints[0].status = Status.SUCCESS
            running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
            ready = sum(1 for p in pods if all(cs.get("ready", False) for cs in p.get("status", {}).get("containerStatuses", [])))
            
            svc_success, svc_output = self._kubectl(["get", "svc", "-n", "traefik", "traefik", "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}"])
            if svc_success and svc_output:
                checkpoints[1].status = Status.SUCCESS
                checkpoints[1].message = svc_output[:10]
            
            if ready == len(pods) and ready > 0:
                checkpoints[2].status = Status.SUCCESS
                return Status.SUCCESS, f"{ready} ready"
            return Status.WAITING, f"{running}/{len(pods)}"
        except:
            return Status.FAILED, "Error"

    def _check_harbor(self) -> tuple:
        step = self._get_step("harbor")
        checkpoints = step.checkpoints
        
        # PVCs
        pvc_success, pvc_output = self._kubectl(["get", "pvc", "-n", "harbor", "-o", "json"])
        if pvc_success:
            try:
                pvc_data = json.loads(pvc_output)
                pvcs = pvc_data.get("items", [])
                bound = sum(1 for p in pvcs if p.get("status", {}).get("phase") == "Bound")
                if pvcs:
                    checkpoints[0].status = Status.SUCCESS if bound == len(pvcs) else Status.WAITING
                    checkpoints[0].message = f"{bound}/{len(pvcs)}"
            except:
                pass
        
        success, output = self._kubectl(["get", "pods", "-n", "harbor", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            if not pods:
                return Status.PENDING, "Not installed"
            
            def is_ready(pod):
                return pod.get("status", {}).get("phase") == "Running" and all(cs.get("ready", False) for cs in pod.get("status", {}).get("containerStatuses", []))
            
            components = {
                "database": checkpoints[1],
                "redis": checkpoints[2],
                "core": checkpoints[3],
                "registry": checkpoints[4],
                "jobservice": checkpoints[5],
                "trivy": checkpoints[6],
            }
            
            for pod in pods:
                name = pod.get("metadata", {}).get("name", "")
                for comp, cp in components.items():
                    if comp in name:
                        if is_ready(pod):
                            cp.status = Status.SUCCESS
                        elif "CrashLoopBackOff" in str(pod.get("status", {})):
                            cp.status = Status.FAILED
                        elif pod.get("status", {}).get("phase") == "Running":
                            cp.status = Status.WAITING
                        elif pod.get("status", {}).get("phase") == "Pending":
                            cp.status = Status.WAITING
            
            running = sum(1 for p in pods if is_ready(p))
            failed = sum(1 for p in pods if "CrashLoopBackOff" in str(p.get("status", {})))
            
            if running == len(pods):
                return Status.SUCCESS, f"All {len(pods)} ready"
            elif failed > 0:
                return Status.FAILED, f"{running}/{len(pods)}"
            return Status.WAITING, f"{running}/{len(pods)}"
        except:
            return Status.FAILED, "Error"

    def _check_certmanager(self) -> tuple:
        """Check cert-manager components"""
        step = self._get_step("certmgr")
        checkpoints = step.checkpoints
        
        success, output = self._kubectl(["get", "pods", "-n", "cert-manager", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            if not pods:
                return Status.PENDING, "Not installed"
            
            def is_ready(pod):
                return pod.get("status", {}).get("phase") == "Running" and all(cs.get("ready", False) for cs in pod.get("status", {}).get("containerStatuses", []))
            
            components = {
                "cert-manager-controller": checkpoints[0],  # ctl
                "cert-manager-webhook": checkpoints[1],      # hook
                "cert-manager-cainjector": checkpoints[2],   # inj
            }
            
            for pod in pods:
                name = pod.get("metadata", {}).get("name", "")
                for comp, cp in components.items():
                    if comp in name:
                        if is_ready(pod):
                            cp.status = Status.SUCCESS
                        else:
                            cp.status = Status.WAITING
            
            # Check ClusterIssuer
            issuer_success, issuer_output = self._kubectl(["get", "clusterissuer", "-o", "json"])
            if issuer_success:
                try:
                    issuer_data = json.loads(issuer_output)
                    issuers = issuer_data.get("items", [])
                    ready = sum(1 for iss in issuers if any(c.get("type") == "Ready" and c.get("status") == "True" for c in iss.get("status", {}).get("conditions", [])))
                    if ready > 0:
                        checkpoints[3].status = Status.SUCCESS
                        checkpoints[3].message = f"{ready}"
                except:
                    pass
            
            running = sum(1 for p in pods if is_ready(p))
            if running == len(pods) and checkpoints[3].status == Status.SUCCESS:
                return Status.SUCCESS, f"{running} pods"
            return Status.WAITING, f"{running}/{len(pods)}"
        except:
            return Status.FAILED, "Error"

    def _check_monitoring(self) -> tuple:
        """Check Prometheus/Grafana monitoring stack"""
        step = self._get_step("monitoring")
        checkpoints = step.checkpoints
        
        # Try common monitoring namespaces
        namespaces = ["monitoring", "prometheus", "observability", "kube-prometheus-stack"]
        ns_found = None
        
        for ns in namespaces:
            success, output = self._kubectl(["get", "pods", "-n", ns, "-o", "json"])
            if success:
                try:
                    data = json.loads(output)
                    if data.get("items"):
                        ns_found = ns
                        break
                except:
                    pass
        
        if not ns_found:
            return Status.PENDING, "Not installed"
        
        success, output = self._kubectl(["get", "pods", "-n", ns_found, "-o", "json"])
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            
            def is_ready(pod):
                return pod.get("status", {}).get("phase") == "Running" and all(cs.get("ready", False) for cs in pod.get("status", {}).get("containerStatuses", []))
            
            components = {
                "prometheus": checkpoints[0],    # prom
                "grafana": checkpoints[1],       # graf
                "alertmanager": checkpoints[2],  # alert
                "node-exporter": checkpoints[3], # node
                "kube-state": checkpoints[4],    # kube
            }
            
            for pod in pods:
                name = pod.get("metadata", {}).get("name", "").lower()
                for comp, cp in components.items():
                    if comp in name:
                        if is_ready(pod):
                            cp.status = Status.SUCCESS
                        elif pod.get("status", {}).get("phase") == "Running":
                            cp.status = Status.WAITING
                        elif pod.get("status", {}).get("phase") == "Pending":
                            cp.status = Status.WAITING
            
            running = sum(1 for p in pods if is_ready(p))
            total = len(pods)
            
            if running == total and total > 0:
                return Status.SUCCESS, f"All {total} ready"
            return Status.WAITING, f"{running}/{total}"
        except:
            return Status.FAILED, "Error"

    def _check_gitea(self) -> tuple:
        """Check Gitea git server"""
        step = self._get_step("gitea")
        checkpoints = step.checkpoints
        
        # Check PVCs
        pvc_success, pvc_output = self._kubectl(["get", "pvc", "-n", "gitea", "-o", "json"])
        if pvc_success:
            try:
                pvc_data = json.loads(pvc_output)
                pvcs = pvc_data.get("items", [])
                bound = sum(1 for p in pvcs if p.get("status", {}).get("phase") == "Bound")
                if pvcs:
                    checkpoints[0].status = Status.SUCCESS if bound == len(pvcs) else Status.WAITING
                    checkpoints[0].message = f"{bound}/{len(pvcs)}"
            except:
                pass
        
        success, output = self._kubectl(["get", "pods", "-n", "gitea", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            if not pods:
                return Status.PENDING, "Not installed"
            
            def is_ready(pod):
                return pod.get("status", {}).get("phase") == "Running" and all(cs.get("ready", False) for cs in pod.get("status", {}).get("containerStatuses", []))
            
            for pod in pods:
                name = pod.get("metadata", {}).get("name", "").lower()
                if "postgresql" in name or "postgres" in name:
                    if is_ready(pod):
                        checkpoints[1].status = Status.SUCCESS
                    else:
                        checkpoints[1].status = Status.WAITING
                elif "gitea" in name and "postgresql" not in name:
                    if is_ready(pod):
                        checkpoints[2].status = Status.SUCCESS
                    else:
                        checkpoints[2].status = Status.WAITING
            
            # Check ingress
            ing_success, ing_output = self._kubectl(["get", "ingress", "-n", "gitea", "-o", "json"])
            if ing_success:
                try:
                    ing_data = json.loads(ing_output)
                    ingresses = ing_data.get("items", [])
                    if ingresses:
                        checkpoints[3].status = Status.SUCCESS
                except:
                    pass
            
            running = sum(1 for p in pods if is_ready(p))
            total = len(pods)
            
            if running == total and total > 0:
                return Status.SUCCESS, f"All {total} ready"
            return Status.WAITING, f"{running}/{total}"
        except:
            return Status.FAILED, "Error"

    def _check_ingress(self) -> tuple:
        """Check ingress and cert-manager"""
        step = self._get_step("ingress")
        checkpoints = step.checkpoints
        
        # Check cert-manager
        success, output = self._kubectl(["get", "pods", "-n", "cert-manager", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                pods = data.get("items", [])
                running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
                if running > 0:
                    checkpoints[0].status = Status.SUCCESS
                    checkpoints[0].message = f"{running}"
            except:
                pass
        
        # Check ClusterIssuer
        success, output = self._kubectl(["get", "clusterissuer", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                issuers = data.get("items", [])
                ready = 0
                for iss in issuers:
                    conditions = iss.get("status", {}).get("conditions", [])
                    if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions):
                        ready += 1
                if ready > 0:
                    checkpoints[1].status = Status.SUCCESS
                    checkpoints[1].message = f"{ready}"
            except:
                pass
        
        # Check ingresses
        success, output = self._kubectl(["get", "ingress", "-A", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                ingresses = data.get("items", [])
                if len(ingresses) > 0:
                    checkpoints[2].status = Status.SUCCESS
                    checkpoints[2].message = f"{len(ingresses)}"
            except:
                pass
        
        done = sum(1 for cp in checkpoints if cp.status == Status.SUCCESS)
        if done == len(checkpoints):
            return Status.SUCCESS, "Ready"
        elif done > 0:
            return Status.WAITING, f"{done}/3"
        return Status.PENDING, "Checking"

    def _load_test_results(self) -> dict:
        """Load test results from JSON file"""
        if not os.path.isfile(self.test_results_file):
            return {}
        try:
            with open(self.test_results_file) as f:
                return json.load(f)
        except:
            return {}

    def _get_pvcs(self) -> List[dict]:
        success, output = self._kubectl(["get", "pvc", "-n", "harbor", "-o", "json"])
        if not success:
            return []
        try:
            data = json.loads(output)
            return [{"name": i.get("metadata", {}).get("name", "?"), "status": i.get("status", {}).get("phase", "?"), "size": i.get("status", {}).get("capacity", {}).get("storage", "-")} for i in data.get("items", [])]
        except:
            return []

    def render_checkpoints_row(self, checkpoints: List[Checkpoint]) -> Text:
        text = Text()
        for i, cp in enumerate(checkpoints):
            if i > 0:
                text.append(" ")
            if cp.status == Status.WAITING:
                # Animated spinner for waiting checkpoints - use different animations!
                anim_type = i % 3
                if anim_type == 0:
                    icon = BLINK_FRAMES[(self.frame + i) % len(BLINK_FRAMES)]
                elif anim_type == 1:
                    icon = PULSE_FRAMES[(self.frame + i) % len(PULSE_FRAMES)]
                else:
                    icon = RADAR_FRAMES[(self.frame + i) % len(RADAR_FRAMES)]
                text.append(icon, style="#0066AA bold")
            elif cp.status == Status.SUCCESS:
                # Subtle pulse for completed items
                phase = (self.frame + i * 3) % 8
                brightness = "33FF33" if phase < 4 else "22DD22"
                text.append("■", style=f"#{brightness}")
            else:
                icon, style = CHECKPOINT_STYLES.get(cp.status, ("○", "#666666"))
                text.append(icon, style=style)
        return text

    def render_step_icon(self, step: Step) -> Text:
        """Render step icon with animation for waiting states"""
        if step.status == Status.WAITING:
            # Use different spinners based on step index
            idx = self.steps.index(step) if step in self.steps else 0
            anim_type = idx % 4
            if anim_type == 0:
                icon = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
            elif anim_type == 1:
                icon = DOTS_FRAMES[self.frame % len(DOTS_FRAMES)]
            elif anim_type == 2:
                icon = RADAR_FRAMES[self.frame % len(RADAR_FRAMES)]
            else:
                icon = BOUNCE_FRAMES[self.frame % len(BOUNCE_FRAMES)]
            return Text(icon, style="#0066AA bold")
        elif step.status == Status.SUCCESS:
            # Subtle celebration animation
            if self.frame % 20 < 2:
                return Text("★", style="#FFD700 bold")
            return Text("●", style="#33FF33 bold")
        elif step.status == Status.FAILED:
            # Alarming blink
            if self.frame % 4 < 2:
                return Text("●", style="#FF0000 bold")
            else:
                return Text("○", style="#880000")
        icon, style = STATUS_ICONS[step.status]
        return Text(icon, style=style)

    def render_step_table(self) -> Table:
        table = Table(show_header=True, header_style="bold #000000", border_style="#444444", expand=True, box=None)
        table.add_column("", width=2)
        table.add_column("Step", width=10, style="#000000")
        table.add_column("Checks", width=16)
        table.add_column("Status", width=14)
        for step in self.steps:
            status_style = "#008800" if step.status == Status.SUCCESS else "#CC0000" if step.status == Status.FAILED else "#0066AA" if step.status == Status.WAITING else "#666666"
            table.add_row(self.render_step_icon(step), Text(step.description, style="#000000"), self.render_checkpoints_row(step.checkpoints), Text(step.message or "", style=status_style))
        return table

    def render_checkpoint_details(self) -> Table:
        table = Table(show_header=False, border_style="#444444", expand=True, box=None)
        table.add_column("", width=12, style="#000000")
        table.add_column("", width=8, style="#000000")
        table.add_column("", width=2)
        table.add_column("", width=8, style="#444444")
        for step in self.steps:
            if step.status in (Status.WAITING, Status.FAILED, Status.RUNNING) or any(cp.status in (Status.WAITING, Status.FAILED) for cp in step.checkpoints):
                for cp in step.checkpoints:
                    if cp.status != Status.PENDING:
                        icon, style = CHECKPOINT_STYLES[cp.status]
                        table.add_row(Text(step.description[:12], style="#0066AA"), cp.name[:8], Text(icon, style=style), Text(cp.message[:8] if cp.message else "", style="#444444"))
        return table

    def render_pvc_table(self) -> Table:
        table = Table(title="💾 PVCs", show_header=False, border_style="#444444", box=None, title_style="#000000")
        table.add_column("", width=22, style="#000000")
        table.add_column("", width=6)
        table.add_column("", width=5, style="#444444")
        for pvc in self._get_pvcs():
            st = pvc["status"]
            style = "#008800" if st == "Bound" else "#CC8800" if st == "Pending" else "#CC0000"
            table.add_row(Text(pvc["name"][:22], style="#000000"), Text(st[:6], style=style), pvc["size"][:5])
        return table

    def render_blinkenlights(self) -> Text:
        """Render full-width status panel with detailed metrics"""
        text = Text()
        all_done = all(s.status == Status.SUCCESS for s in self.steps)
        completed = sum(1 for s in self.steps if s.status == Status.SUCCESS)
        waiting = sum(1 for s in self.steps if s.status == Status.WAITING)
        failed = sum(1 for s in self.steps if s.status == Status.FAILED)
        total = len(self.steps)
        
        # Group steps by category
        infra_steps = [s for s in self.steps if s.name in ["tfplan", "tfapply", "vms"]]
        talos_steps = [s for s in self.steps if s.name in ["talos_cfg", "talos_boot", "nodes"]]
        net_steps = [s for s in self.steps if s.name in ["cilium"]]
        stor_steps = [s for s in self.steps if s.name in ["piraeus", "linstor", "satellites", "storage", "sc"]]
        apps_steps = [s for s in self.steps if s.name in ["traefik", "certmgr", "monitoring", "harbor", "gitea", "ingress"]]
        
        # Calculate category stats
        def cat_stats(steps):
            done = sum(1 for s in steps if s.status == Status.SUCCESS)
            wait = sum(1 for s in steps if s.status == Status.WAITING)
            fail = sum(1 for s in steps if s.status == Status.FAILED)
            return done, wait, fail, len(steps)
        
        # Header
        border = "═" * 98
        text.append(f"╔{border}╗\n", style="#444444")
        
        # Title row with stats
        text.append("║ ", style="#444444")
        title = "SYSTEM STATUS MONITOR"
        if all_done:
            for i, char in enumerate(title):
                colors = ["#00FF00", "#00DD00", "#00BB00", "#00FF00"]
                text.append(char, style=f"bold {colors[(self.frame + i) % len(colors)]}")
        else:
            text.append(title, style="bold #000000")
        
        text.append("  │  ", style="#444444")
        text.append(f"Progress: ", style="#666666")
        text.append(f"{completed}/{total}", style="bold #000000")
        text.append(f" ({int(completed/total*100)}%)", style="#666666")
        
        if waiting > 0:
            spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
            text.append(f"  │  {spinner} ", style="#FFAA33")
            text.append(f"{waiting} active", style="#FFAA33")
        if failed > 0:
            text.append(f"  │  ✗ ", style="#FF3333")
            text.append(f"{failed} failed", style="#FF3333")
        
        # Pad to fill width
        text.append(" " * 20 + "║\n", style="#444444")
        
        text.append(f"╠{border}╣\n", style="#444444")
        
        # Scrolling status message
        text.append("║ ", style="#444444")
        active_step = next((s for s in self.steps if s.status == Status.WAITING), None)
        if all_done:
            message = "★ CLUSTER READY ★ ALL COMPONENTS DEPLOYED ★ "
        elif active_step:
            message = f">>> {active_step.name.upper()}: {active_step.message or 'Processing...'} <<< "
        else:
            message = ">>> INITIALIZING <<< "
        
        scroll_offset = self.frame % len(message)
        scrolled = (message * 5)[scroll_offset:scroll_offset + 96]
        text.append(scrolled, style="#00AAFF bold")
        text.append(" ║\n", style="#444444")
        
        text.append(f"╠{border}╣\n", style="#444444")
        
        # Category rows with detailed info
        def render_category_row(label: str, steps_list: list, icon: str):
            done, wait, fail, tot = cat_stats(steps_list)
            text.append("║ ", style="#444444")
            text.append(f"{icon} ", style="#666666")
            text.append(f"{label:12}", style="bold #000000")
            text.append(" │ ", style="#444444")
            
            # LED indicators for each step
            for i, step in enumerate(steps_list):
                if step.status == Status.SUCCESS:
                    text.append("●", style="#33FF33")
                elif step.status == Status.WAITING:
                    on = (self.frame + i) % 4 < 2
                    text.append("●" if on else "○", style="#FFAA33" if on else LED_DIM)
                elif step.status == Status.FAILED:
                    on = self.frame % 2 == 0
                    text.append("●" if on else "○", style="#FF3333" if on else "#880000")
                else:
                    text.append("○", style=LED_DIM)
                text.append(" ", style="#444444")
            
            # Pad LEDs
            for _ in range(8 - len(steps_list)):
                text.append("  ", style="#444444")
            
            text.append("│ ", style="#444444")
            
            # Step names with status
            for step in steps_list[:4]:  # Show up to 4 step names
                if step.status == Status.SUCCESS:
                    text.append(f"{step.description[:8]:8} ", style="#008800")
                elif step.status == Status.WAITING:
                    text.append(f"{step.description[:8]:8} ", style="#AA6600")
                elif step.status == Status.FAILED:
                    text.append(f"{step.description[:8]:8} ", style="#CC0000")
                else:
                    text.append(f"{step.description[:8]:8} ", style="#666666")
            
            # Pad names
            for _ in range(4 - min(4, len(steps_list))):
                text.append(" " * 9, style="#444444")
            
            text.append("│ ", style="#444444")
            
            # Summary
            if done == tot:
                text.append("✓ DONE ", style="#33FF33 bold")
            elif fail > 0:
                text.append("✗ FAIL ", style="#FF3333 bold")
            elif wait > 0:
                spinner = DOTS_FRAMES[self.frame % len(DOTS_FRAMES)]
                text.append(f"{spinner} RUN  ", style="#FFAA33 bold")
            else:
                text.append("○ WAIT ", style="#666666")
            
            text.append(f"{done}/{tot}", style="#000000")
            text.append(" " * 5 + "║\n", style="#444444")
        
        render_category_row("INFRA", infra_steps, "🏗")
        render_category_row("TALOS", talos_steps, "🖥")
        render_category_row("NETWORK", net_steps, "🌐")
        render_category_row("STORAGE", stor_steps, "💾")
        render_category_row("APPS", apps_steps, "📦")
        
        text.append(f"╠{border}╣\n", style="#444444")
        
        # Progress bar row (full width)
        text.append("║ ", style="#444444")
        text.append("PROGRESS ", style="bold #000000")
        
        bar_width = 60
        fill = int((completed / total) * bar_width) if total > 0 else 0
        
        text.append("│", style="#444444")
        for i in range(bar_width):
            if i < fill:
                # Color gradient based on position
                if i < bar_width * 0.33:
                    text.append("█", style="#FF6633")
                elif i < bar_width * 0.66:
                    text.append("█", style="#FFAA33")
                else:
                    text.append("█", style="#33FF33")
            elif i == fill and self.frame % 4 < 2:
                text.append("▓", style="#FFAA33")
            else:
                text.append("░", style=LED_DIM)
        text.append("│", style="#444444")
        
        pct = int((completed / total) * 100) if total > 0 else 0
        text.append(f" {pct:3d}% ", style="bold #000000")
        
        # Elapsed time
        elapsed = int(time.time() - self.start_time)
        mins, secs = divmod(elapsed, 60)
        text.append(f"│ ⏱ {mins:02d}:{secs:02d} ", style="#666666")
        text.append("║\n", style="#444444")
        
        # Wave animation bar
        text.append("║ ", style="#444444")
        wave_width = 96
        for i in range(wave_width):
            wave_char = WAVE_FRAMES[(self.frame + i) % len(WAVE_FRAMES)]
            hue = (self.frame * 3 + i * 4) % 360
            if hue < 60:
                color = "#FF3333"
            elif hue < 120:
                color = "#FFAA33"
            elif hue < 180:
                color = "#33FF33"
            elif hue < 240:
                color = "#33FFFF"
            elif hue < 300:
                color = "#3366FF"
            else:
                color = "#FF33FF"
            text.append(wave_char, style=color)
        text.append(" ║\n", style="#444444")
        
        text.append(f"╚{border}╝", style="#444444")
        
        return text

    def render_celebration(self) -> Text:
        """Render a celebration when deployment completes!"""
        text = Text()
        all_done = all(s.status == Status.SUCCESS for s in self.steps)
        
        if not all_done:
            return text
        
        # Time since completion
        celebration_duration = self.frame - (self.completion_frame or self.frame)
        
        # Celebration colors
        colors = ["#FF3333", "#FF7F00", "#FFFF00", "#00FF00", "#00FFFF", "#0000FF", "#8B00FF"]
        
        # Fireworks!
        firework_chars = ["✦", "✧", "✶", "✷", "✸", "✹", "★", "☆", "✵", "✴"]
        
        lines = []
        
        # Banner line 1 - stars
        line1 = ""
        for i in range(50):
            if (self.frame + i) % 5 == 0:
                line1 += firework_chars[(self.frame + i) % len(firework_chars)]
            else:
                line1 += " "
        text.append(f"{line1}\n")
        
        # Apply rainbow colors to banner
        banner_text = " 🎉  DEPLOYMENT COMPLETE!  🎉 "
        for i, char in enumerate(banner_text):
            color = colors[(self.frame + i) % len(colors)]
            text.append(char, style=f"bold {color} on {BG_COLOR}")
        text.append("\n")
        
        # Stats line
        elapsed = int(time.time() - self.start_time)
        mins, secs = divmod(elapsed, 60)
        text.append(f"     Time: {mins}m {secs}s", style="bold #000000")
        
        # Test results if available
        results = self._load_test_results()
        if results and results.get("tests"):
            passed = results.get("passed", 0)
            total = passed + results.get("failed", 0)
            text.append(f"  │  Tests: {passed}/{total} ✓", style="bold #008800" if results.get("failed", 0) == 0 else "bold #CC0000")
        
        text.append("\n")
        
        # Fireworks line 2
        line2 = ""
        for i in range(50):
            if (self.frame + i + 3) % 7 == 0:
                line2 += firework_chars[(self.frame + i * 2) % len(firework_chars)]
            else:
                line2 += " "
        
        for i, char in enumerate(line2):
            if char != " ":
                color = colors[(self.frame + i) % len(colors)]
                text.append(char, style=color)
            else:
                text.append(char)
        
        return text

    def render_test_cards(self) -> Table:
        """Render test results as cards with BLINKENLIGHTS"""
        results = self._load_test_results()
        
        if not results or not results.get("tests"):
            table = Table(title="🧪 Tests", show_header=False, border_style="#444444", box=None, title_style="#000000")
            table.add_column("", width=40)
            status = results.get("status", "pending")
            if status == "running":
                # Animated waiting
                spinner = DOTS_FRAMES[self.frame % len(DOTS_FRAMES)]
                meter = METER_FRAMES[self.frame % len(METER_FRAMES)]
                table.add_row(Text(f"{spinner} Tests running... {meter}", style="#0066AA"))
            else:
                table.add_row(Text("○ No tests yet - awaiting deployment", style="#666666"))
            return table
        
        # Group tests by category
        categories = {}
        for test in results.get("tests", []):
            cat = test.get("category", "other")
            if cat not in categories:
                categories[cat] = []
            categories[cat].append(test)
        
        table = Table(title="🧪 Tests", show_header=False, border_style="#444444", box=None, title_style="#000000", expand=True)
        table.add_column("", width=8, style="#000000")
        table.add_column("", width=18, style="#000000")
        table.add_column("", width=2)
        table.add_column("", width=15, style="#444444")
        
        # Category icons
        cat_icons = {
            "basic": "🔧",
            "talos": "🖥️",
            "network": "🌐",
            "storage": "💾",
            "apps": "📦",
        }
        
        for cat, tests in categories.items():
            icon = cat_icons.get(cat, "•")
            for i, test in enumerate(tests):
                status = test.get("status", "")
                name = test.get("name", "?")[:18]
                msg = test.get("message", "")[:15]
                
                if status == "pass":
                    # Animated success - subtle pulse
                    phase = (self.frame + i * 2) % 8
                    if phase < 2:
                        st_icon = "★"
                        st_style = "#FFD700"
                    else:
                        st_icon = "✓"
                        st_style = "#33FF33"
                elif status == "fail":
                    # Alarming blink for failures
                    if self.frame % 4 < 2:
                        st_icon = "✗"
                        st_style = "#FF0000 bold"
                    else:
                        st_icon = "!"
                        st_style = "#FF6600"
                elif status == "skip":
                    st_icon = "○"
                    st_style = "#666666"
                    st_icon = "○"
                    st_style = "#666666"
                else:
                    st_icon = "?"
                    st_style = "#666666"
                
                table.add_row(
                    Text(f"{icon} {cat[:5]}", style="#444444"),
                    Text(name, style="#000000"),
                    Text(st_icon, style=st_style),
                    Text(msg, style="#444444")
                )
        
        # Summary
        passed = results.get("passed", 0)
        failed = results.get("failed", 0)
        total = passed + failed
        
        if total > 0:
            table.add_row("", "", "", "")
            summary_style = "#008800" if failed == 0 else "#CC0000"
            table.add_row(
                Text("", style="#444444"),
                Text(f"Total: {passed}/{total}", style=summary_style),
                Text("✓" if failed == 0 else "!", style=summary_style),
                Text("PASSED" if failed == 0 else f"{failed} FAIL", style=summary_style)
            )
        
        return table

    def render_progress_bar(self) -> Text:
        """Render a visual progress bar based on completed steps"""
        total = len(self.steps)
        done = sum(1 for s in self.steps if s.status == Status.SUCCESS)
        waiting = sum(1 for s in self.steps if s.status == Status.WAITING)
        
        bar_width = 20
        done_chars = int((done / total) * bar_width)
        waiting_chars = int((waiting / total) * bar_width)
        pending_chars = bar_width - done_chars - waiting_chars
        
        bar = Text()
        bar.append("█" * done_chars, style="#008800")
        bar.append("▓" * waiting_chars, style="#0066AA")
        bar.append("░" * pending_chars, style="#888888")
        bar.append(f" {done}/{total}", style="bold #000000")
        return bar

    def render_header_fancy(self) -> Text:
        """Render an animated header"""
        text = Text()
        
        # Check if all complete
        all_done = all(s.status == Status.SUCCESS for s in self.steps)
        if all_done and self.completion_frame is None:
            self.completion_frame = self.frame
        
        # Status icon
        if all_done:
            text.append(" ✓ ", style="bold #33FF33")
        elif any(s.status == Status.WAITING for s in self.steps):
            spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
            text.append(f" {spinner} ", style="bold #FFAA33")
        else:
            text.append(" ○ ", style="bold #666666")
        
        # Title with rainbow animation when complete
        title = "CURE BACKBONE DEPLOY"
        if all_done:
            # Rainbow celebration!
            colors = ["#FF0000", "#FF7F00", "#FFFF00", "#00FF00", "#0000FF", "#4B0082", "#9400D3"]
            for i, char in enumerate(title):
                color = colors[(self.frame + i) % len(colors)]
                text.append(char, style=f"bold {color} on {BG_COLOR}")
        else:
            # Normal with subtle wave
            for i, char in enumerate(title):
                phase = (self.frame + i) % 20
                if phase < 5:
                    text.append(char, style=f"bold #000000 on {BG_COLOR}")
                else:
                    text.append(char, style=f"bold #222222 on {BG_COLOR}")
        
        text.append("  │  ", style="#444444")
        text.append_text(self.render_progress_bar())
        
        # Uptime counter
        elapsed = int(time.time() - self.start_time)
        mins, secs = divmod(elapsed, 60)
        text.append("  ⏱ ", style="#444444")
        text.append(f"{mins:02d}:{secs:02d}", style="#000000 bold")
        
        # Animated clock
        clock = CLOCK_FRAMES[self.frame % len(CLOCK_FRAMES)]
        text.append(f"  {clock} ", style="#444444")
        text.append(time.strftime('%H:%M:%S'), style="#000000")
        
        # Activity indicator
        if all_done:
            text.append("  ✓", style="#33FF33")
        elif any(s.status == Status.WAITING for s in self.steps):
            activity = DOTS_FRAMES[self.frame % len(DOTS_FRAMES)]
            text.append(f"  {activity}", style="#FFAA33")
        else:
            text.append("  ●", style="#33FF33")
        
        return text

    def render_layout(self) -> Layout:
        all_done = all(s.status == Status.SUCCESS for s in self.steps)
        
        layout = Layout()
        
        if all_done:
            # CELEBRATION MODE! 🎉
            if self.blinkenlicht:
                layout.split_column(
                    Layout(name="header", size=3),
                    Layout(name="celebration", size=5),
                    Layout(name="main"),
                    Layout(name="blinken", size=12),
                    Layout(name="footer", size=3)
                )
            else:
                layout.split_column(
                    Layout(name="header", size=3),
                    Layout(name="celebration", size=5),
                    Layout(name="main"),
                    Layout(name="footer", size=3)
                )
            layout["celebration"].update(Panel(self.render_celebration(), border_style="#FFD700", style=BG_STYLE, title="🏆 VICTORY", title_align="center"))
        else:
            if self.blinkenlicht:
                layout.split_column(
                    Layout(name="header", size=3),
                    Layout(name="main"),
                    Layout(name="blinken", size=12),
                    Layout(name="footer", size=3)
                )
            else:
                layout.split_column(
                    Layout(name="header", size=3),
                    Layout(name="main"),
                    Layout(name="footer", size=3)
                )
        
        # Main area: steps on left, tests + pvcs on right
        layout["main"].split_row(Layout(name="left", ratio=2), Layout(name="right", ratio=3))
        layout["left"].split_column(Layout(name="steps", ratio=4), Layout(name="details", ratio=1))
        layout["right"].split_column(Layout(name="tests", ratio=4), Layout(name="pvcs", ratio=1))
        
        # Header with fancy animation
        layout["header"].update(Panel(self.render_header_fancy(), border_style="#444444", style=BG_STYLE))
        
        # Steps panel
        layout["steps"].update(Panel(self.render_step_table(), title="📋 Steps", border_style="#444444", style=BG_STYLE))
        layout["details"].update(Panel(self.render_checkpoint_details(), title="⚡ Active", border_style="#444444", style=BG_STYLE))
        
        # Tests and PVCs
        layout["tests"].update(Panel(self.render_test_cards(), border_style="#444444", style=BG_STYLE))
        layout["pvcs"].update(Panel(self.render_pvc_table(), border_style="#444444", style=BG_STYLE))
        
        # BLINKENLIGHTS! (only if enabled)
        if self.blinkenlicht:
            layout["blinken"].update(Panel(self.render_blinkenlights(), border_style="#444444", style=BG_STYLE))
        
        # Footer legend
        legend = Text()
        legend.append("  ", style="#444444")
        legend.append("□", style="#666666"); legend.append(" pending  ", style="#000000")
        legend.append("◧", style="#0066AA"); legend.append(" wait  ", style="#000000")
        legend.append("■", style="#33FF33"); legend.append(" done  ", style="#000000")
        legend.append("■", style="#FF3333"); legend.append(" fail  ", style="#000000")
        legend.append("│  ", style="#444444")
        legend.append("✓", style="#33FF33"); legend.append(" pass  ", style="#000000")
        legend.append("✗", style="#FF3333"); legend.append(" fail  ", style="#000000")
        legend.append("│  ", style="#444444")
        
        # Animated exit hint
        pulse = PULSE_FRAMES[self.frame % len(PULSE_FRAMES)]
        legend.append(f"{pulse} ", style="#FF6633")
        legend.append("Ctrl+C exit", style="#444444")
        
        layout["footer"].update(Panel(legend, border_style="#444444", style=BG_STYLE))
        return layout

    def update_all_statuses(self):
        for step in self.steps:
            if step.check_fn:
                try:
                    status, message = step.check_fn()
                    with self.lock:
                        step.status = status
                        step.message = message
                except Exception as e:
                    with self.lock:
                        step.status = Status.FAILED
                        step.message = str(e)[:15]

    def run(self, refresh_rate: float = 2.0):
        update_counter = 0
        # MAXIMUM BLINKENLIGHTS - 10 FPS for smooth animations!
        with Live(self.render_layout(), refresh_per_second=10, screen=True) as live:
            try:
                while True:
                    self.frame += 1
                    # Only do full status check every N frames (less frequent = faster UI)
                    if update_counter % 20 == 0:
                        self.update_all_statuses()
                    live.update(self.render_layout())
                    update_counter += 1
                    time.sleep(0.1)  # 10 FPS for MAXIMUM BLINKENLIGHTS
            except KeyboardInterrupt:
                # Fancy exit animation
                for i in range(5):
                    self.frame = i * 10
                    live.update(self.render_layout())
                    time.sleep(0.05)
                pass

    def run_once(self):
        self.update_all_statuses()
        self.console.print(self.render_step_table())
        self.console.print(self.render_pvc_table())


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Cure Backbone Deploy Dashboard")
    parser.add_argument("--workdir", "-w", default=".", help="Working directory")
    parser.add_argument("--once", "-1", action="store_true", help="Run once")
    parser.add_argument("--refresh", "-r", type=float, default=2.0, help="Refresh rate")
    parser.add_argument("--blinkenlicht", "-b", action="store_true", help="Enable blinkenlicht panel")
    args = parser.parse_args()
    dashboard = ClusterDashboard(workdir=args.workdir, blinkenlicht=args.blinkenlicht)
    if args.once:
        dashboard.run_once()
    else:
        dashboard.run(refresh_rate=args.refresh)


if __name__ == "__main__":
    main()
