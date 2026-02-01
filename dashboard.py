#!/usr/bin/env python3
"""
Talos Cluster Deployment Dashboard
A visual TUI for monitoring cluster deployment progress.
"""

import subprocess
import json
import time
import sys
import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Callable
from concurrent.futures import ThreadPoolExecutor
import threading

try:
    from rich.console import Console
    from rich.table import Table
    from rich.live import Live
    from rich.panel import Panel
    from rich.layout import Layout
    from rich.text import Text
    from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TaskProgressColumn
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
    from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TaskProgressColumn
    from rich.style import Style


class Status(Enum):
    PENDING = "pending"
    RUNNING = "running"
    WAITING = "waiting"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"


STATUS_STYLES = {
    Status.PENDING: ("⏸", "dim"),
    Status.RUNNING: ("▶", "yellow bold"),
    Status.WAITING: ("⏳", "cyan"),
    Status.SUCCESS: ("✓", "green bold"),
    Status.FAILED: ("✗", "red bold"),
    Status.SKIPPED: ("○", "dim"),
}


@dataclass
class Step:
    name: str
    description: str
    status: Status = Status.PENDING
    message: str = ""
    substeps: list = field(default_factory=list)
    check_fn: Optional[Callable] = None


class ClusterDashboard:
    def __init__(self, workdir: str = "."):
        self.console = Console()
        self.workdir = workdir
        self.kubeconfig = os.path.join(workdir, "kubeconfig")
        self.steps: list[Step] = []
        self.current_step = 0
        self.lock = threading.Lock()
        self._init_steps()

    def _init_steps(self):
        """Initialize deployment steps"""
        self.steps = [
            Step("terraform", "Infrastructure Provisioning", 
                 substeps=["VMs created", "Network configured", "Talos bootstrapped"]),
            Step("talos_health", "Talos Cluster Health",
                 check_fn=self._check_talos_health),
            Step("cilium", "Cilium CNI",
                 check_fn=self._check_cilium),
            Step("piraeus_operator", "Piraeus Operator",
                 check_fn=self._check_piraeus_operator),
            Step("linstor_controller", "LINSTOR Controller",
                 check_fn=self._check_linstor_controller),
            Step("linstor_satellites", "LINSTOR Satellites",
                 check_fn=self._check_linstor_satellites),
            Step("storage_pools", "Storage Pools",
                 check_fn=self._check_storage_pools),
            Step("storageclass", "StorageClass",
                 check_fn=self._check_storageclass),
            Step("traefik", "Traefik Ingress",
                 check_fn=self._check_traefik),
            Step("harbor", "Harbor Registry",
                 check_fn=self._check_harbor),
        ]

    def _kubectl(self, args: list[str], timeout: int = 10) -> tuple[bool, str]:
        """Run kubectl command and return (success, output)"""
        try:
            env = os.environ.copy()
            env["KUBECONFIG"] = self.kubeconfig
            result = subprocess.run(
                ["kubectl"] + args,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env
            )
            return result.returncode == 0, result.stdout + result.stderr
        except Exception as e:
            return False, str(e)

    def _linstor(self, args: list[str]) -> tuple[bool, str]:
        """Run linstor command via kubectl exec"""
        success, output = self._kubectl([
            "-n", "piraeus-datastore", "exec", "deploy/linstor-controller", "--",
            "linstor"] + args, timeout=30)
        return success, output

    # Check functions for each step
    def _check_talos_health(self) -> tuple[Status, str]:
        success, output = self._kubectl(["get", "nodes", "-o", "json"])
        if not success:
            return Status.FAILED, "Cannot connect to cluster"
        try:
            data = json.loads(output)
            nodes = data.get("items", [])
            ready = sum(1 for n in nodes if any(
                c["type"] == "Ready" and c["status"] == "True" 
                for c in n.get("status", {}).get("conditions", [])))
            total = len(nodes)
            if ready == total and total > 0:
                return Status.SUCCESS, f"{ready}/{total} nodes ready"
            return Status.WAITING, f"{ready}/{total} nodes ready"
        except:
            return Status.FAILED, "Parse error"

    def _check_cilium(self) -> tuple[Status, str]:
        success, output = self._kubectl([
            "get", "pods", "-n", "kube-system", "-l", "app.kubernetes.io/name=cilium",
            "-o", "json"])
        if not success:
            return Status.WAITING, "Checking..."
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
            total = len(pods)
            if running == total and total > 0:
                return Status.SUCCESS, f"{running}/{total} pods running"
            return Status.WAITING, f"{running}/{total} pods running"
        except:
            return Status.FAILED, "Parse error"

    def _check_piraeus_operator(self) -> tuple[Status, str]:
        success, output = self._kubectl([
            "get", "pods", "-n", "piraeus-datastore", 
            "-l", "app.kubernetes.io/name=piraeus-operator",
            "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
            if running > 0:
                return Status.SUCCESS, f"Running ({running} pods)"
            return Status.WAITING, "Starting..."
        except:
            return Status.FAILED, "Parse error"

    def _check_linstor_controller(self) -> tuple[Status, str]:
        success, output = self._kubectl([
            "get", "pods", "-n", "piraeus-datastore",
            "-l", "app.kubernetes.io/component=linstor-controller",
            "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            for p in pods:
                phase = p.get("status", {}).get("phase")
                ready = all(
                    cs.get("ready", False) 
                    for cs in p.get("status", {}).get("containerStatuses", []))
                if phase == "Running" and ready:
                    return Status.SUCCESS, "Ready"
            return Status.WAITING, "Starting..."
        except:
            return Status.FAILED, "Parse error"

    def _check_linstor_satellites(self) -> tuple[Status, str]:
        success, output = self._linstor(["node", "list"])
        if not success:
            return Status.WAITING, "Controller not ready"
        online = output.count("Online")
        if online > 0:
            return Status.SUCCESS, f"{online} nodes online"
        return Status.WAITING, "No nodes online"

    def _check_storage_pools(self) -> tuple[Status, str]:
        success, output = self._linstor(["storage-pool", "list"])
        if not success:
            return Status.WAITING, "Checking..."
        # Count LVM_THIN pools (not DISKLESS)
        lvm_count = output.count("LVM_THIN")
        if lvm_count > 0:
            return Status.SUCCESS, f"{lvm_count} LVM pools"
        return Status.WAITING, "No LVM pools"

    def _check_storageclass(self) -> tuple[Status, str]:
        success, output = self._kubectl(["get", "sc", "linstor-lvm-r1", "-o", "json"])
        if not success:
            return Status.PENDING, "Not created"
        try:
            data = json.loads(output)
            params = data.get("parameters", {})
            has_fstype = "csi.storage.k8s.io/fstype" in params
            if has_fstype:
                return Status.SUCCESS, f"Ready (fstype: {params.get('csi.storage.k8s.io/fstype')})"
            return Status.FAILED, "Missing fstype!"
        except:
            return Status.FAILED, "Parse error"

    def _check_traefik(self) -> tuple[Status, str]:
        success, output = self._kubectl([
            "get", "pods", "-n", "traefik", "-l", "app.kubernetes.io/name=traefik",
            "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            if not pods:
                return Status.PENDING, "Not installed"
            running = sum(1 for p in pods if p.get("status", {}).get("phase") == "Running")
            ready = sum(1 for p in pods if all(
                cs.get("ready", False) 
                for cs in p.get("status", {}).get("containerStatuses", [])))
            if ready == len(pods) and ready > 0:
                return Status.SUCCESS, f"{ready} replicas ready"
            return Status.WAITING, f"{running}/{len(pods)} running"
        except:
            return Status.FAILED, "Parse error"

    def _check_harbor(self) -> tuple[Status, str]:
        success, output = self._kubectl(["get", "pods", "-n", "harbor", "-o", "json"])
        if not success:
            return Status.PENDING, "Not installed"
        try:
            data = json.loads(output)
            pods = data.get("items", [])
            if not pods:
                return Status.PENDING, "Not installed"
            
            running = 0
            pending = 0
            failed = 0
            total = len(pods)
            
            pod_status = []
            for p in pods:
                name = p.get("metadata", {}).get("name", "unknown")
                # Shorten name
                short_name = name.split("-")[1] if "-" in name else name
                phase = p.get("status", {}).get("phase", "Unknown")
                
                ready = all(
                    cs.get("ready", False) 
                    for cs in p.get("status", {}).get("containerStatuses", []))
                
                if phase == "Running" and ready:
                    running += 1
                elif phase == "Pending":
                    pending += 1
                elif phase == "Failed" or "CrashLoopBackOff" in str(p.get("status", {})):
                    failed += 1
            
            if running == total:
                return Status.SUCCESS, f"All {total} pods ready"
            elif failed > 0:
                return Status.FAILED, f"{running}/{total} ready, {failed} failed"
            else:
                return Status.WAITING, f"{running}/{total} ready, {pending} pending"
        except Exception as e:
            return Status.FAILED, f"Error: {e}"

    def _check_harbor_pvcs(self) -> list[dict]:
        """Get Harbor PVC status"""
        success, output = self._kubectl(["get", "pvc", "-n", "harbor", "-o", "json"])
        if not success:
            return []
        try:
            data = json.loads(output)
            pvcs = []
            for item in data.get("items", []):
                pvcs.append({
                    "name": item.get("metadata", {}).get("name", "unknown"),
                    "status": item.get("status", {}).get("phase", "Unknown"),
                    "capacity": item.get("status", {}).get("capacity", {}).get("storage", "-"),
                })
            return pvcs
        except:
            return []

    def render_status_icon(self, status: Status) -> Text:
        """Render a status icon with appropriate styling"""
        icon, style = STATUS_STYLES[status]
        return Text(icon, style=style)

    def render_step_table(self) -> Table:
        """Render the main steps table"""
        table = Table(
            title="🚀 Talos Cluster Deployment",
            show_header=True,
            header_style="bold magenta",
            border_style="blue",
            expand=True
        )
        
        table.add_column("", width=3, justify="center")
        table.add_column("Step", style="cyan", width=20)
        table.add_column("Status", width=40)
        table.add_column("", width=3, justify="center")

        for step in self.steps:
            icon = self.render_status_icon(step.status)
            status_text = Text(step.message or step.status.value)
            
            if step.status == Status.SUCCESS:
                status_text.stylize("green")
            elif step.status == Status.FAILED:
                status_text.stylize("red")
            elif step.status == Status.WAITING:
                status_text.stylize("cyan")
            elif step.status == Status.RUNNING:
                status_text.stylize("yellow")
            
            # Checkmark for completed
            check = Text("✓", style="green") if step.status == Status.SUCCESS else Text("")
            
            table.add_row(icon, step.description, status_text, check)

        return table

    def render_pvc_table(self) -> Table:
        """Render Harbor PVC status table"""
        table = Table(
            title="💾 Harbor PVCs",
            show_header=True,
            header_style="bold cyan",
            border_style="dim",
        )
        
        table.add_column("PVC", style="dim")
        table.add_column("Status", width=10)
        table.add_column("Size")

        pvcs = self._check_harbor_pvcs()
        for pvc in pvcs:
            status = pvc["status"]
            style = "green" if status == "Bound" else "yellow" if status == "Pending" else "red"
            table.add_row(
                pvc["name"][:30],
                Text(status, style=style),
                pvc["capacity"]
            )

        return table

    def render_layout(self) -> Layout:
        """Render the full dashboard layout"""
        layout = Layout()
        
        layout.split_column(
            Layout(name="header", size=3),
            Layout(name="main"),
            Layout(name="footer", size=3),
        )
        
        layout["main"].split_row(
            Layout(name="steps", ratio=2),
            Layout(name="details", ratio=1),
        )
        
        # Header
        layout["header"].update(
            Panel(
                Text("Talos + Proxmox Cluster Dashboard", style="bold white", justify="center"),
                style="blue"
            )
        )
        
        # Steps table
        layout["steps"].update(Panel(self.render_step_table(), border_style="blue"))
        
        # Details (PVCs)
        layout["details"].update(Panel(self.render_pvc_table(), border_style="dim"))
        
        # Footer
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        layout["footer"].update(
            Panel(
                Text(f"Last update: {timestamp} | Press Ctrl+C to exit", justify="center", style="dim"),
                border_style="dim"
            )
        )
        
        return layout

    def update_all_statuses(self):
        """Update status for all steps that have check functions"""
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
                        step.message = str(e)

    def run(self, refresh_rate: float = 2.0):
        """Run the dashboard with live updates"""
        with Live(self.render_layout(), refresh_per_second=1, screen=True) as live:
            try:
                while True:
                    self.update_all_statuses()
                    live.update(self.render_layout())
                    time.sleep(refresh_rate)
            except KeyboardInterrupt:
                pass

    def run_once(self):
        """Run a single status check and print"""
        self.update_all_statuses()
        self.console.print(self.render_step_table())
        self.console.print(self.render_pvc_table())


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Talos Cluster Deployment Dashboard")
    parser.add_argument("--workdir", "-w", default=".", help="Working directory with kubeconfig")
    parser.add_argument("--once", "-1", action="store_true", help="Run once and exit")
    parser.add_argument("--refresh", "-r", type=float, default=2.0, help="Refresh rate in seconds")
    args = parser.parse_args()

    dashboard = ClusterDashboard(workdir=args.workdir)
    
    if args.once:
        dashboard.run_once()
    else:
        dashboard.run(refresh_rate=args.refresh)


if __name__ == "__main__":
    main()
