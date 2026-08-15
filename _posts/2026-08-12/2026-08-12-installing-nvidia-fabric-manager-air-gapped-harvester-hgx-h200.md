---
title: "Installing NVIDIA Fabric Manager on an Air-Gapped Harvester HGX H200 Host"
date: 2026-08-12 09:00:00 +0800
categories: [GPU Infrastructure]
tags: [nvidia, fabric-manager, hgx, h200, nvswitch, harvester, kubevirt, gpu, air-gapped, vfio]
---

Getting CUDA working inside passthrough VMs on an 8× H200 SXM HGX system running Harvester,
where the host OS is immutable and the environment has no internet access and no NVIDIA vGPU licence.

---

## Part 1 — Background: the NVIDIA concepts that matter here

### NVLink and NVSwitch

On an HGX baseboard, the GPUs are not only connected by PCIe. They also have **NVLink** ports —
a much faster, GPU-to-GPU interconnect used for peer-to-peer memory access and collective
operations in multi-GPU training.

On small systems, NVLink is a fixed mesh of direct GPU-to-GPU cables. On an HGX baseboard, every
GPU's NVLink ports instead connect to **NVSwitch** — a crossbar switch ASIC that routes NVLink
traffic between any pair of GPUs at full bandwidth. An 8-GPU HGX board typically carries four
NVSwitch ASICs forming a single fabric domain across all eight GPUs.

Two things follow from this, and they drive everything else in this document:

1. **NVSwitch is not a per-GPU resource.** It is shared infrastructure belonging to the whole
   baseboard. It has its own routing tables and memory-mapped address space, and appears as its
   own PCI device — distinct from the GPUs.
2. **NVSwitch is not a PCIe switch.** It switches NVLink traffic. The PCIe switches on the board
   (e.g. Broadcom PEX-series) are a completely separate layer, and they are what determines your
   IOMMU groupings. Don't conflate the two — they are different fabrics with different constraints.

