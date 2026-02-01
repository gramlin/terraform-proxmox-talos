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
except ImportError:
    print("Installing rich library...")
    subprocess.run([sys.executable, "-m", "pip", "install", "rich", "-q"])
    from rich.console import Console
    from rich.table import Table
    from rich.live import Live
    from rich.panel import Panel
    from rich.layout import Layout
    from rich.text import Text


class Status(Enum):
    PENDING = "pending"
    RUNNING = "running"
    WAITING = "waiting"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"


STATUS_ICONS = {
    Status.PENDING: ("○", "dim"),
    Status.RUNNING: ("◉", "yellow bold"),
    Status.WAITING: ("◎", "cyan"),
    Status.SUCCESS: ("●", "green bold"),
    Status.FAILED: ("●", "red bold"),
    Status.SKIPPED: ("○", "dim"),
}

CHECKPOINT_STYLES = {
    Status.PENDING: ("□", "dim"),
    Status.RUNNING: ("▣", "yellow"),
    Status.WAITING: ("◧", "cyan"),
    Status.SUCCESS: ("■", "green"),
    Status.FAILED: ("■", "red"),
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
            Step("terraform", "Infrastructure", 
                 check_fn=self._check_terraform,
                 checkpoints=[Checkpoint("tfstate"), Checkpoint("VMs"), Checkpoint("network")]),
            Step("talos", "Talos Cluster",
                 check_fn=self._check_talos_health,
                 checkpoints=[Checkpoint("config"), Checkpoint("bootstrap"), Checkpoint("nodes")]),
            Step("cilium", "Cilium CNI",
                 check_fn=self._check_cilium,
                 checkpoints=[Checkpoint("agents"), Checkpoint("operator"), Checkpoint("envoy")]),
            Step("piraeus", "Piraeus",
                 check_fn=self._check_piraeus_operator,
                 checkpoints=[Checkpoint("CRDs"), Checkpoint("operator")]),
            Step("linstor", "LINSTOR Ctrl",
                 check_fn=self._check_linstor_controller,
                 checkpoints=[Checkpoint("pod"), Checkpoint("api")]),
            Step("satellites", "Satellites",
                 check_fn=self._check_linstor_satellites,
                 checkpoints=[Checkpoint("pods"), Checkpoint("online"), Checkpoint("lvm")]),
            Step("storage", "Storage",
                 check_fn=self._check_storage_pools,
                 checkpoints=[Checkpoint("pools"), Checkpoint("capacity")]),
            Step("sc", "StorageClass",
                 check_fn=self._check_storageclass,
                 checkpoints=[Checkpoint("created"), Checkpoint("fstype")]),
            Step("traefik", "Traefik",
                 check_fn=self._check_traefik,
                 checkpoints=[Checkpoint("deploy"), Checkpoint("LB"), Checkpoint("ready")]),
            Step("harbor", "Harbor",
                 check_fn=self._check_harbor,
                 checkpoints=[Checkpoint("PVCs"), Checkpoint("db"), Checkpoint("redis"), Checkpoint("core"), Checkpoint("reg")]),
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
        checkpoints = self.steps[2].checkpoints
        success, output = self._kubectl(["get", "pods", "-n", "kube-system", "-l", "app.kubernetes.io/name=cilium", "-o", "json"])
        if not success:
            return Status.WAITING, "Checking"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            agents = [p for p in pods if "cilium-" in p.get("metadata", {}).get("name", "") and "operator" not in p.get("metadata", {}).get("name", "") and "envoy" not in p.get("metadata", {}).get("name", "")]
            operators = [p for p in pods if "operator" in p.get("metadata", {}).get("name", "")]
            envoys = [p for p in pods if "envoy" in p.get("metadata", {}).get("name", "")]
            def running(lst): return sum(1 for p in lst if p.get("status", {}).get("phase") == "Running")
            if agents:
                checkpoints[0].status = Status.SUCCESS if running(agents) == len(agents) else Status.WAITING
                checkpoints[0].message = f"{running(agents)}/{len(agents)}"
            if operators:
                checkpoints[1].status = Status.SUCCESS if running(operators) > 0 else Status.WAITING
            if envoys:
                checkpoints[2].status = Status.SUCCESS if running(envoys) == len(envoys) else Status.WAITING
            total_running = running(pods)
            if total_running == len(pods) and len(pods) > 0:
                return Status.SUCCESS, f"{len(pods)} pods"
            return Status.WAITING, f"{total_running}/{len(pods)}"
        except:
            return Status.FAILED, "Error"

    def _check_piraeus_operator(self) -> tuple:
        checkpoints = self.steps[3].checkpoints
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
                return Status.SUCCESS, f"{running} pods"
            return Status.WAITING, "Starting"
        except:
            return Status.FAILED, "Error"

    def _check_linstor_controller(self) -> tuple:
        checkpoints = self.steps[4].checkpoints
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-l", "app.kubernetes.io/component=linstor-controller", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            for p in pods:
                phase = p.get("status", {}).get("phase")
                ready = all(cs.get("ready", False) for cs in p.get("status", {}).get("containerStatuses", []))
                if phase == "Running":
                    checkpoints[0].status = Status.SUCCESS
                if phase == "Running" and ready:
                    checkpoints[1].status = Status.SUCCESS
                    return Status.SUCCESS, "Ready"
            return Status.WAITING, "Starting"
        except:
            return Status.FAILED, "Error"

    def _check_linstor_satellites(self) -> tuple:
        checkpoints = self.steps[5].checkpoints
        success, output = self._kubectl(["get", "pods", "-n", "piraeus-datastore", "-l", "app.kubernetes.io/component=linstor-satellite", "-o", "json"])
        if success:
            try:
                data = json.loads(output)
                pods = data.get("items", [])
                running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
                if pods:
                    checkpoints[0].status = Status.SUCCESS if running == len(pods) else Status.WAITING
                    checkpoints[0].message = f"{running}/{len(pods)}"
            except:
                pass
        success, output = self._kubectl(["get", "ds", "-n", "piraeus-datastore", "lvm-init", "-o", "jsonpath={.status.numberReady}/{.status.desiredNumberScheduled}"])
        if success and output:
            checkpoints[2].status = Status.SUCCESS
            checkpoints[2].message = output
        success, output = self._linstor(["node", "list"])
        if not success:
            return Status.WAITING, "Ctrl not ready"
        online = output.count("Online")
        if online > 0:
            checkpoints[1].status = Status.SUCCESS
            checkpoints[1].message = str(online)
            return Status.SUCCESS, f"{online} online"
        return Status.WAITING, "No nodes"

    def _check_storage_pools(self) -> tuple:
        checkpoints = self.steps[6].checkpoints
        success, output = self._linstor(["storage-pool", "list"])
        if not success:
            return Status.WAITING, "Checking"
        lvm_count = output.count("LVM_THIN")
        if lvm_count > 0:
            checkpoints[0].status = Status.SUCCESS
            checkpoints[0].message = str(lvm_count)
            if "GiB" in output:
                checkpoints[1].status = Status.SUCCESS
            return Status.SUCCESS, f"{lvm_count} pools"
        return Status.WAITING, "No pools"

    def _check_storageclass(self) -> tuple:
        checkpoints = self.steps[7].checkpoints
        success, output = self._kubectl(["get", "sc", "linstor-lvm-r1", "-o", "json"])
        if not success:
            return Status.PENDING, "Not created"
        checkpoints[0].status = Status.SUCCESS
        try:
            data = json.loads(output)
            params = data.get("parameters", {})
            if "csi.storage.k8s.io/fstype" in params:
                checkpoints[1].status = Status.SUCCESS
                checkpoints[1].message = params.get("csi.storage.k8s.io/fstype")
                return Status.SUCCESS, f"fstype=ext4"
            else:
                checkpoints[1].status = Status.FAILED
                return Status.FAILED, "No fstype!"
        except:
            return Status.FAILED, "Error"

    def _check_traefik(self) -> tuple:
        checkpoints = self.steps[8].checkpoints
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
                checkpoints[1].message = svc_output
            if ready == len(pods) and ready > 0:
                checkpoints[2].status = Status.SUCCESS
                return Status.SUCCESS, f"{ready} ready"
            return Status.WAITING, f"{running}/{len(pods)}"
        except:
            return Status.FAILED, "Error"

    def _check_harbor(self) -> tuple:
        checkpoints = self.steps[9].checkpoints
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
            components = {"database": checkpoints[1], "redis": checkpoints[2], "core": checkpoints[3], "registry": checkpoints[4]}
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
            running = sum(1 for p in pods if is_ready(p))
            failed = sum(1 for p in pods if "CrashLoopBackOff" in str(p.get("status", {})))
            if running == len(pods):
                return Status.SUCCESS, f"All {len(pods)} ready"
            elif failed > 0:
                return Status.FAILED, f"{running}/{len(pods)}"
            return Status.WAITING, f"{running}/{len(pods)}"
        except:
            return Status.FAILED, "Error"

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
            icon, style = CHECKPOINT_STYLES.get(cp.status, ("○", "dim"))
            text.append(icon, style=style)
        return text

    def render_step_table(self) -> Table:
        table = Table(show_header=True, header_style="bold cyan", border_style="blue", expand=True, box=None)
        table.add_column("", width=2)
        table.add_column("Step", width=12)
        table.add_column("Checks", width=14)
        table.add_column("Status", width=18)
        for step in self.steps:
            icon, style = STATUS_ICONS[step.status]
            status_style = "green" if step.status == Status.SUCCESS else "red" if step.status == Status.FAILED else "cyan" if step.status == Status.WAITING else "dim"
            table.add_row(Text(icon, style=style), step.description, self.render_checkpoints_row(step.checkpoints), Text(step.message or "", style=status_style))
        return table

    def render_checkpoint_details(self) -> Table:
        table = Table(show_header=False, border_style="dim", expand=True, box=None)
        table.add_column("", width=12)
        table.add_column("", width=8)
        table.add_column("", width=2)
        table.add_column("", width=8)
        for step in self.steps:
            if step.status in (Status.WAITING, Status.FAILED, Status.RUNNING) or any(cp.status in (Status.WAITING, Status.FAILED) for cp in step.checkpoints):
                for cp in step.checkpoints:
                    if cp.status != Status.PENDING:
                        icon, style = CHECKPOINT_STYLES[cp.status]
                        table.add_row(Text(step.description[:12], style="cyan"), cp.name[:8], Text(icon, style=style), Text(cp.message[:8] if cp.message else "", style="dim"))
        return table

    def render_pvc_table(self) -> Table:
        table = Table(title="💾 PVCs", show_header=False, border_style="dim", box=None)
        table.add_column("", width=22)
        table.add_column("", width=6)
        table.add_column("", width=5)
        for pvc in self._get_pvcs():
            st = pvc["status"]
            style = "green" if st == "Bound" else "yellow" if st == "Pending" else "red"
            table.add_row(Text(pvc["name"][:22], style="dim"), Text(st[:6], style=style), pvc["size"][:5])
        return table

    def render_layout(self) -> Layout:
        layout = Layout()
        layout.split_column(Layout(name="header", size=3), Layout(name="main"), Layout(name="footer", size=3))
        layout["main"].split_row(Layout(name="left", ratio=3), Layout(name="right", ratio=2))
        layout["right"].split_column(Layout(name="details"), Layout(name="pvcs"))
        header = Text()
        header.append("🚀 ", style="bold")
        header.append("Talos Cluster Dashboard", style="bold white")
        header.append(f"  │  {os.path.basename(self.kubeconfig)}", style="dim")
        layout["header"].update(Panel(header, border_style="blue"))
        layout["left"].update(Panel(self.render_step_table(), title="Steps", border_style="blue"))
        layout["details"].update(Panel(self.render_checkpoint_details(), title="Active Checks", border_style="dim"))
        layout["pvcs"].update(Panel(self.render_pvc_table(), border_style="dim"))
        legend = Text()
        legend.append(f"  {time.strftime('%H:%M:%S')}  │  ", style="dim")
        legend.append("□", style="dim"); legend.append(" pending  ", style="dim")
        legend.append("◧", style="cyan"); legend.append(" wait  ", style="dim")
        legend.append("■", style="green"); legend.append(" done  ", style="dim")
        legend.append("■", style="red"); legend.append(" fail  ", style="dim")
        legend.append("│  Ctrl+C exit", style="dim")
        layout["footer"].update(Panel(legend, border_style="dim"))
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
        with Live(self.render_layout(), refresh_per_second=1, screen=True) as live:
            try:
                while True:
                    self.update_all_statuses()
                    live.update(self.render_layout())
                    time.sleep(refresh_rate)
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
