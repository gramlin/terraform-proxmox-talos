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
    def __init__(self, workdir: str = ".", blinkenlicht: bool = False, control_room: bool = False):
        self.console = Console()
        self.workdir = workdir
        self.blinkenlicht = blinkenlicht
        self.control_room = control_room  # Always show completed/monitoring view (Kontrollrummet)
        self.kubeconfig = self._find_kubeconfig()
        self.talosconfig = os.path.join(workdir, "talosconfig.yml")
        self.test_results_file = os.path.join(workdir, ".test-results.json")
        self.health_data_file = os.path.join(workdir, ".health-data.json")  # Health data from do script
        self.steps: List[Step] = []
        self.test_results: dict = {}
        self.lock = threading.Lock()
        self.frame = 0  # Animation frame counter
        self.start_time = time.time()  # Track uptime
        self.completion_frame = None  # When did we complete?
        self.preflight_status = {}  # Preflight check status
        self._status_thread = None  # Background status checker
        self._status_running = False
        self.page_rotation = 0  # For rotating health pages on completion
        self._init_steps()
        self._init_preflight()

    def _init_preflight(self):
        """Initialize preflight checks - must be fast, no blocking!"""
        try:
            tf_files = len([f for f in os.listdir(self.workdir) if f.endswith('.tf')]) if os.path.isdir(self.workdir) else 0
        except:
            tf_files = 0
        
        # Check tracking files exist and are fresh (updated in last 30s)
        tf_tracking = os.path.join(self.workdir, ".tf-resources.json")
        talos_tracking = os.path.join(self.workdir, ".talos-status.json")
        proxmox_tracking = os.path.join(self.workdir, ".proxmox-status.json")
        
        def is_fresh(path, max_age=30):
            try:
                if os.path.isfile(path):
                    return time.time() - os.path.getmtime(path) < max_age
            except:
                pass
            return False
        
        self.preflight_status = {
            "workdir": os.path.isdir(self.workdir),
            "terraform": os.path.isdir(os.path.join(self.workdir, ".terraform")) or tf_files > 0,
            "tf_files": tf_files,
            "kubeconfig": os.path.isfile(self.kubeconfig) if self.kubeconfig else False,
            "talosconfig": os.path.isfile(self.talosconfig),
            "do_script": os.path.isfile(os.path.join(self.workdir, "do")),
            "secrets": os.path.isfile(os.path.join(self.workdir, "secrets-proxmox.tf")),
            # Tracking files status
            "tf_tracking": is_fresh(tf_tracking),
            "talos_tracking": is_fresh(talos_tracking),
            "proxmox_tracking": is_fresh(proxmox_tracking),
        }

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

    def _load_config(self) -> dict:
        """Load do.cfg configuration"""
        config = {
            "INSTALL_HARBOR": "true",
            "INSTALL_MONITORING": "true",
            "INSTALL_GITEA": "true",
        }
        
        # Try do.local.cfg first (overrides), then do.cfg
        for cfg_file in ["do.local.cfg", "do.cfg"]:
            cfg_path = os.path.join(self.workdir, cfg_file)
            if os.path.isfile(cfg_path):
                try:
                    with open(cfg_path, 'r') as f:
                        for line in f:
                            line = line.strip()
                            # Skip comments and empty lines
                            if not line or line.startswith('#'):
                                continue
                            # Parse KEY="value" or KEY=value
                            if '=' in line:
                                key, value = line.split('=', 1)
                                key = key.strip()
                                value = value.strip().strip('"').strip("'")
                                if key in config:
                                    config[key] = value
                except Exception:
                    pass
        
        # Normalize boolean values
        for key in config:
            val = config[key].lower()
            if val in ["true", "1", "yes"]:
                config[key] = True
            elif val in ["false", "0", "no"]:
                config[key] = False
        
        return config

    def _init_steps(self):
        # Load config to determine which components to show
        config = self._load_config()
        
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
        ]
        
        # Add optional components based on config
        if config.get("INSTALL_MONITORING", True):
            self.steps.append(
                Step("monitoring", "Monitor",
                     check_fn=self._check_monitoring,
                     checkpoints=[Checkpoint("prom"), Checkpoint("graf"), Checkpoint("alert"), Checkpoint("node"), Checkpoint("kube")])
            )
        
        if config.get("INSTALL_HARBOR", True):
            self.steps.append(
                Step("harbor", "Harbor",
                     check_fn=self._check_harbor,
                     checkpoints=[Checkpoint("pvc"), Checkpoint("db"), Checkpoint("red"), Checkpoint("core"), Checkpoint("reg"), Checkpoint("job"), Checkpoint("tri")])
            )
        
        if config.get("INSTALL_GITEA", True):
            self.steps.append(
                Step("gitea", "Gitea",
                     check_fn=self._check_gitea,
                     checkpoints=[Checkpoint("pvc"), Checkpoint("db"), Checkpoint("app"), Checkpoint("ing")])
            )
        
        # Always add ingress check last
        self.steps.append(
            Step("ingress", "Ingress",
                 check_fn=self._check_ingress,
                 checkpoints=[Checkpoint("cert"), Checkpoint("issuer"), Checkpoint("ing")])
        )

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
                
                vm_resources = [r for r in resources if "proxmox_virtual_environment_vm" in r.get("type", "")]

                # Check for controller VMs (match "controller" or "cp" in name)
                ctrl_resources = [r for r in vm_resources if "controller" in r.get("name", "").lower() or "cp" in r.get("name", "").lower()]
                ctrl_count = sum(len(r.get("instances", [])) for r in ctrl_resources)
                if ctrl_count > 0:
                    checkpoints[1].status = Status.SUCCESS
                    checkpoints[1].message = str(ctrl_count)
                
                # Check for worker VMs (match "worker" or "wk" in name)
                worker_resources = [r for r in vm_resources if "worker" in r.get("name", "").lower() or "wk" in r.get("name", "").lower()]
                worker_count = sum(len(r.get("instances", [])) for r in worker_resources)
                if worker_count > 0:
                    checkpoints[2].status = Status.SUCCESS
                    checkpoints[2].message = str(worker_count)
                
                total_vms = ctrl_count + worker_count
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
            # Check if terraform is running (VMs being created)
            tf_file = os.path.join(self.workdir, ".tf-resources.json")
            if os.path.isfile(tf_file):
                try:
                    with open(tf_file) as f:
                        tf_data = json.load(f)
                        if tf_data.get("status") == "running":
                            # Set all checkpoints to waiting (being created)
                            for cp in checkpoints:
                                cp.status = Status.WAITING
                            return Status.WAITING, "Creating..."
                except:
                    pass
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
                
                # Map to checkpoints - match by position number in name
                # Controllers have "cp" and workers have "wk" in their names
                running = 0
                matched_cps = set()
                
                for vm_name, started in vm_names:
                    vm_lower = vm_name.lower()
                    cp_idx = None
                    
                    # Match controllers: erwecp1, erwecp2, cp1, cp2, controller1, ctrl1
                    if "cp1" in vm_lower or "controller1" in vm_lower or "ctrl1" in vm_lower or vm_lower.endswith("cp-1"):
                        cp_idx = 0
                    elif "cp2" in vm_lower or "controller2" in vm_lower or "ctrl2" in vm_lower or vm_lower.endswith("cp-2"):
                        cp_idx = 1
                    # Match workers: erwewk1-4, wk1-4, worker1-4
                    elif "wk1" in vm_lower or "worker1" in vm_lower or "work1" in vm_lower or vm_lower.endswith("wk-1"):
                        cp_idx = 2
                    elif "wk2" in vm_lower or "worker2" in vm_lower or "work2" in vm_lower or vm_lower.endswith("wk-2"):
                        cp_idx = 3
                    elif "wk3" in vm_lower or "worker3" in vm_lower or "work3" in vm_lower or vm_lower.endswith("wk-3"):
                        cp_idx = 4
                    elif "wk4" in vm_lower or "worker4" in vm_lower or "work4" in vm_lower or vm_lower.endswith("wk-4"):
                        cp_idx = 5
                    
                    if cp_idx is not None and cp_idx < len(checkpoints):
                        matched_cps.add(cp_idx)
                        if started:
                            checkpoints[cp_idx].status = Status.SUCCESS
                            running += 1
                        else:
                            checkpoints[cp_idx].status = Status.WAITING
                
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
        
        # Machine secrets - check terraform state for talos_machine_secrets
        tfstate = os.path.join(self.workdir, "terraform.tfstate")
        if os.path.isfile(tfstate):
            try:
                with open(tfstate) as f:
                    state = json.load(f)
                    resources = state.get("resources", [])
                    has_secrets = any("talos_machine_secrets" in r.get("type", "") for r in resources)
                    if has_secrets:
                        checkpoints[0].status = Status.SUCCESS
            except:
                pass
        
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
            
            # Track which components we've found
            # Note: In Talos, etcd runs as a system service, not a k8s pod
            # So we check apiserver, scheduler, controller-manager (3 components)
            found = {"apiserver": False, "scheduler": False, "controller-manager": False}
            
            for pod in pods:
                name = pod.get("metadata", {}).get("name", "").lower()
                phase = pod.get("status", {}).get("phase", "")
                is_running = phase == "Running"
                
                # Match specific component names
                if "kube-apiserver" in name:
                    if is_running:
                        checkpoints[0].status = Status.SUCCESS
                        found["apiserver"] = True
                    elif not found["apiserver"]:
                        checkpoints[0].status = Status.WAITING
                        
                elif "kube-scheduler" in name:
                    if is_running:
                        checkpoints[1].status = Status.SUCCESS
                        found["scheduler"] = True
                    elif not found["scheduler"]:
                        checkpoints[1].status = Status.WAITING
                        
                elif "kube-controller-manager" in name:
                    if is_running:
                        checkpoints[2].status = Status.SUCCESS
                        found["controller-manager"] = True
                    elif not found["controller-manager"]:
                        checkpoints[2].status = Status.WAITING
            
            # Also mark 4th checkpoint as success if we have the 3 core components
            # (checkpoint layout has 4 slots but Talos only has 3 visible components)
            ready = sum(1 for cp in checkpoints[:3] if cp.status == Status.SUCCESS)
            if ready == 3:
                checkpoints[3].status = Status.SUCCESS
                return Status.SUCCESS, "Control plane up"
            return Status.WAITING, f"{ready}/3 comps"
        except:
            return Status.WAITING, "Parsing"
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
            
            ready_count = 0
            for node in nodes:
                name = node.get("metadata", {}).get("name", "").lower()
                conditions = node.get("status", {}).get("conditions", [])
                is_ready = any(c["type"] == "Ready" and c["status"] == "True" for c in conditions)
                
                # Match by position number in name
                cp_idx = None
                if "cp1" in name or "controller1" in name or "ctrl1" in name or name.endswith("cp-1"):
                    cp_idx = 0
                elif "cp2" in name or "controller2" in name or "ctrl2" in name or name.endswith("cp-2"):
                    cp_idx = 1
                elif "wk1" in name or "worker1" in name or "work1" in name or name.endswith("wk-1"):
                    cp_idx = 2
                elif "wk2" in name or "worker2" in name or "work2" in name or name.endswith("wk-2"):
                    cp_idx = 3
                elif "wk3" in name or "worker3" in name or "work3" in name or name.endswith("wk-3"):
                    cp_idx = 4
                elif "wk4" in name or "worker4" in name or "work4" in name or name.endswith("wk-4"):
                    cp_idx = 5
                
                if cp_idx is not None and cp_idx < len(checkpoints):
                    if is_ready:
                        checkpoints[cp_idx].status = Status.SUCCESS
                        ready_count += 1
                    else:
                        checkpoints[cp_idx].status = Status.WAITING
            
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
        """Check Cilium CNI - just verify pods are running"""
        step = self._get_step("cilium")
        checkpoints = step.checkpoints
        pods = []
        
        # Get all pods in kube-system and filter by name
        success, output = self._kubectl(["get", "pods", "-n", "kube-system", "-o", "json"])
        if not success:
            return Status.WAITING, "No kubectl"
        
        try:
            data = json.loads(output)
            all_pods = data.get("items", [])
            # Filter for cilium pods (cilium-XXXXX format, not envoy/operator)
            for p in all_pods:
                name = p.get("metadata", {}).get("name", "")
                if name.startswith("cilium-") and "envoy" not in name:
                    pods.append(p)
        except Exception as e:
            return Status.FAILED, f"JSON error"
        
        if not pods:
            return Status.WAITING, "No pods"
        
        try:
            def is_running(p): return p.get("status", {}).get("phase") == "Running"
            
            # Find operator and agents by name pattern
            operators = [p for p in pods if "operator" in p.get("metadata", {}).get("name", "")]
            # Agents are cilium-XXXXX (random suffix), not operator
            agents = [p for p in pods if not "operator" in p.get("metadata", {}).get("name", "")]
            
            # Operator checkpoint (index 0)
            if operators and is_running(operators[0]):
                checkpoints[0].status = Status.SUCCESS
            elif operators:
                checkpoints[0].status = Status.WAITING
            
            # Agent checkpoints (index 1-6)
            running_agents = [a for a in agents if is_running(a)]
            for i in range(min(len(running_agents), 6)):
                if i + 1 < len(checkpoints):
                    checkpoints[i + 1].status = Status.SUCCESS
            
            running = sum(1 for p in pods if is_running(p))
            total = len(pods)
            if running == total and total > 0:
                return Status.SUCCESS, f"{running} pods"
            return Status.WAITING, f"{running}/{total}"
        except:
            return Status.FAILED, "Error"

    def _check_piraeus_operator(self) -> tuple:
        step = self._get_step("piraeus")
        checkpoints = step.checkpoints
        
        # Check for LINSTOR CRDs
        success, output = self._kubectl(["get", "crd", "-o", "name"])
        if success and "linstor" in output.lower():
            checkpoints[0].status = Status.SUCCESS
        
        # Check operator pod - try multiple label patterns
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            
            operator_running = False
            csi_ctrl_running = False
            csi_node_count = 0
            csi_node_ready = 0
            
            for p in pods:
                name = p.get("metadata", {}).get("name", "")
                phase = p.get("status", {}).get("phase")
                
                # Operator pod
                if "operator" in name and phase == "Running":
                    operator_running = True
                    checkpoints[1].status = Status.SUCCESS
                
                # CSI controller
                if "csi-controller" in name or ("csi" in name and "controller" in name):
                    if phase == "Running":
                        csi_ctrl_running = True
                        checkpoints[2].status = Status.SUCCESS
                    else:
                        checkpoints[2].status = Status.WAITING
                
                # CSI node pods
                if "csi-node" in name or ("csi" in name and "node" in name):
                    csi_node_count += 1
                    if phase == "Running":
                        csi_node_ready += 1
            
            if csi_node_count > 0:
                checkpoints[3].message = f"{csi_node_ready}/{csi_node_count}"
                if csi_node_ready == csi_node_count:
                    checkpoints[3].status = Status.SUCCESS
                elif csi_node_ready > 0:
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
            
            # Match pods by name pattern
            for pod in pods:
                name = pod.get("metadata", {}).get("name", "").lower()
                ready = is_ready(pod)
                
                # Skip startup/job pods
                if "startupapicheck" in name:
                    continue
                
                if "webhook" in name:
                    checkpoints[1].status = Status.SUCCESS if ready else Status.WAITING
                elif "cainjector" in name:
                    checkpoints[2].status = Status.SUCCESS if ready else Status.WAITING
                elif "cert-manager" in name:
                    # Main controller pod
                    checkpoints[0].status = Status.SUCCESS if ready else Status.WAITING
            
            # Check ClusterIssuer (optional - don't block on it)
            issuer_success, issuer_output = self._kubectl(["get", "clusterissuer", "-o", "json"])
            if issuer_success:
                try:
                    issuer_data = json.loads(issuer_output)
                    issuers = issuer_data.get("items", [])
                    ready_issuers = sum(1 for iss in issuers if any(c.get("type") == "Ready" and c.get("status") == "True" for c in iss.get("status", {}).get("conditions", [])))
                    if ready_issuers > 0:
                        checkpoints[3].status = Status.SUCCESS
                        checkpoints[3].message = f"{ready_issuers}"
                    elif issuers:
                        checkpoints[3].status = Status.WAITING
                except:
                    pass
            
            # Count only core pods (first 3 checkpoints) for status
            core_done = sum(1 for cp in checkpoints[:3] if cp.status == Status.SUCCESS)
            issuer_done = 1 if checkpoints[3].status == Status.SUCCESS else 0
            
            if core_done == 3:
                if issuer_done:
                    return Status.SUCCESS, f"4/4"
                return Status.SUCCESS, f"3/3 pods"
            return Status.WAITING, f"{core_done}/3"
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

    def render_checkpoints_row(self, checkpoints: List[Checkpoint], step: Step = None) -> Text:
        text = Text()
        
        # Check if this step is actively running
        is_step_active = False
        if step:
            dashboard_status = self._load_dashboard_status()
            current_step = dashboard_status.get("current_step", "").lower()
            step_status = dashboard_status.get("status", "")
            
            # Only active if status is "running" and step matches
            if step_status == "running" and current_step:
                step_name_lower = step.name.lower()
                if "terraform" in current_step or "tf" in current_step:
                    if step_name_lower in ["tfplan", "tfapply", "vms"]:
                        is_step_active = True
                elif "talos" in current_step or "bootstrap" in current_step or "kubeconfig" in current_step:
                    if step_name_lower in ["talos_cfg", "talos_boot", "nodes"]:
                        is_step_active = True
                elif "storage" in current_step or "linstor" in current_step or "piraeus" in current_step or "satellite" in current_step or "pool" in current_step:
                    if step_name_lower in ["piraeus", "linstor", "satellites", "storage", "sc"]:
                        is_step_active = True
                elif "cilium" in current_step:
                    if step_name_lower == "cilium":
                        is_step_active = True
                elif "traefik" in current_step:
                    if step_name_lower == "traefik":
                        is_step_active = True
                elif "cert" in current_step:
                    if step_name_lower in ["certmgr", "ingress"]:
                        is_step_active = True
                elif "harbor" in current_step:
                    if step_name_lower == "harbor":
                        is_step_active = True
                elif "gitea" in current_step:
                    if step_name_lower == "gitea":
                        is_step_active = True
                elif "monitor" in current_step or "prometheus" in current_step or "grafana" in current_step:
                    if step_name_lower == "monitoring":
                        is_step_active = True
        
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
                # Bright green if step is active, dark green if completed/inactive
                if is_step_active:
                    # Subtle pulse for active items
                    phase = (self.frame + i * 3) % 8
                    brightness = "33FF33" if phase < 4 else "22DD22"
                    text.append("■", style=f"#{brightness}")
                else:
                    # Dark green for completed/inactive
                    text.append("■", style="#006600")
            else:
                icon, style = CHECKPOINT_STYLES.get(cp.status, ("○", "#666666"))
                text.append(icon, style=style)
        return text

    def render_step_icon(self, step: Step) -> Text:
        """Render step icon with animation for waiting states"""
        
        # Check if this step is actively running (tracking file recently updated)
        is_actively_running = False
        dashboard_status = self._load_dashboard_status()
        current_step = dashboard_status.get("current_step", "").lower()
        
        # Map step names to tracking indicators
        step_name_lower = step.name.lower()
        
        # More flexible matching - check for keywords in current_step
        if current_step:
            # Terraform-related (includes "read terraform outputs")
            if "terraform" in current_step or "tf" in current_step:
                if step_name_lower in ["tfplan", "tfapply", "vms"]:
                    is_actively_running = True
            # Talos-related
            elif "talos" in current_step or "bootstrap" in current_step or "kubeconfig" in current_step:
                if step_name_lower in ["talos_cfg", "talos_boot", "nodes"]:
                    is_actively_running = True
            # Storage-related
            elif "storage" in current_step or "linstor" in current_step or "piraeus" in current_step or "satellite" in current_step or "pool" in current_step:
                if step_name_lower in ["piraeus", "linstor", "satellites", "storage", "sc"]:
                    is_actively_running = True
            # Networking
            elif "cilium" in current_step:
                if step_name_lower == "cilium":
                    is_actively_running = True
            # Apps and services
            elif "traefik" in current_step:
                if step_name_lower == "traefik":
                    is_actively_running = True
            elif "cert" in current_step:
                if step_name_lower in ["certmgr", "ingress"]:
                    is_actively_running = True
            elif "harbor" in current_step:
                if step_name_lower == "harbor":
                    is_actively_running = True
            elif "gitea" in current_step:
                if step_name_lower == "gitea":
                    is_actively_running = True
            elif "monitor" in current_step or "prometheus" in current_step or "grafana" in current_step:
                if step_name_lower == "monitoring":
                    is_actively_running = True
        
        # IMPORTANT: Only show orange if status from .dashboard-status.json is "running"
        # If status is "complete", don't override with orange
        step_status = dashboard_status.get("status", "")
        if is_actively_running and step.status == Status.SUCCESS and step_status == "running":
            icon = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
            return Text(icon, style="#FF8800 bold")  # Orange for re-run
        
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
            table.add_row(self.render_step_icon(step), Text(step.description, style="#000000"), self.render_checkpoints_row(step.checkpoints, step), Text(step.message or "", style=status_style))
        return table

    def render_checkpoint_details(self) -> Table:
        table = Table(show_header=False, border_style="#444444", expand=True, box=None)
        table.add_column("", width=12, style="#000000")
        table.add_column("", width=8, style="#000000")
        table.add_column("", width=2)
        table.add_column("", width=8, style="#444444")
        
        # Show current script step from do script
        dashboard_status = self._load_dashboard_status()
        current_step = dashboard_status.get("current_step", "")
        step_status = dashboard_status.get("status", "")
        
        if current_step:
            # Truncate long step names
            step_display = current_step[:20]
            if step_status == "running":
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                table.add_row(
                    Text("▶ Script", style="bold #0066AA"),
                    Text(step_display[:8], style="#000000"),
                    Text(spinner, style="bold #FFAA33"),
                    Text("", style="#666666")
                )
            elif step_status == "failed":
                table.add_row(
                    Text("✗ Script", style="bold #FF3333"),
                    Text(step_display[:8], style="#000000"),
                    Text("!", style="bold #FF3333"),
                    Text("FAIL", style="#FF3333")
                )
            table.add_row(Text("", style="#666666"), Text("", style="#666666"), Text("", style="#666666"), Text("", style="#666666"))
        
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
        
        # Scrolling status message - show current script step
        text.append("║ ", style="#444444")
        
        # Get current step from do script
        dashboard_status = self._load_dashboard_status()
        script_step = dashboard_status.get("current_step", "")
        
        active_step = next((s for s in self.steps if s.status == Status.WAITING), None)
        if all_done:
            message = "★ CLUSTER READY ★ ALL COMPONENTS DEPLOYED ★ "
        elif script_step:
            # Show what the script is actually doing right now
            message = f">>> {script_step.upper()} <<< "
        elif active_step:
            message = f">>> {active_step.name.upper()}: {active_step.message or 'Processing...'} <<< "
        else:
            message = ">>> INITIALIZING <<< "
        
        scroll_offset = self.frame % len(message)
        scrolled = (message * 5)[scroll_offset:scroll_offset + 96]
        text.append(scrolled, style="#00AAFF bold")
        text.append(" ║\n", style="#444444")
        
        text.append(f"╠{border}╣\n", style="#444444")
        
        # Category rows with detailed info - fixed width columns, NO EMOJIS
        def render_category_row(label: str, steps_list: list):
            done, wait, fail, tot = cat_stats(steps_list)
            text.append("║ ", style="#444444")
            text.append(f"{label:8}", style="bold #000000")
            text.append(" │", style="#444444")
            
            # LED indicators for each step (fixed 6 slots)
            for i in range(6):
                if i < len(steps_list):
                    step = steps_list[i]
                    if step.status == Status.SUCCESS:
                        text.append(" *", style="#33FF33")
                    elif step.status == Status.WAITING:
                        on = (self.frame + i) % 4 < 2
                        text.append(" *" if on else " o", style="#FFAA33" if on else LED_DIM)
                    elif step.status == Status.FAILED:
                        on = self.frame % 2 == 0
                        text.append(" X" if on else " x", style="#FF3333" if on else "#880000")
                    else:
                        text.append(" o", style=LED_DIM)
                else:
                    text.append("  ", style="#444444")
            
            text.append(" │", style="#444444")
            
            # Step names with status (fixed 5 slots, 10 chars each)
            for i in range(5):
                if i < len(steps_list):
                    step = steps_list[i]
                    name = step.description[:10].ljust(10)
                    if step.status == Status.SUCCESS:
                        text.append(f" {name}", style="#008800")
                    elif step.status == Status.WAITING:
                        text.append(f" {name}", style="#AA6600")
                    elif step.status == Status.FAILED:
                        text.append(f" {name}", style="#CC0000")
                    else:
                        text.append(f" {name}", style="#666666")
                else:
                    text.append(" " * 11, style="#444444")
            
            text.append(" │", style="#444444")
            
            # Summary (fixed width 12 chars)
            if done == tot:
                text.append(" [DONE]  ", style="#33FF33 bold")
            elif fail > 0:
                text.append(" [FAIL]  ", style="#FF3333 bold")
            elif wait > 0:
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                text.append(f" {spinner} RUN   ", style="#FFAA33 bold")
            else:
                text.append(" [WAIT]  ", style="#666666")
            
            text.append(f"{done}/{tot}".rjust(4), style="#000000")
            text.append(" ║\n", style="#444444")
        
        render_category_row("INFRA", infra_steps)
        render_category_row("TALOS", talos_steps)
        render_category_row("NETWORK", net_steps)
        render_category_row("STORAGE", stor_steps)
        render_category_row("APPS", apps_steps)
        
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

    def _get_completion_page(self) -> tuple:
        """Return the current completion page (title, content_widget).
        Rotates through different health check pages every 5 seconds."""
        # Rotate pages every 5 seconds (15 frames at ~3 fps)
        page_index = (self.frame // 15) % 4
        
        if page_index == 0:
            # Cluster Health
            return ("⚡ Cluster Status", Panel(
                self.render_cluster_health(), 
                border_style="#44FF44", 
                style=BG_STYLE
            ))
        elif page_index == 1:
            # Test Results
            test_results = self._load_test_results()
            if test_results and test_results.get("tests"):
                return ("🧪 Test Results", Panel(
                    self.render_test_cards(),
                    border_style="#FFAA00",
                    style=BG_STYLE
                ))
            else:
                # Fallback to proxmox if no tests
                page_index = 2
        
        if page_index == 2:
            # Proxmox VMs
            proxmox_data = self._load_proxmox_status()
            if proxmox_data.get("vms"):
                return ("🖥️  VMs", Panel(
                    self.render_proxmox_status(),
                    border_style="#3366FF",
                    style=BG_STYLE
                ))
            else:
                page_index = 3
        
        if page_index == 3:
            # Info / Next Steps
            info_text = Text()
            info_text.append("✓ Cluster deployment complete!\n\n", style="bold #008800")
            info_text.append("Next steps:\n", style="bold #000000")
            info_text.append("  • Run './do report' for full deployment status\n", style="#000000")
            info_text.append("  • Run './do info' for access information\n", style="#000000")
            info_text.append("  • Run './do test' for validation tests\n", style="#000000")
            info_text.append("\nDashboard rotates through health metrics every 5 seconds.", style="#444444")
            return ("📊 Info", Panel(info_text, border_style="#CCCCCC", style=BG_STYLE))
        
        # Default fallback
        return ("📊 Info", Panel(
            Text("Cluster deployment complete!\nRun './do report' for status"),
            border_style="#444444",
            style=BG_STYLE
        ))

    def render_celebration(self) -> Text:
        """Render completion status (simple, readable)."""
        text = Text()
        all_done = all(s.status == Status.SUCCESS for s in self.steps)
        
        if not all_done and not self.control_room:
            return text
        
        # Simple completion message
        if all_done:
            text.append("✓ Klustret är redo", style="bold #008800")
        else:
            text.append("◐ Övervakar kluster...", style="bold #3366FF")
        
        # Stats line - load health data if available
        health_data = self._load_health_data()
        if health_data:
            nodes = health_data.get("nodes_ready", 0)
            total_nodes = health_data.get("nodes_total", 0)
            text.append(f"  │  Noder: {nodes}/{total_nodes}", style="bold #008800" if nodes == total_nodes else "bold #FFAA33")
            
            pods = health_data.get("pods_running", 0)
            text.append(f"  │  Poddar: {pods}", style="bold #000000")
        else:
            elapsed = int(time.time() - self.start_time)
            mins, secs = divmod(elapsed, 60)
            text.append(f"  │  Tid: {mins}m {secs}s", style="bold #000000")
        
        # Test results if available
        results = self._load_test_results()
        if results and results.get("tests"):
            passed = results.get("passed", 0)
            total = passed + results.get("failed", 0)
            text.append(f"  │  Tester: {passed}/{total}", style="bold #008800" if results.get("failed", 0) == 0 else "bold #CC0000")
        
        return text

    def render_control_room_status(self) -> Text:
        """Render control room status when deployment is not complete."""
        text = Text()
        
        # Load health data from do script
        health_data = self._load_health_data()
        
        completed = sum(1 for s in self.steps if s.status == Status.SUCCESS)
        total = len(self.steps)
        
        if health_data:
            nodes = health_data.get("nodes_ready", 0)
            total_nodes = health_data.get("nodes_total", 0)
            text.append(f"◐ Övervakar  │  Noder: {nodes}/{total_nodes}", style="bold #3366FF")
            
            if health_data.get("cpu_usage"):
                text.append(f"  │  CPU: {health_data['cpu_usage']:.1f}%", style="bold #000000")
            if health_data.get("memory_usage"):
                text.append(f"  │  Minne: {health_data['memory_usage']:.1f}%", style="bold #000000")
        else:
            text.append(f"◐ Övervakar kluster  │  Steg: {completed}/{total}", style="bold #3366FF")
        
        return text

    def _load_health_data(self) -> dict:
        """Load health data from JSON file (written by do script)"""
        if os.path.isfile(self.health_data_file):
            try:
                mtime = os.path.getmtime(self.health_data_file)
                # Only use if updated in last 60 seconds
                if time.time() - mtime < 60:
                    with open(self.health_data_file, "r") as f:
                        return json.load(f)
            except (json.JSONDecodeError, IOError, OSError):
                pass
        return {}

    def render_preflight(self) -> Table:
        """Render preflight status panel"""
        table = Table(title="Preflight", show_header=False, border_style="#444444", box=None, title_style="#000000", expand=True)
        table.add_column("Check", ratio=2, style="#000000")
        table.add_column("Status", ratio=1)
        
        # Basic checks
        checks = [
            ("Workdir", self.preflight_status.get("workdir", False)),
            ("TF Files", self.preflight_status.get("tf_files", 0) > 0),
            ("Secrets", self.preflight_status.get("secrets", False)),
            ("Do Script", self.preflight_status.get("do_script", False)),
        ]
        
        for name, ok in checks:
            if ok:
                status = Text("OK", style="bold #33FF33")
            else:
                # Animate pending checks
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                status = Text(f"{spinner}", style="bold #FFAA33")
            table.add_row(Text(name, style="#000000"), status)
        
        # Divider
        table.add_row(Text("─ Config ─", style="#666666"), Text("", style="#666666"))
        
        # Config files (become green when generated)
        config_checks = [
            ("Kubeconfig", self.preflight_status.get("kubeconfig", False)),
            ("Talosconfig", self.preflight_status.get("talosconfig", False)),
        ]
        for name, ok in config_checks:
            if ok:
                status = Text("✓", style="bold #33FF33")
            else:
                status = Text("○", style="#666666")
            table.add_row(Text(name, style="#000000"), status)
        
        # Tracking status (shows activity from do script)
        table.add_row(Text("─ Activity ─", style="#666666"), Text("", style="#666666"))
        
        tracking_checks = [
            ("TF Track", self.preflight_status.get("tf_tracking", False)),
            ("Talos Track", self.preflight_status.get("talos_tracking", False)),
            ("Proxmox Track", self.preflight_status.get("proxmox_tracking", False)),
        ]
        for name, ok in tracking_checks:
            if ok:
                # Active tracking - blinking indicator
                blink = PULSE_FRAMES[self.frame % len(PULSE_FRAMES)]
                status = Text(blink, style="bold #33FF33")
            else:
                status = Text("○", style="#666666")
            table.add_row(Text(name, style="#000000"), status)
        
        return table

    def _load_dashboard_status(self) -> dict:
        """Load current step from do script"""
        status_file = os.path.join(self.workdir, ".dashboard-status.json")
        if os.path.exists(status_file):
            try:
                mtime = os.path.getmtime(status_file)
                # Only show if updated in last 60 seconds
                if time.time() - mtime < 60:
                    with open(status_file, "r") as f:
                        return json.load(f)
            except (json.JSONDecodeError, IOError, OSError):
                pass
        return {}

    def _load_tf_resources(self) -> dict:
        """Load terraform resources from JSON file"""
        tf_file = os.path.join(self.workdir, ".tf-resources.json")
        if os.path.exists(tf_file):
            try:
                mtime = os.path.getmtime(tf_file)
                # Only read if file was modified in last 5 minutes
                if time.time() - mtime < 300:
                    with open(tf_file, "r") as f:
                        return json.load(f)
            except (json.JSONDecodeError, IOError, OSError):
                pass
        return {"resources": [], "status": "idle"}

    def render_tf_resources(self) -> Table:
        """Render terraform resource activity"""
        data = self._load_tf_resources()
        resources = data.get("resources", [])
        status = data.get("status", "idle")
        
        table = Table(title="Terraform", show_header=False, border_style="#444444", box=None, title_style="#000000", expand=True)
        table.add_column("Resource", ratio=3, style="#000000", no_wrap=True, overflow="ellipsis")
        table.add_column("Action", ratio=1)
        
        if status == "idle" or not resources:
            table.add_row(
                Text("Waiting for terraform...", style="#666666"),
                Text("", style="#666666")
            )
            return table
        
        # Show most recent resources (up to 4)
        recent = sorted(resources, key=lambda r: r.get("updated", ""), reverse=True)[:4]
        
        for res in recent:
            name = res.get("name", "?")[:20]
            action = res.get("action", "?")
            
            # Color based on action
            if action == "complete":
                action_text = Text("OK", style="#33FF33")
            elif action == "creating":
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                action_text = Text(f"{spinner}", style="#FFAA33")
            elif action == "modifying":
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                action_text = Text(f"{spinner}", style="#0088FF")
            elif action == "destroying":
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                action_text = Text(f"{spinner}", style="#FF6633")
            elif action == "failed":
                action_text = Text("!!", style="#FF3333 bold")
            else:
                action_text = Text(".", style="#666666")
            
            table.add_row(Text(name, style="#000000"), action_text)
        
        # Show count if more
        if len(resources) > 4:
            table.add_row(
                Text(f"+{len(resources) - 4} more", style="#666666"),
                Text("", style="#666666")
            )
        
        return table

    def _load_talos_status(self) -> dict:
        """Load talos status from JSON file"""
        talos_file = os.path.join(self.workdir, ".talos-status.json")
        if os.path.exists(talos_file):
            try:
                with open(talos_file, "r") as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError):
                pass
        return {"operations": [], "status": "idle"}

    def _load_linstor_status(self) -> dict:
        """Load linstor status from JSON file"""
        linstor_file = os.path.join(self.workdir, ".linstor-status.json")
        if os.path.exists(linstor_file):
            try:
                with open(linstor_file, "r") as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError):
                pass
        return {"operations": [], "status": "idle"}

    def _query_prometheus(self, query: str, timeout: int = 5) -> Optional[dict]:
        """Query Prometheus via port-forward"""
        try:
            # Try to port-forward to prometheus
            pf_cmd = [
                "kubectl", "port-forward", 
                "-n", "monitoring",
                "svc/kube-prometheus-stack-prometheus", 
                "9090:9090", 
                "-q"
            ]
            
            # Start port-forward in background (will timeout and close itself)
            pf_proc = subprocess.Popen(pf_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            
            # Give it a moment to establish
            time.sleep(0.2)
            
            # Query prometheus
            import urllib.request
            import urllib.error
            import urllib.parse
            
            url = f"http://localhost:9090/api/v1/query?query={urllib.parse.quote(query)}"
            try:
                with urllib.request.urlopen(url, timeout=timeout) as response:
                    data = json.loads(response.read().decode())
                    return data
            except (urllib.error.URLError, urllib.error.HTTPError, OSError, TimeoutError):
                return None
            finally:
                try:
                    pf_proc.terminate()
                    pf_proc.wait(timeout=1)
                except:
                    pf_proc.kill()
        except:
            return None
    
    def _get_cluster_metrics(self) -> dict:
        """Get key cluster health metrics from Prometheus"""
        metrics = {
            "cpu_usage": 0,
            "memory_usage": 0,
            "disk_usage": 0,
            "pod_restarts": 0,
            "alerts_firing": 0,
            "nodes_ready": 0,
            "nodes_total": 0,
            "pvcs_pending": 0,
            "errors": []
        }
        
        try:
            # Node readiness
            success, output = self._kubectl(["get", "nodes", "-o", "json"], timeout=5)
            if success:
                data = json.loads(output)
                nodes = data.get("items", [])
                metrics["nodes_total"] = len(nodes)
                ready_count = 0
                for node in nodes:
                    conditions = node.get("status", {}).get("conditions", [])
                    if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions):
                        ready_count += 1
                metrics["nodes_ready"] = ready_count
            
            # PVC status
            success, output = self._kubectl(["get", "pvc", "-A", "-o", "json"], timeout=5)
            if success:
                data = json.loads(output)
                pvcs = data.get("items", [])
                pending = sum(1 for pvc in pvcs if pvc.get("status", {}).get("phase") != "Bound")
                metrics["pvcs_pending"] = pending
            
            # Pod restarts in last hour
            success, output = self._kubectl([
                "get", "pods", "-A",
                "-o", "json"
            ], timeout=5)
            if success:
                data = json.loads(output)
                pods = data.get("items", [])
                total_restarts = 0
                for pod in pods:
                    for container in pod.get("status", {}).get("containerStatuses", []):
                        total_restarts += container.get("restartCount", 0)
                metrics["pod_restarts"] = total_restarts
            
            # Try to query prometheus for more detailed metrics (non-blocking)
            prom_data = self._query_prometheus('sum(rate(node_cpu_seconds_total[5m])) * 100', timeout=2)
            if prom_data and prom_data.get("data", {}).get("result"):
                try:
                    cpu = float(prom_data["data"]["result"][0]["value"][1])
                    metrics["cpu_usage"] = min(100, cpu)
                except:
                    pass
            
            prom_data = self._query_prometheus('sum(container_memory_usage_bytes) / sum(machine_memory_bytes) * 100', timeout=2)
            if prom_data and prom_data.get("data", {}).get("result"):
                try:
                    mem = float(prom_data["data"]["result"][0]["value"][1])
                    metrics["memory_usage"] = min(100, mem)
                except:
                    pass
                    
        except Exception as e:
            metrics["errors"].append(str(e)[:30])
        
        return metrics

    def _load_proxmox_status(self) -> dict:
        """Load proxmox VM status from JSON file"""
        proxmox_file = os.path.join(self.workdir, ".proxmox-status.json")
        if os.path.exists(proxmox_file):
            try:
                with open(proxmox_file, "r") as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError):
                pass
        return {"vms": [], "status": "idle"}

    def render_cluster_health(self) -> Table:
        """Render cluster health metrics from monitoring"""
        metrics = self._get_cluster_metrics()
        
        table = Table(title="Cluster Health", show_header=False, border_style="#444444", box=None, title_style="#000000", expand=True)
        table.add_column("Metric", ratio=2, style="#000000", no_wrap=True)
        table.add_column("Value", ratio=1, justify="right")
        table.add_column("Status", ratio=1)
        
        # Nodes
        nodes_status = "✓" if metrics["nodes_ready"] == metrics["nodes_total"] and metrics["nodes_total"] > 0 else "⚠"
        if metrics["nodes_total"] == 0:
            nodes_text = Text("pending", style="#666666")
        else:
            nodes_text = Text(f"{metrics['nodes_ready']}/{metrics['nodes_total']}", style="#000000")
        nodes_icon = Text(nodes_status, style="#33FF33" if "✓" in nodes_status else "#FFAA33")
        table.add_row("Nodes Ready", nodes_text, nodes_icon)
        
        # CPU Usage
        cpu = metrics.get("cpu_usage", 0)
        if cpu == 0:
            cpu_text = Text("N/A", style="#666666")
            cpu_icon = Text("○", style="#666666")
        elif cpu > 80:
            cpu_text = Text(f"{cpu:.1f}%", style="#FF3333")
            cpu_icon = Text("●", style="#FF3333 bold")
        elif cpu > 50:
            cpu_text = Text(f"{cpu:.1f}%", style="#FFAA33")
            cpu_icon = Text("●", style="#FFAA33 bold")
        else:
            cpu_text = Text(f"{cpu:.1f}%", style="#33FF33")
            cpu_icon = Text("●", style="#33FF33")
        table.add_row("CPU Usage", cpu_text, cpu_icon)
        
        # Memory Usage
        mem = metrics.get("memory_usage", 0)
        if mem == 0:
            mem_text = Text("N/A", style="#666666")
            mem_icon = Text("○", style="#666666")
        elif mem > 85:
            mem_text = Text(f"{mem:.1f}%", style="#FF3333")
            mem_icon = Text("●", style="#FF3333 bold")
        elif mem > 70:
            mem_text = Text(f"{mem:.1f}%", style="#FFAA33")
            mem_icon = Text("●", style="#FFAA33 bold")
        else:
            mem_text = Text(f"{mem:.1f}%", style="#33FF33")
            mem_icon = Text("●", style="#33FF33")
        table.add_row("Memory Usage", mem_text, mem_icon)
        
        # PVC Status
        pending_pvcs = metrics.get("pvcs_pending", 0)
        if pending_pvcs == 0:
            pvc_text = Text("OK", style="#33FF33")
            pvc_icon = Text("✓", style="#33FF33")
        else:
            pvc_text = Text(f"{pending_pvcs} pending", style="#FFAA33")
            pvc_icon = Text(f"⚠", style="#FFAA33")
        table.add_row("Storage PVCs", pvc_text, pvc_icon)
        
        # Pod Restarts
        restarts = metrics.get("pod_restarts", 0)
        if restarts == 0:
            restart_text = Text("0", style="#33FF33")
            restart_icon = Text("✓", style="#33FF33")
        elif restarts < 5:
            restart_text = Text(f"{restarts}", style="#FFAA33")
            restart_icon = Text("⚠", style="#FFAA33")
        else:
            restart_text = Text(f"{restarts}", style="#FF3333")
            restart_icon = Text("●", style="#FF3333")
        table.add_row("Pod Restarts", restart_text, restart_icon)
        
        # Add error info if any
        errors = metrics.get("errors", [])
        if errors:
            for error in errors[:2]:
                table.add_row(
                    Text("Error", style="#FF3333"),
                    Text(error[:20], style="#FF3333"),
                    Text("!", style="#FF3333")
                )
        
        return table

    def render_proxmox_status(self) -> Table:
        """Render Proxmox VM status"""
        data = self._load_proxmox_status()
        vms = data.get("vms", [])
        
        table = Table(title="Proxmox VMs", show_header=False, border_style="#444444", box=None, title_style="#000000", expand=True)
        table.add_column("VM", ratio=2, style="#000000", no_wrap=True, overflow="ellipsis")
        table.add_column("St", ratio=1)
        table.add_column("C", justify="right")
        table.add_column("M", justify="right")
        
        if not vms:
            table.add_row(
                Text("Waiting...", style="#666666"),
                Text("", style="#666666"),
                Text("", style="#666666"),
                Text("", style="#666666")
            )
            return table
        
        for vm in sorted(vms, key=lambda v: v.get("name", "")):
            name = vm.get("name", "?")[:18]
            status = vm.get("status", "?")
            cpu = vm.get("cpu", 0)
            mem = vm.get("mem", 0)
            uptime = vm.get("uptime", 0)
            
            # Status indicator with animation
            if status == "running":
                # Uptime check - recently started VMs get animated boot indicator
                if uptime < 60:
                    spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                    state_text = Text(f"{spinner} boot", style="#FFAA33")
                else:
                    # Pulse effect for healthy running VMs
                    phase = (self.frame // 4) % 4
                    if phase == 0:
                        state_text = Text("* UP", style="#33FF33")
                    else:
                        state_text = Text("* UP", style="#22CC22")
            elif status == "stopped":
                state_text = Text("- DOWN", style="#FF6633")
            elif status == "paused":
                state_text = Text("| PAUSE", style="#FFAA33")
            else:
                state_text = Text(status[:8], style="#666666")
            
            # CPU color based on load
            if cpu > 80:
                cpu_text = Text(f"{cpu:3}%", style="#FF3333")
            elif cpu > 50:
                cpu_text = Text(f"{cpu:3}%", style="#FFAA33")
            else:
                cpu_text = Text(f"{cpu:3}%", style="#33FF33")
            
            # Memory color based on usage
            if mem > 85:
                mem_text = Text(f"{mem:3}%", style="#FF3333")
            elif mem > 70:
                mem_text = Text(f"{mem:3}%", style="#FFAA33")
            else:
                mem_text = Text(f"{mem:3}%", style="#33FF33")
            
            table.add_row(name, state_text, cpu_text, mem_text)
        
        return table

    def render_talos_status(self) -> Table:
        """Render Talos operations status"""
        data = self._load_talos_status()
        operations = data.get("operations", [])
        
        table = Table(title="Talos", show_header=False, border_style="#444444", box=None, title_style="#000000", expand=True)
        table.add_column("Op", ratio=3, style="#000000", no_wrap=True, overflow="ellipsis")
        table.add_column("St", ratio=1)
        
        if not operations:
            table.add_row(
                Text("Waiting...", style="#666666"),
                Text("", style="#666666")
            )
            return table
        
        for op in operations[-4:]:  # Show last 4
            name = op.get("name", "?")[:18]
            action = op.get("action", "?")
            
            if action == "complete":
                action_text = Text("OK", style="#33FF33")
            elif action in ["checking", "bootstrapping", "configuring"]:
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                action_text = Text(f"{spinner}", style="#FFAA33")
            elif action == "failed":
                action_text = Text("!!", style="#FF3333 bold")
            else:
                action_text = Text(".", style="#666666")
            
            table.add_row(Text(name, style="#000000"), action_text)
        
        return table

    def render_linstor_status(self) -> Table:
        """Render LINSTOR operations status"""
        data = self._load_linstor_status()
        operations = data.get("operations", [])
        
        table = Table(title="LINSTOR", show_header=False, border_style="#444444", box=None, title_style="#000000", expand=True)
        table.add_column("Component", ratio=3, style="#000000", no_wrap=True, overflow="ellipsis")
        table.add_column("St", ratio=1)
        
        if not operations:
            table.add_row(
                Text("Waiting...", style="#666666"),
                Text("", style="#666666")
            )
            return table
        
        for op in operations[-4:]:  # Show last 4
            name = op.get("name", "?")[:20]
            action = op.get("action", "?")
            
            if action == "complete":
                action_text = Text("OK", style="#33FF33")
            elif action in ["installing", "creating", "waiting", "running"]:
                spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
                action_text = Text(f"{spinner}", style="#FFAA33")
            elif action == "failed":
                action_text = Text("!!", style="#FF3333 bold")
            else:
                action_text = Text(".", style="#666666")
            
            table.add_row(Text(name, style="#000000"), action_text)
        
        return table

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
        show_control_room = self.control_room or all_done
        
        if all_done and self.completion_frame is None:
            self.completion_frame = self.frame
        
        # Status icon
        if show_control_room:
            radar = RADAR_FRAMES[self.frame % len(RADAR_FRAMES)]
            text.append(f" {radar} ", style="bold #3366FF")
        elif any(s.status == Status.WAITING for s in self.steps):
            spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
            text.append(f" {spinner} ", style="bold #FFAA33")
        else:
            text.append(" ○ ", style="bold #666666")
        
        # Title - depends on mode
        if show_control_room:
            title = "KONTROLLRUMMET"
            text.append(title, style="bold #FFFFFF on #3366FF")
        else:
            title = "MASKINRUMMET"
            text.append(title, style="bold #000000 on #CCCCCC")
        
        text.append("  │  ", style="#444444")
        text.append_text(self.render_progress_bar())
        
        # Uptime counter - use time.time() directly to ensure fresh value
        now = time.time()
        elapsed = int(now - self.start_time)
        mins, secs = divmod(elapsed, 60)
        text.append("  ⏱ ", style="#444444")
        text.append(f"{mins:02d}:{secs:02d}", style="#000000 bold")
        
        # Animated clock - show current seconds to prove updates are happening
        clock = CLOCK_FRAMES[self.frame % len(CLOCK_FRAMES)]
        text.append(f"  {clock} ", style="#444444")
        current_time = time.strftime('%H:%M:%S')
        text.append(current_time, style="#000000")
        
        # Activity indicator
        if all_done:
            text.append("  ✓", style="#33FF33")
        elif any(s.status == Status.WAITING for s in self.steps):
            activity = DOTS_FRAMES[self.frame % len(DOTS_FRAMES)]
            text.append(f"  {activity}", style="#FFAA33")
        else:
            text.append("  ●", style="#33FF33")
        
        # Show current script step
        dashboard_status = self._load_dashboard_status()
        script_step = dashboard_status.get("current_step", "")
        if script_step and not all_done:
            # Truncate and show current operation
            step_short = script_step[:25]
            text.append("  │ ", style="#444444")
            spinner = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
            text.append(f"{spinner} ", style="#FFAA33")
            text.append(step_short, style="#000000")
        
        return text

    def render_layout(self) -> Layout:
        all_done = all(s.status == Status.SUCCESS for s in self.steps)
        
        # Control room mode always shows the monitoring view
        show_control_room = self.control_room or all_done
        
        layout = Layout()
        
        if show_control_room:
            # KONTROLLRUMMET 🎛️ - Show cluster health/monitoring
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
            
            # Show status banner
            if self.control_room and not all_done:
                # Monitoring mode but deployment not complete
                layout["celebration"].update(Panel(self.render_control_room_status(), border_style="#3366FF", style=BG_STYLE, title="🎛️  KONTROLLRUMMET", title_align="center"))
            else:
                layout["celebration"].update(Panel(self.render_celebration(), border_style="#FFD700", style=BG_STYLE, title="🎛️  KONTROLLRUMMET", title_align="center"))
            
            # Rotating health pages in main area
            layout["main"].split_row(
                Layout(name="health", ratio=2),
                Layout(name="monitoring", ratio=2)
            )
            
            # Get current page based on rotation
            page_title, page_widget = self._get_completion_page()
            
            # Show rotating pages on left (main content)
            layout["health"].update(page_widget)
            
            # Show completion stats on right
            stats_text = Text()
            elapsed = int(time.time() - self.start_time)
            mins, secs = divmod(elapsed, 60)
            stats_text.append("Deployment Stats\n", style="bold #000000")
            stats_text.append(f"\nTotal time: {mins}m {secs}s\n", style="#000000")
            stats_text.append(f"Steps completed: {len([s for s in self.steps if s.status == Status.SUCCESS])}/{len(self.steps)}\n", style="#000000")
            
            # Test summary if available
            test_results = self._load_test_results()
            if test_results and test_results.get("tests"):
                passed = test_results.get("passed", 0)
                failed = test_results.get("failed", 0)
                total = passed + failed
                stats_text.append(f"Tests: {passed}/{total} passed", style="bold #008800" if failed == 0 else "bold #CC0000")
            
            stats_text.append("\n\n(Rotating pages every 5s)", style="#888888")
            layout["monitoring"].update(Panel(stats_text, border_style="#CCCCCC", style=BG_STYLE, title="📈 Översikt"))
        else:
            # MASKINRUMMET ⚙️ - Deployment in progress
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
        
        # Main area: steps on left, operations in middle, tests on right (only when in Maskinrummet)
        if not show_control_room:
            # Dynamically build middle column based on what has data
            tf_data = self._load_tf_resources()
            talos_data = self._load_talos_status()
            linstor_data = self._load_linstor_status()
            proxmox_data = self._load_proxmox_status()
            test_results = self._load_test_results()
            
            # Check what's active/complete
            tf_active = tf_data.get("status") == "running" and tf_data.get("resources")
            tf_complete = tf_data.get("status") == "complete"
            talos_active = talos_data.get("status") == "running" and talos_data.get("operations")
            talos_complete = talos_data.get("status") == "complete"
            linstor_active = linstor_data.get("status") == "running" and linstor_data.get("operations")
            linstor_complete = linstor_data.get("status") == "complete"
            proxmox_has_vms = bool(proxmox_data.get("vms"))
            tests_have_data = test_results and test_results.get("tests")
            pvcs_active = any(s.description == "Storage Pool" and s.status == Status.DONE for s in self.steps)
            
            # Build middle panels list (only show active/incomplete)
            middle_panels = []
            
            # Check if there's any operation panel activity
            has_operation_panels = proxmox_has_vms or tf_active or talos_active or linstor_active \
                or (not tf_complete and tf_data.get("resources")) \
                or (not talos_complete and talos_data.get("operations")) \
                or (not linstor_complete and linstor_data.get("operations"))
            
            # Always show preflight when nothing else is running
            if not has_operation_panels:
                middle_panels.append(("preflight", self.render_preflight()))
            
            if proxmox_has_vms:
                middle_panels.append(("proxmox", self.render_proxmox_status()))
            if tf_active or (not tf_complete and tf_data.get("resources")):
                middle_panels.append(("terraform", self.render_tf_resources()))
            if talos_active or (not talos_complete and talos_data.get("operations")):
                middle_panels.append(("talos", self.render_talos_status()))
            if linstor_active or (not linstor_complete and linstor_data.get("operations")):
                middle_panels.append(("linstor", self.render_linstor_status()))
            
            # Build right panels (only show when has data)
            right_panels = []
            if tests_have_data:
                right_panels.append(("tests", self.render_test_cards()))
            if pvcs_active:
                right_panels.append(("pvcs", self.render_pvc_table()))
            
            # Create layout based on what we have
            if middle_panels and right_panels:
                layout["main"].split_row(Layout(name="left", ratio=2), Layout(name="middle", ratio=3), Layout(name="right", ratio=2))
            elif middle_panels:
                layout["main"].split_row(Layout(name="left", ratio=2), Layout(name="middle", ratio=4))
            elif right_panels:
                layout["main"].split_row(Layout(name="left", ratio=3), Layout(name="right", ratio=2))
            else:
                layout["main"].split_row(Layout(name="left", ratio=1))
            
            layout["left"].split_column(Layout(name="steps", ratio=4), Layout(name="details", ratio=1))
            
            # Header with fancy animation
            layout["header"].update(Panel(self.render_header_fancy(), border_style="#444444", style=BG_STYLE))
            
            # Steps panel
            layout["steps"].update(Panel(self.render_step_table(), title="Steps", border_style="#444444", style=BG_STYLE))
            layout["details"].update(Panel(self.render_checkpoint_details(), title="Active", border_style="#444444", style=BG_STYLE))
            
            # Middle panels (dynamic)
            if middle_panels:
                middle_layouts = [Layout(name=name, minimum_size=5) for name, _ in middle_panels]
                layout["middle"].split_column(*middle_layouts)
                for name, content in middle_panels:
                    layout[name].update(Panel(content, border_style="#444444", style=BG_STYLE))
            
            # Right panels (dynamic)
            if right_panels:
                right_layouts = [Layout(name=name, ratio=1) for name, _ in right_panels]
                layout["right"].split_column(*right_layouts)
                for name, content in right_panels:
                    title = "Tests" if name == "tests" else None
                    layout[name].update(Panel(content, title=title, border_style="#444444", style=BG_STYLE))
        
        # Header with fancy animation (for all states)
        layout["header"].update(Panel(self.render_header_fancy(), border_style="#444444", style=BG_STYLE))
        
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
        """Update all step statuses - runs in background thread"""
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

    def _status_worker(self):
        """Background thread that checks statuses without blocking UI"""
        while self._status_running:
            try:
                self.update_all_statuses()
            except Exception:
                pass
            # Check every 3 seconds
            for _ in range(30):  # 30 * 0.1 = 3s, but check stop flag frequently
                if not self._status_running:
                    break
                try:
                    time.sleep(0.1)
                except Exception:
                    break

    def run(self, refresh_rate: float = 2.0):
        # Start background status checker thread
        self._status_running = True
        self._status_thread = threading.Thread(target=self._status_worker, daemon=True)
        self._status_thread.start()
        
        # MAXIMUM BLINKENLIGHTS - 10 FPS for smooth animations!
        # UI loop NEVER blocks on status checks
        try:
            with Live(self.render_layout(), refresh_per_second=10, screen=True) as live:
                try:
                    while True:
                        self.frame += 1
                        # Refresh preflight (fast, no network calls)
                        try:
                            self._init_preflight()
                        except Exception:
                            pass
                        try:
                            live.update(self.render_layout())
                        except Exception as e:
                            # Log render errors but don't crash
                            pass
                        time.sleep(0.1)  # 10 FPS for MAXIMUM BLINKENLIGHTS
                except KeyboardInterrupt:
                    self._status_running = False
                    pass
        except Exception as e:
            # If Live crashes, print error and keep running simple mode
            import traceback
            print(f"Dashboard error: {e}")
            traceback.print_exc()
            self._status_running = False

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
    parser.add_argument("--control-room", "-c", action="store_true", 
                        help="Kontrollrummet: Always show monitoring view (skip deployment progress)")
    parser.add_argument("--maskinrummet", "-m", action="store_true",
                        help="Maskinrummet: Show deployment progress (default)")
    args = parser.parse_args()
    
    # Control room mode takes precedence unless explicitly in maskinrummet
    control_room = args.control_room and not args.maskinrummet
    
    dashboard = ClusterDashboard(
        workdir=args.workdir, 
        blinkenlicht=args.blinkenlicht,
        control_room=control_room
    )
    if args.once:
        dashboard.run_once()
    else:
        dashboard.run(refresh_rate=args.refresh)


if __name__ == "__main__":
    main()