> **Further reading**
> - [NVIDIA NVLink and NVSwitch overview](https://www.nvidia.com/en-us/data-center/nvlink/) — what the interconnect is and why it exists
> - [NVIDIA HGX Software User Guide](https://docs.nvidia.com/datacenter/tesla/hgx-software-guide/index.html) — the full software stack for an HGX baseboard, bottom to top

### Fabric Manager

The NVSwitch ASICs do not configure themselves. **Fabric Manager (FM)** is a host-side service
that:

- discovers the NVSwitches and GPUs on the baseboard,
- loads the correct topology file for the board,
- programs the switch routing tables,
- and reports fabric health.

Until FM has run successfully, GPUs on an NVSwitch system report:

```
Fabric State  : In Progress
```

and CUDA refuses to initialise, typically with:

```
Error 802: system not yet initialized
```

FM depends on two other pieces:

| Component | Role |
|---|---|
| NVIDIA kernel driver | Provides `nvidia-nvswitch` — the kernel-side driver that claims the NVSwitch PCI devices |
| `libnvidia-nscq` | NSCQ = NVSwitch Configuration and Query. The library FM uses to talk to the switches |

So the dependency chain is strictly: **driver → NSCQ → Fabric Manager**. Installing FM alone
achieves nothing; it will start, fail to query NVSwitch device information, and exit.

FM's four documented responsibilities are worth internalising, since they explain every symptom in
this document:

1. Coordinate with the NVSwitch driver to initialise and train switch-to-switch NVLinks
2. Coordinate with the GPU driver to initialise and train switch-to-GPU NVLinks
3. Configure routing among NVSwitch ports
4. Monitor the fabric for NVLink and NVSwitch errors

> **Further reading**
> - [NVIDIA Fabric Manager User Guide](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html) — the primary reference for everything in this document
> - [Fabric Manager config options](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/contents.html) — full table of contents, including config options, startup options and the service file
> - [Fabric Manager Client (GitHub)](https://github.com/NVIDIA/Fabric-Manager-Client) — CLI for the partition-management API used in Shared NVSwitch mode

### Where each piece runs in a virtualised setup

This is the single most important design point, and getting it wrong is a very common mistake.

| Component | Host | Guest VM |
|---|---|---|
| NVIDIA kernel driver (for NVSwitch) | ✅ | — |
| Fabric Manager + NSCQ | ✅ | ❌ **never** |
| GPU driver | — | ✅ |
| CUDA toolkit, PyTorch, workloads | — | ✅ |

A guest VM that receives individual GPUs via PCI passthrough **cannot see the NVSwitch hardware**
— and should not. Running FM inside such a guest fails immediately, because there is no NVSwitch
device for it to query.

The handshake between the two sides happens through the GPU hardware itself: host-side FM programs
the fabric, and when the guest's GPU driver initialises, it reads that state from the GPU and
reports `Fabric State: Completed`.

### The two supported virtualisation models

| Model | GPUs | NVSwitch | Fabric Manager | Use when |
|---|---|---|---|---|
| **Full baseboard passthrough** | All 8 to one VM | Also passed through | Runs **inside the guest** | One workload needs all 8 GPUs with full NVLink |
| **Shared NVSwitch** | Passed through individually to different VMs | Stays host-owned | Runs **on the host** | GPUs split across multiple VMs |

Passing through *some* GPUs plus the NVSwitch is not a valid configuration. The switch is either
entirely host-owned, or it goes to a single VM along with every GPU on the board.

This document covers the **Shared NVSwitch** model.

> **Further reading**
> - [Full Passthrough Virtualization Model](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html#full-passthrough-virtualization-model) — supported VM configurations for 1, 2, 4, 8 and 16 GPUs, and their limitations
> - [Shared NVSwitch Virtualization Model](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html#shared-nvswitch-virtualization-model) — service VM design, guest lifecycle, and the partition APIs
> - [Bare Metal Mode](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html#bare-metal-mode) — the `FABRIC_MODE=0` behaviour this setup ended up relying on

---

## Part 2 — The problem

**Symptom (inside the guest VM):**

```
Error 802: system not yet initialized
torch.cuda.is_available() -> False
```

```
Fabric
    State   : In Progress
    Status  : N/A
GPU Fabric GUID : N/A
```

**First wrong turn:** Fabric Manager had been installed *inside the guest VM*, where it failed with:

```
request to query NVSwitch device information from NVSwitch driver ... failed
```

That is correct behaviour — a passthrough guest has no NVSwitch. FM was in the wrong place.

**Actual root cause**, found by inspecting the host:

```bash
lspci -k
```

```
xx:00.0 Bridge: NVIDIA Corporation GH100 [H100 NVSwitch] (rev a1)
	Subsystem: NVIDIA Corporation Device 1796
        <-- no "Kernel driver in use" line at all
```

All four NVSwitch bridges had **no kernel driver bound**. Meanwhile the GPUs were correctly bound
to `vfio-pci` for passthrough, and NVMe was on `nvme`. Only the switches were orphaned.

No driver on the switches → FM cannot initialise the fabric → every passthrough GPU waits forever
on a handshake that never comes.

---

## Part 3 — Approaches that did not work

Documented so they are not retried.

| Attempt | Outcome |
|---|---|
| Harvester `nvidia-driver-toolkit` add-on | Requires a **licensed vGPU/GRID `.run` driver** from NVIDIA's licensing portal. Also vGPU-specific — the documentation makes no mention of NVSwitch or Fabric Manager. Not applicable to full PCI passthrough. |
| NVIDIA Container Toolkit | Wrong layer entirely. It exposes GPUs to *containers* and explicitly assumes a working host driver already exists. Irrelevant when GPUs go straight into VMs via VFIO. |
| `zypper install` on host | `The target filesystem is mounted as read-only.` |
| `transactional-update pkg install` | `command not found` — removed from this build. |
| `mount -o remount,rw /` | `cannot remount /dev/loopN read-write, is write-protected` — the root is a loop-mounted OS **image**, not merely a read-only mount flag. |
| `.run` driver installer | Designed for a normal writable filesystem; incompatible with an immutable/transactional root. |
| Passing NVSwitch through to a guest | Breaks the shared-fabric model; guest gains control over routing affecting GPUs owned by other VMs. |

### Why no package can be installed

The host is SUSE Linux Micro with an elemental-style immutable root. From `/proc/cmdline`:

```
root=LABEL=COS_STATE cos-img/filename=/cOS/active.img
rd.cos.mount=LABEL=COS_OEM:/oem
rd.cos.mount=LABEL=COS_PERSISTENT:/usr/local
```

The root filesystem is a read-only image file. But note the last line: **`/usr/local` is a
writable, persistent partition.** That is the opening.

> **Further reading**
> - [Harvester PCI Devices add-on](https://docs.harvesterhci.io/v1.4/advanced/addons/pcidevices/) — how `PCIDevice` / `PCIDeviceClaim` bind host devices to `vfio-pci`
> - [`harvester/pcidevices` controller (GitHub)](https://github.com/harvester/pcidevices) — the controller doing the runtime binding, and the CRD shapes
> - [Harvester NVIDIA driver toolkit add-on](https://docs.harvesterhci.io/v1.8/advanced/addons/nvidiadrivertoolkit/) — the vGPU-oriented add-on, and why it doesn't apply here
> - [Harvester CloudInit CRD](https://docs.harvesterhci.io/v1.8/advanced/cloudinitcrd/) — the supported way to persist host-level config on an immutable OS
> - [NVIDIA Container Toolkit install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) — note its prerequisite that a host driver already exists; it is a container-layer tool, not a passthrough one

---

## Part 4 — The approach that worked

> Kernel modules do not have to be installed to be loaded. `insmod` accepts any file path.
> So: extract the RPMs into the writable partition and load the module by hand.

No package installation, no filesystem remount, no OS modification.

---

## Part 5 — Phase 1: obtaining the packages (air-gapped)

Performed on a separate staging VM that has internet access and Docker. The staging VM ran Ubuntu,
which has no `zypper`, so a SUSE container was used to resolve dependencies properly rather than
scraping HTML directory listings.

### 5.1 Start a SUSE container

```bash
mkdir -p rpms
docker run -it --rm -v $(pwd)/rpms:/rpms registry.opensuse.org/opensuse/leap:16.0 bash
```

### 5.2 Add the NVIDIA repositories

```bash
zypper ar -G https://download.nvidia.com/suse/sle16/ nvidia-gfx
zypper ar -G https://developer.download.nvidia.com/compute/cuda/repos/sles15/x86_64/ nvidia-cuda
zypper refresh
```

### 5.3 Find what actually exists

```bash
zypper se -s nvidia-open-driver-G06-signed-kmp
zypper se -s nvidia-fabricmanager
zypper se -s libnvidia-nscq
```

**Key discovery — the packages are spread across three repositories:**

| Package | Repository |
|---|---|
| `nvidia-open-driver-G06-signed-kmp-default` — *the actual kernel module* | **Leap `repo-oss`** (the distribution repo) |
| `nvidia-open-driver-G06-signed-kmp-meta` — a 36 KB pointer only | `nvidia-gfx` |
| `nvidia-fabricmanager`, `libnvidia-nscq` | `nvidia-cuda` |
| `nvidia-compute-utils-G06`, `nvidia-common-G06`, `nvidia-compute-G06` | `nvidia-gfx` / `nvidia-cuda` |

NVIDIA's SUSE repo ships **only** userspace packages and meta-packages. SUSE builds and signs the
kernel module itself, so the real binary comes from the distribution repository. Scraping NVIDIA's
repo alone will never find it.

### 5.4 Choosing a version

Two constraints must hold simultaneously:

1. The version must exist in **all** the repos involved — FM must match the driver version exactly,
   or it refuses to attach.
2. The kernel module package (KMP) must be **kABI-compatible** with the running host kernel.

The KMP filename encodes the kernel it was built against, e.g.:

```
nvidia-open-driver-G06-signed-kmp-default-<driver>_k6.12.0_<kernel-abi>-...
```

Candidate matrix (host kernel ABI was `160000.28`):

| Driver | Built against | FM + NSCQ available? | Verdict |
|---|---|---|---|
| 580.159.03 | `160000.29` — **newer than host** | yes | risky |
| 580.126.18 | `160000.26` | **no** | unusable |
| **580.126.09** | `160000.9` — older, same codestream | **yes** | **chosen** |
| 580.119.02 | `160000.7` | no | unusable |

**Rule of thumb:** within a single SUSE codestream, kernel ABI is stable, so a module built against
an *older* kernel in that stream loads fine on a newer one. The reverse direction is the risky one —
a module built against a newer kernel may reference symbols the running kernel does not have.

### 5.5 Download without installing

```bash
zypper --pkg-cache-dir /rpms install -y --download-only \
  nvidia-open-driver-G06-signed-kmp-default=580.126.09_k6.12.0_160000.9-160000.1.1 \
  nvidia-compute-utils-G06=580.126.09-1 \
  nvidia-fabricmanager=580.126.09-1 \
  libnvidia-nscq=580.126.09-1
exit
```

Syntax notes:

- The version goes after `=`. Appending it to the package name fails.
- `nvidia-fabricmanager` and `libnvidia-nscq` have **no** `-580` branch suffix; modern packages
  carry the branch in the version field.

### ⚠️ 5.6 Exclude the kernel package

The resolver pulls **`kernel-default`** (a full kernel, newer than the host's) because the container
has no kernel installed. This must **never** reach the host — the platform manages its own kernel,
and replacing it out-of-band risks breaking the node.

---

## Part 6 — Phase 2: internal repository

```bash
mkdir -p nvidia-repo
find rpms -name '*.rpm' ! -name 'kernel-default*' -exec cp {} nvidia-repo/ \;
ls nvidia-repo | grep kernel     # MUST return nothing
createrepo_c nvidia-repo/
cd nvidia-repo && python3 -m http.server 8000
```

Verify reachability from the GPU host:

```bash
curl -sI http://<staging-vm-ip>:8000/repodata/repomd.xml    # expect 200 OK
```

> A `python3 -m http.server` dies with the SSH session. Use nginx for anything long-lived.

---

## Part 7 — Phase 3: load the driver on the host

### 7.1 Extract into the writable partition

```bash
mkdir -p /usr/local/nvidia && cd /usr/local/nvidia
curl -O http://<staging-vm-ip>:8000/nvidia-open-driver-G06-signed-kmp-default-580.126.09_k6.12.0_160000.9-160000.1.1.x86_64.rpm
curl -O http://<staging-vm-ip>:8000/nvidia-fabricmanager-580.126.09-1.x86_64.rpm
curl -O http://<staging-vm-ip>:8000/libnvidia-nscq-580.126.09-1.x86_64.rpm
curl -O http://<staging-vm-ip>:8000/nvidia-modprobe-580.126.09-160000.22.1.x86_64.rpm
for f in *.rpm; do rpm2cpio $f | cpio -idm; done
```

`rpm2cpio | cpio -idm` unpacks an RPM's contents into the current directory without touching the
RPM database or the system.

### 7.2 Decompress and load the module

SUSE ships kernel modules zstd-compressed; `insmod` needs them decompressed.

```bash
cd /usr/local/nvidia/usr/lib/modules/6.12.0-160000.9-default/updates/
zstd -d nvidia.ko.zst
insmod ./nvidia.ko
dmesg | tail -20
```

Success:

```
NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  580.126.09  Release Build
```

No symbol or version errors — the kABI compatibility assumption held.

> If Secure Boot is enforced, an unenrolled module signature will be rejected here. Check with
> `mokutil --sb-state`, or `dmesg | grep -i "secure boot"` if `mokutil` is absent.

### 7.3 Verify driver binding — both conditions must hold

```bash
lspci -k -s <nvswitch-bdf>     # e.g. 09:00.0
lspci -k -s <gpu-bdf>          # e.g. 23:00.0
```

```
Bridge: NVIDIA Corporation GH100 [H100 NVSwitch]
	Kernel driver in use: nvidia-nvswitch     <-- switch claimed ✅
3D controller: NVIDIA Corporation GH100 [H200 SXM 141GB]
	Kernel driver in use: vfio-pci            <-- passthrough intact ✅
```

If a GPU shows `nvidia`, **stop**. The driver has stolen a passthrough device. See Part 10.

---

## Part 8 — Phase 4: create NVSwitch device nodes

There are no udev rules for these on a minimal host, and `nvidia-modprobe -c 0` will not help — it
creates *GPU* nodes, and all GPUs are vfio-bound and invisible to the NVIDIA driver.

Find the character device major number and confirm the switches registered:

```bash
cat /proc/devices | grep -i nvidia
ls /proc/driver/nvidia-nvswitch/devices/
```

```
507 nvidia-nvswitch
0000:09:00.0  0000:0a:00.0  0000:0b:00.0  0000:0c:00.0
```

Create the nodes — one per switch, plus a control node at minor 255:

```bash
MAJOR=$(awk '/nvidia-nvswitch/{print $1}' /proc/devices)
mknod -m 666 /dev/nvidia-nvswitchctl c $MAJOR 255
for i in 0 1 2 3; do mknod -m 666 /dev/nvidia-nvswitch$i c $MAJOR $i; done
ls -la /dev/nvidia-nvswitch*
```

> Read the major from `/proc/devices` rather than hardcoding it — dynamic majors can change
> between boots.

---

## Part 9 — Phase 5: configure and start Fabric Manager

The stock config references absolute paths under `/usr/share` and `/var`, which don't exist here.
Copy it and repoint everything at the extracted tree.

```bash
cd /usr/local/nvidia
cp ./usr/share/nvidia/nvswitch/fabricmanager.cfg fm.cfg
sed -i 's|^TOPOLOGY_FILE_PATH=.*|TOPOLOGY_FILE_PATH=/usr/local/nvidia/usr/share/nvidia/nvswitch|' fm.cfg
sed -i 's|^LOG_FILE_NAME=.*|LOG_FILE_NAME=/usr/local/nvidia/fabricmanager.log|'                   fm.cfg
sed -i 's|^STATE_FILE_NAME=.*|STATE_FILE_NAME=/usr/local/nvidia/fabricmanager.state|'             fm.cfg
sed -i 's|^DAEMONIZE=.*|DAEMONIZE=0|'                                                             fm.cfg
```

The topology directory contains a file per supported board; the HGX H100/H200 baseboard uses
`dgxh100_hgxh100_topology`. FM selects it automatically once the path is correct.

Start it:

```bash
export LD_LIBRARY_PATH=/usr/local/nvidia/usr/lib64:/usr/local/nvidia/usr/lib:$LD_LIBRARY_PATH
./usr/bin/nv-fabricmanager -c /usr/local/nvidia/fm.cfg
```

```
Successfully configured all the available NVSwitches to route GPU NVLink traffic.
NVLink Peer-to-Peer support will be enabled once the GPUs are successfully
registered with the NVLink fabric.
```

### A note on FABRIC_MODE

| Value | Meaning |
|---|---|
| `0` | Bare metal — FM expects to see the GPUs itself |
| `1` | Shared NVSwitch — FM configures switches, then waits for a hypervisor service to call its partition-activation API |

**`FABRIC_MODE=0` worked**, even though the GPUs are vfio-bound and invisible to the host driver.
The switches initialise, and each GPU registers with the fabric when its driver starts inside its
guest. Mode `1` was *not* required — which matters, because it expects a hypervisor integration
that KubeVirt-based platforms do not provide out of the box.

---

## Part 10 — Persistence

Nothing loaded at runtime survives a reboot: the module, the device nodes and the FM process all
disappear. Only the extracted files under `/usr/local` persist.

### 10.1 Startup script

```bash
cat > /usr/local/nvidia/start-fm.sh << 'EOF'
#!/bin/bash
set -e
cd /usr/local/nvidia
# 1. Load the NVIDIA kernel module (claims the NVSwitch bridges)
lsmod | grep -q '^nvidia ' || \
  insmod ./usr/lib/modules/6.12.0-160000.9-default/updates/nvidia.ko
# 2. Create NVSwitch device nodes
MAJOR=$(awk '/nvidia-nvswitch/{print $1}' /proc/devices)
[ -e /dev/nvidia-nvswitchctl ] || mknod -m 666 /dev/nvidia-nvswitchctl c $MAJOR 255
for i in 0 1 2 3; do
  [ -e /dev/nvidia-nvswitch$i ] || mknod -m 666 /dev/nvidia-nvswitch$i c $MAJOR $i
done
# 3. Start Fabric Manager
export LD_LIBRARY_PATH=/usr/local/nvidia/usr/lib64:/usr/local/nvidia/usr/lib:$LD_LIBRARY_PATH
exec ./usr/bin/nv-fabricmanager -c /usr/local/nvidia/fm.cfg
EOF
chmod +x /usr/local/nvidia/start-fm.sh
```

### 10.2 systemd unit

```bash
cat > /etc/systemd/system/nvidia-fabricmanager-local.service << 'EOF'
[Unit]
Description=NVIDIA Fabric Manager (local extracted)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/nvidia/start-fm.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now nvidia-fabricmanager-local
systemctl status nvidia-fabricmanager-local
```

> **`DAEMONIZE=0` is required** (set in Part 9). FM daemonises by default, which makes a
> `Type=simple` unit report `inactive (dead)` moments after start — systemd sees the parent exit
> while FM keeps running untracked, and `Restart=on-failure` becomes useless. With `DAEMONIZE=0`
> the service shows `active (running)` and logs land in journald.
> (Alternative: keep `DAEMONIZE=1` and use `Type=forking`.)

### 10.3 Surviving OS upgrades

On an immutable OS, `/etc` may be reset from the image at boot, and is definitely replaced on an OS
upgrade. To make the unit file reappear every boot, write it via the platform's own cloud-init
mechanism (which writes into the persistent `/oem` partition) rather than relying on the manual
`/etc` write:

```yaml
apiVersion: node.harvesterhci.io/v1beta1
kind: CloudInit
metadata:
  name: nvidia-fabricmanager
spec:
  matchSelector:
    kubernetes.io/hostname: <gpu-node-name>
  filename: 90-nvidia-fabricmanager.yaml
  contents: |
    stages:
      boot:
        - name: "install fabric manager service"
          files:
            - path: /etc/systemd/system/nvidia-fabricmanager-local.service
              permissions: 0644
              content: |
                [Unit]
                Description=NVIDIA Fabric Manager (local extracted)
                After=network.target
                [Service]
                Type=simple
                ExecStart=/usr/local/nvidia/start-fm.sh
                Restart=on-failure
                RestartSec=10
                [Install]
                WantedBy=multi-user.target
          commands:
            - systemctl daemon-reload
            - systemctl enable --now nvidia-fabricmanager-local.service
  paused: false
```

Verify it landed without rebooting:

```bash
kubectl get cloudinit
ls -la /oem/                       # the rendered file should appear here
elemental run-stage boot           # re-execute the boot stage now
systemctl status nvidia-fabricmanager-local
```

### 10.4 Protecting the passthrough binding

If GPU→`vfio-pci` binding is performed at runtime by a controller pod rather than at boot, there is
now a race: the `nvidia` driver exists on the host and may claim a GPU before the controller binds
it. If `lspci -k` ever shows a GPU on `nvidia` instead of `vfio-pci` after a reboot, pin it:

```
# /etc/modprobe.d/10-vfio-gpu-pin.conf
options vfio-pci ids=10de:2335
softdep nvidia pre: vfio-pci
```

`10de:2335` is the H200 SXM PCI ID. Do **not** add the NVSwitch ID here — the switches must be
claimed by `nvidia`.

---

## Part 11 — Verification

### Host

```bash
systemctl status nvidia-fabricmanager-local     # active (running)
pgrep -af nv-fabricmanager                      # note: plain pgrep fails, name > 15 chars
tail -30 /usr/local/nvidia/fabricmanager.log
journalctl -u nvidia-fabricmanager-local -n 30
lspci -k -s <nvswitch-bdf>    # nvidia-nvswitch
lspci -k -s <gpu-bdf>         # vfio-pci
```

### Guest VM

Power-cycle the VM after FM starts. The fabric handshake happens during GPU driver init inside the
guest and is not retried, so a VM that was already running will stay broken.

```bash
nvidia-smi -q | grep -A5 Fabric
```

```
Fabric
    State   : Completed
    Status  : Success
    CliqueId: 0
```

```bash
python -c "import torch; print(torch.cuda.is_available())"     # True
python -c "import torch; print(torch.__version__, torch.version.cuda)"
```

---

## Part 12 — References

### NVIDIA — fabric, drivers, concepts

| Link | What it covers |
|---|---|
| [Fabric Manager User Guide](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html) | The primary reference. Deployment models, config options, service management, SDK, high-availability modes, troubleshooting |
| [Fabric Manager — full contents](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/contents.html) | Section-level index; useful for jumping straight to config options or a specific virtualisation model |
| [HGX Software User Guide](https://docs.nvidia.com/datacenter/tesla/hgx-software-guide/index.html) | The complete HGX software stack and install order — driver, NSCQ, FM, DCGM |
| [NVLink & NVSwitch product page](https://www.nvidia.com/en-us/data-center/nvlink/) | Conceptual overview of the interconnect and switch generations |
| [Fabric Manager Client (GitHub)](https://github.com/NVIDIA/Fabric-Manager-Client) | Partition management CLI for Shared NVSwitch mode; also documents `FABRIC_MODE_RESTART` and resiliency |
| [NVIDIA open GPU kernel modules (GitHub)](https://github.com/NVIDIA/open-gpu-kernel-modules) | Source of the open driver — the same code SUSE builds into the KMP used here |
| [NVIDIA CUDA repo for SLES](https://developer.download.nvidia.com/compute/cuda/repos/sles15/x86_64/) | Where `nvidia-fabricmanager` and `libnvidia-nscq` come from |
| [NVIDIA driver repo for SLE](https://download.nvidia.com/suse/sle16/) | Userspace and meta-packages (note: **not** the kernel module) |

### Harvester / KubeVirt / immutable OS

| Link | What it covers |
|---|---|
| [Harvester PCI Devices add-on](https://docs.harvesterhci.io/v1.4/advanced/addons/pcidevices/) | Enabling passthrough, `PCIDevice` and `PCIDeviceClaim`, UI workflow |
| [Harvester CloudInit CRD](https://docs.harvesterhci.io/v1.8/advanced/cloudinitcrd/) | Persisting host config on an immutable node via `/oem` |
| [Harvester NVIDIA driver toolkit add-on](https://docs.harvesterhci.io/v1.8/advanced/addons/nvidiadrivertoolkit/) | The vGPU/GRID path — requires a licence, no NVSwitch support |
| [`harvester/pcidevices` (GitHub)](https://github.com/harvester/pcidevices) | Controller internals; how and when devices get bound to `vfio-pci` |
| [KubeVirt host devices / GPU assignment](https://kubevirt.io/user-guide/compute/host-devices/) | `permittedHostDevices`, resource names, VM spec syntax |
| [SUSE Linux Micro documentation](https://documentation.suse.com/sl-micro/6.2/) | Transactional/immutable OS model underlying the Harvester host |

### VFIO, IOMMU and passthrough background

| Link | What it covers |
|---|---|
| [Linux kernel VFIO documentation](https://docs.kernel.org/driver-api/vfio.html) | How VFIO groups, containers and device binding actually work |
| [Gentoo Wiki — GPU passthrough](https://wiki.gentoo.org/wiki/GPU_passthrough_with_virt-manager,_QEMU,_and_KVM) | Practical guide; good coverage of large-BAR GPUs and "Above 4G decoding" |
| [ArchWiki — PCI passthrough via OVMF](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF) | The most thorough community reference on IOMMU groups and ACS |
| [SUSE KMP documentation](https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-tuning-kernel.html) | Kernel Module Packages and kABI stability within a codestream |

---

## Part 13 — Summary

| | |
|---|---|
| **Symptom** | CUDA Error 802 in guest; `Fabric State: In Progress` |
| **Root cause** | NVSwitch bridges on the host had no kernel driver bound |
| **Why it was hard** | Immutable read-only root; no package installation possible; no vGPU licence; air-gapped; the real kernel module ships from the distro repo, not NVIDIA's |
| **Solution** | Extract RPMs into the writable persistent partition, `insmod` the module directly, create NVSwitch device nodes manually, run FM from the extracted tree |
| **Result** | `Fabric State: Completed`; `torch.cuda.is_available() == True` |

### Lessons worth carrying forward

- Fabric Manager belongs on the **host**, never in a passthrough guest.
- FM alone is useless — it needs the kernel driver and NSCQ, all at the **same version**.
- On SUSE, NVIDIA ships meta-packages; the **distribution** ships the signed kernel module.
- Version selection is a three-way intersection: driver repo × CUDA repo × kernel ABI.
- An immutable root blocks *installation*, not *module loading*. `insmod` takes a path.
- NVSwitch (NVLink fabric) and PCIe switches (IOMMU grouping) are different problems. Don't conflate them.
