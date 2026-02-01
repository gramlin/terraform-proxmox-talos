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
    def __init__(self, workdir: str = "."):
        self.console = Console()
        self.workdir = workdir
        self.kubeconfig = self._find_kubeconfig()
        self.talosconfig = os.path.join(workdir, "talosconfig.yml")
        self.steps: List[Step] = []
        self.lock = threading.Lock()
        self.frame = 0  # Animation frame counter
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
            Step("harbor", "Harbor",
                 check_fn=self._check_harbor,
                 checkpoints=[Checkpoint("pvc"), Checkpoint("db"), Checkpoint("red"), Checkpoint("core"), Checkpoint("reg"), Checkpoint("job"), Checkpoint("tri")]),
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
                # Animated spinner for waiting checkpoints
                icon = BLINK_FRAMES[(self.frame + i) % len(BLINK_FRAMES)]
                text.append(icon, style="#0066AA bold")
            else:
                icon, style = CHECKPOINT_STYLES.get(cp.status, ("○", "#666666"))
                text.append(icon, style=style)
        return text

    def render_step_icon(self, step: Step) -> Text:
        """Render step icon with animation for waiting states"""
        if step.status == Status.WAITING:
            icon = SPINNER_FRAMES[self.frame % len(SPINNER_FRAMES)]
            return Text(icon, style="#0066AA bold")
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

    def render_layout(self) -> Layout:
        layout = Layout()
        layout.split_column(Layout(name="header", size=3), Layout(name="main"), Layout(name="footer", size=3))
        layout["main"].split_row(Layout(name="left", ratio=3), Layout(name="right", ratio=2))
        layout["right"].split_column(Layout(name="details"), Layout(name="pvcs"))
        header = Text()
        header.append("🚀 ", style="bold")
        header.append("Talos Cluster Dashboard", style=f"bold #000000 on {BG_COLOR}")
        header.append("  │  ", style="#444444")
        header.append_text(self.render_progress_bar())
        header.append(f"  │  {os.path.basename(self.kubeconfig)}", style="#444444")
        layout["header"].update(Panel(header, border_style="#444444", style=BG_STYLE))
        layout["left"].update(Panel(self.render_step_table(), title="Steps", border_style="#444444", style=BG_STYLE))
        layout["details"].update(Panel(self.render_checkpoint_details(), title="Active Checks", border_style="#444444", style=BG_STYLE))
        layout["pvcs"].update(Panel(self.render_pvc_table(), border_style="#444444", style=BG_STYLE))
        legend = Text()
        legend.append(f"  {time.strftime('%H:%M:%S')}  │  ", style="#444444")
        legend.append("□", style="#666666"); legend.append(" pending  ", style="#000000")
        legend.append("◧", style="#0066AA"); legend.append(" wait  ", style="#000000")
        legend.append("■", style="#008800"); legend.append(" done  ", style="#000000")
        legend.append("■", style="#CC0000"); legend.append(" fail  ", style="#000000")
        legend.append("│  Ctrl+C exit", style="#444444")
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
        with Live(self.render_layout(), refresh_per_second=4, screen=True) as live:
            try:
                while True:
                    self.frame += 1
                    # Only do full status check every N frames
                    if update_counter % 8 == 0:
                        self.update_all_statuses()
                    live.update(self.render_layout())
                    update_counter += 1
                    time.sleep(0.25)  # Fast refresh for smooth animation
            except KeyboardInterrupt:
                pass

    def run_once(self):
        self.update_all_statuses()
        self.console.print(self.render_step_table())
        self.console.print(self.render_pvc_table())


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Talos Cluster Dashboard")
    parser.add_argument("--workdir", "-w", default=".", help="Working directory")
    parser.add_argument("--once", "-1", action="store_true", help="Run once")
    parser.add_argument("--refresh", "-r", type=float, default=2.0, help="Refresh rate")
    args = parser.parse_args()
    dashboard = ClusterDashboard(workdir=args.workdir)
    if args.once:
        dashboard.run_once()
    else:
        dashboard.run(refresh_rate=args.refresh)


if __name__ == "__main__":
    main()
