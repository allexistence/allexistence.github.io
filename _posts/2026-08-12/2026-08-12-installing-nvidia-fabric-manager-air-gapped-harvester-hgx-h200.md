---
title: "Installing NVIDIA Fabric Manager on an Air-Gapped Harvester HGX H200 Host"
date: 2026-08-12 09:00:00 +0800
categories: [GPU Infrastructure]
tags: [nvidia, fabric-manager, hgx, h200, nvswitch, harvester, kubevirt, gpu, air-gapped, vfio]
---

Getting CUDA working inside passthrough VMs on an 8× H200 SXM HGX system, where the host OS is
immutable, the environment has no internet access, and there is no NVIDIA vGPU licence.

The first half explains **what all the pieces are**, using everyday analogies. The second half is
the **procedure**, with exact commands. Read the first half once; use the second half as a runbook.

---

# Part One — Understanding the pieces

## The building and the workers

### Story

Imagine a big office building. Inside, there are **eight extremely fast workers**. Each is a genius
at maths, but only maths. Give them a huge pile of calculations and they finish in seconds.

These workers are your **eight H200 GPUs**.

You rent out office space to tenants, and each tenant gets some of these workers.

The **tenants are Virtual Machines**.

### Technical

```
        ONE PHYSICAL SERVER (the "host")
        ┌──────────────────────────────────────────┐
        │  CPU + RAM + disks                       │
        │                                          │
        │  GPU0  GPU1  GPU2  GPU3                  │   8 × H200 SXM
        │  GPU4  GPU5  GPU6  GPU7                  │
        └──────────────────────────────────────────┘
                        │
             VMs run on top of this host
        ┌───────────┐  ┌───────────┐  ┌───────────┐
        │   VM  A   │  │   VM  B   │  │   VM  C   │
        │  gets 4   │  │  gets 2   │  │  gets 2   │
        │   GPUs    │  │   GPUs    │  │   GPUs    │
        └───────────┘  └───────────┘  └───────────┘
```

---

## Two kinds of roads

### Story

The workers need to talk to each other. Worker one finishes half a calculation and hands it to
worker two.

There are **two roads** in the building.

**The normal corridor (PCIe).** Everyone uses it — the CPU, the disks, the network card. It works,
but it's busy.

**The private expressway (NVLink).** Built *only* for the workers, to hand work to each other. Many
times faster than the corridor.

For big AI training jobs, the expressway is the whole point. Without it, eight GPUs are just eight
separate GPUs instead of one giant one.

### Technical

| | PCIe | NVLink |
|---|---|---|
| Who uses it | Everything — CPU, disk, NIC, GPU | GPU-to-GPU only |
| Speed | Fast | Much faster |
| Purpose | General system bus | Peer-to-peer GPU memory access |

---

## The junction — NVSwitch

### Story

Now a problem. If every worker needs a private expressway to every other worker, eight workers means
twenty-eight separate roads. Messy, expensive, doesn't scale.

So the building has **one big junction in the middle** — like a traffic roundabout, or a telephone
exchange. Every worker's expressway leads into it. The junction decides: "traffic from worker three
heading to worker six — send it out that exit."

**That junction is NVSwitch.** On this board there are four NVSwitch chips working together as one
junction system for all eight GPUs.

### Diagram

```
   Without a junction (mesh)          With NVSwitch

   GPU ─────── GPU                     GPU   GPU   GPU   GPU
    │ ╲       ╱ │                        ╲    │     │    ╱
    │   ╲   ╱   │                         ╲   │     │   ╱
    │     ╳     │                        ┌─────────────────┐
    │   ╱   ╲   │                        │    NVSwitch     │  ← 4 chips
    │ ╱       ╲ │                        │  (the junction) │
   GPU ─────── GPU                       └─────────────────┘
                                           ╱   │     │   ╲
   Too many roads.                       GPU   GPU   GPU   GPU

                                       Every GPU reaches every
                                       other GPU through the middle.
```

### Two things that matter enormously

**The junction belongs to the whole building — not to any one tenant.** You cannot hand it to
Tenant A; if you did, Tenant A could redirect traffic belonging to Tenants B and C. NVSwitch
**stays with the host** and is never given to a VM.

**NVSwitch is not a PCIe switch.** The server also has PCIe switches (Broadcom PEX chips) — those
are junctions for the *normal corridor*. Two completely different road systems. The PCIe switches
are what determine IOMMU grouping; NVSwitch is a separate story entirely. Don't conflate them.

> **Further reading**
> - [NVIDIA NVLink and NVSwitch overview](https://www.nvidia.com/en-us/data-center/nvlink/)
> - [NVIDIA HGX Software User Guide](https://docs.nvidia.com/datacenter/tesla/hgx-software-guide/index.html)

---

## The traffic policeman — Fabric Manager

### Story

Here's the thing about that junction: **when you switch the building on, the junction is dead.**

No signs. No signals. No routing table. A worker sends traffic into it and it goes nowhere.

Someone has to walk up and program it: "this entrance connects to that exit", "traffic from GPU
three to GPU six goes this way", "check all the roads are actually working."

**That someone is Fabric Manager.** A program that runs on the host, wakes up the junction, programs
all the routes, then keeps watching for faults.

Until it has done its job, the GPUs sit there saying *"I'm not ready, the fabric isn't set up"* —
which is exactly the error seen here:

```
Fabric State : In Progress          ← "still waiting for the policeman"
Error 802: system not yet initialized
```

### Technical — its four jobs

1. Coordinate with the NVSwitch driver to initialise and train switch-to-switch NVLinks
2. Coordinate with the GPU driver to initialise and train switch-to-GPU NVLinks
3. Configure routing among NVSwitch ports
4. Monitor the fabric for NVLink and NVSwitch errors

### What it depends on

| Component | Role |
|---|---|
| NVIDIA kernel driver | Provides `nvidia-nvswitch` — the kernel-side driver that claims the NVSwitch PCI devices |
| `libnvidia-nscq` | NVSwitch Configuration and Query — the library Fabric Manager uses to talk to the switches |

The chain is strictly **driver → NSCQ → Fabric Manager**. Installing Fabric Manager alone achieves
nothing; it will start, fail to query NVSwitch device information, and exit.

> **Further reading**
> - [NVIDIA Fabric Manager User Guide](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html)
> - [Fabric Manager — full contents](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/contents.html)
> - [Fabric Manager Client (GitHub)](https://github.com/NVIDIA/Fabric-Manager-Client)

---

## Who stands where — the most important rule

### Story

The policeman must stand **at the junction**, in the building's own control room.

You cannot put him inside a rented office. From in there he can't even *see* the junction — there's
a wall in the way. He'll stand confused, unable to do anything, and give up.

**This was the original mistake here.** Fabric Manager had been installed inside the guest VM. It
failed every time:

```
request to query NVSwitch device information from NVSwitch driver ... failed
```

Of course it failed. There was no junction in that room to look at.

### Diagram — the correct split

```
┌─────────────────────────────────────────────────────────┐
│  HOST  (the building's control room)                    │
│                                                         │
│   ✅ NVIDIA kernel driver  → grabs the NVSwitch chips   │
│   ✅ libnvidia-nscq        → the "language" FM speaks   │
│   ✅ Fabric Manager        → programs the junction      │
│                                                         │
│   ┌──── NVSwitch × 4 ────┐   ┌──── GPU × 8 ────┐        │
│   │ owned by the host    │   │ handed to VMs   │        │
│   └──────────────────────┘   └────────┬────────┘        │
└───────────────────────────────────────┼─────────────────┘
                                        │ passthrough
                    ┌───────────────────┴──────────────────┐
                    │  GUEST VM                            │
                    │                                      │
                    │   ✅ NVIDIA GPU driver               │
                    │   ✅ CUDA toolkit, PyTorch           │
                    │   ❌ Fabric Manager — NEVER HERE     │
                    └──────────────────────────────────────┘
```

### How the two sides ever agree

They don't talk to each other directly. **The GPU chip itself carries the message.**

1. Host Fabric Manager programs the junction → the GPU hardware records "fabric is ready"
2. Guest starts, its GPU driver loads, reads that flag off the GPU
3. Guest reports `Fabric State: Completed` and CUDA works

This is why **a VM already running when Fabric Manager starts stays broken**. It read the flag too
early, saw "not ready", and never checks again. Power-cycle the VM.

---

## The two supported virtualisation models

| Model | GPUs | NVSwitch | Fabric Manager | Use when |
|---|---|---|---|---|
| **Full baseboard passthrough** | All 8 to one VM | Also passed through | Runs **inside the guest** | One workload needs all 8 GPUs with full NVLink |
| **Shared NVSwitch** | Passed through individually to different VMs | Stays host-owned | Runs **on the host** | GPUs split across multiple VMs |

Passing through *some* GPUs plus the NVSwitch is not valid. The switch is either entirely
host-owned, or it goes to a single VM along with every GPU on the board.

This document covers the **Shared NVSwitch** model.

> **Further reading**
> - [Full Passthrough Virtualization Model](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html#full-passthrough-virtualization-model)
> - [Shared NVSwitch Virtualization Model](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html#shared-nvswitch-virtualization-model)
> - [Bare Metal Mode](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html#bare-metal-mode)

---

## Passthrough — handing over the keys

### Story

When you give a worker to Tenant A, you don't supervise them. You hand over the key and step back.
The tenant brings their own tools and instructions, and works with that worker directly.

Building management now has **no access to that worker at all**.

### Technical

Each GPU gets bound to a driver called `vfio-pci` — a placeholder meaning "this device is rented
out, hands off."

```bash
lspci -k -s <gpu-bdf>
```
```
3D controller: NVIDIA Corporation GH100 [H200 SXM 141GB]
	Kernel driver in use: vfio-pci      ← rented out to a VM
```

That's correct and healthy. A side effect worth knowing: since the host no longer controls the GPUs,
running `nvidia-smi` on the host shows nothing. That is expected, not a fault.

---

## What was actually broken

### Story

You looked at the junction and found something odd. It wasn't misconfigured. It wasn't broken.

**Nobody had even switched it on.** No electrician had ever wired it up.

### Technical

```bash
lspci -k
```
```
xx:00.0 Bridge: NVIDIA Corporation GH100 [H100 NVSwitch]
	Subsystem: NVIDIA Corporation Device 1796
        ← NOTHING. No "Kernel driver in use" line at all.
```

Compare with everything else on the machine:

| Device | Driver | Status |
|---|---|---|
| GPUs | `vfio-pci` | correct — rented to VMs |
| NVMe disks | `nvme` | correct |
| Network cards | `mlx5_core` / `vfio-pci` | correct |
| **NVSwitch × 4** | **(none)** | ← **the bug** |

No driver on the switches → Fabric Manager can't reach them → the fabric never initialises → every
GPU in every VM waits forever.

**One missing driver. That was the whole problem.** Everything after this was the fight to install it.

---

## Why installing it was so hard

Three walls, all at once.

### Wall one — the sealed room

**Story:** a hotel room where every piece of furniture is bolted to the floor and the cupboards are
welded shut. You cannot add anything. That's how Harvester's OS is built — deliberately, so nobody
breaks the cluster by fiddling.

**Technical:**
```bash
zypper install nvidia-open
# The target filesystem is mounted as read-only.

transactional-update
# command not found

mount -o remount,rw /
# cannot remount /dev/loopN read-write, is write-protected
```

That last one is the killer. The root filesystem isn't just *flagged* read-only — it's a
**loop-mounted image file** (`/cOS/active.img`). Like a sealed CD. There's no flag to flip.

**But** one drawer *is* unlocked. From the boot line:
```
root=LABEL=COS_STATE cos-img/filename=/cOS/active.img
rd.cos.mount=LABEL=COS_OEM:/oem
rd.cos.mount=LABEL=COS_PERSISTENT:/usr/local
```
`/usr/local` is writable **and** survives reboots. That drawer became the whole solution.

### Wall two — no internet

**Story:** the building is in a submarine. No deliveries. To get anything, you send a courier to the
surface with a shopping list, and they bring back parcels.

**Technical:** air-gapped network. The courier was a separate VM with internet access.

### Wall three — no licence

**Story:** the official tool for this job needs a paid membership card. You don't have one.

**Technical:** Harvester's NVIDIA driver toolkit add-on requires a licensed **vGPU/GRID** driver from
NVIDIA's licensing portal. It's also built for vGPU sharing rather than full passthrough, and its
documentation never mentions NVSwitch or Fabric Manager. Dead end on two counts.

**Good news:** NVIDIA's datacenter driver has been **open source and free since 2022**. No licence
needed. That's the `nvidia-open` line — exactly what passthrough wants.

---

## Approaches that did not work

Documented so they aren't retried.

| Attempt | Outcome |
|---|---|
| Harvester NVIDIA driver toolkit add-on | Requires a **licensed vGPU/GRID `.run` driver**. Also vGPU-specific — no mention of NVSwitch or Fabric Manager anywhere in its docs. |
| NVIDIA Container Toolkit | Wrong layer entirely. Exposes GPUs to *containers*, and explicitly assumes a working host driver already exists. Irrelevant when GPUs go straight into VMs via VFIO. |
| `zypper install` on host | `The target filesystem is mounted as read-only.` |
| `transactional-update pkg install` | `command not found` — removed from this build. |
| `mount -o remount,rw /` | Refused; the root is a loop-mounted OS **image**, not merely a read-only mount flag. |
| `.run` driver installer | Designed for a normal writable filesystem; incompatible with an immutable root. |
| Passing NVSwitch through to a guest | Breaks the shared-fabric model; the guest gains control over routing affecting GPUs owned by other VMs. |

> **Further reading**
> - [Harvester PCI Devices add-on](https://docs.harvesterhci.io/v1.4/advanced/addons/pcidevices/)
> - [`harvester/pcidevices` controller (GitHub)](https://github.com/harvester/pcidevices)
> - [Harvester NVIDIA driver toolkit add-on](https://docs.harvesterhci.io/v1.8/advanced/addons/nvidiadrivertoolkit/)
> - [Harvester CloudInit CRD](https://docs.harvesterhci.io/v1.8/advanced/cloudinitcrd/)
> - [NVIDIA Container Toolkit install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

---

## The trick that made it work

### Story

You can't install furniture in the sealed room. **But you can carry a toolbox in and use it.**

So instead of *installing* the driver: unzip the package into the one unlocked drawer, then pick up
the driver file and plug it into the kernel directly.

The system is never modified. Nothing is installed. It just works.

### Why this is legitimate, not a hack

A kernel module doesn't care where it lives. "Installing" it just means copying it to a standard
folder so the system finds it automatically. If you already know where it is, `insmod` loads it from
any path. The standard folder is a convenience, not a requirement.

---

# Part Two — The procedure

## Target environment

| Item | Value |
|---|---|
| Host OS | SUSE Linux Micro (SLE16-based), Harvester v1.8 |
| Kernel | `6.12.0-160000.28-default` |
| Platform | AMD Genoa/Bergamo |
| GPUs | 8 × NVIDIA H200 SXM 141GB (`10de:2335`), HGX baseboard |
| NVSwitch | 4 × GH100 NVSwitch bridges |
| Model | Individual GPU passthrough to KubeVirt VMs; NVSwitch host-owned |
| Constraint | Air-gapped; no NVIDIA vGPU licence |
| Driver version used | **580.126.09** |

---

## Obtaining the packages

Performed on a separate staging VM with internet access and Docker. The staging VM ran Ubuntu, which
has no `zypper`, so a SUSE container was used to resolve dependencies properly rather than scraping
HTML directory listings.

### Story

You send your courier with a shopping list. But the shop is confusing:

- the **box** for the part is in Shop A
- the **actual part** is in Shop B — a completely different shop
- the **tools** to fit it are in Shop C

And every piece must be the **exact same model number**, or nothing fits together.

### Start a SUSE container

```bash
mkdir -p rpms
docker run -it --rm -v $(pwd)/rpms:/rpms registry.opensuse.org/opensuse/leap:16.0 bash
```

### Add the NVIDIA repositories

```bash
zypper ar -G https://download.nvidia.com/suse/sle16/ nvidia-gfx
zypper ar -G https://developer.download.nvidia.com/compute/cuda/repos/sles15/x86_64/ nvidia-cuda
zypper refresh
```

### Find what actually exists

```bash
zypper se -s nvidia-open-driver-G06-signed-kmp
zypper se -s nvidia-fabricmanager
zypper se -s libnvidia-nscq
```

**The confusing bit:** NVIDIA's own SUSE repo contains only a **36 KB meta-package** — an empty box,
a pointer. The real 9.5 MB kernel module comes from **openSUSE Leap's `repo-oss`**, the Linux
distribution's own repo. On SUSE, **SUSE builds and signs kernel modules**, not NVIDIA.

You could search NVIDIA's site forever and never find it.

```
   ┌── nvidia-gfx repo ────────┐   meta-package (empty box, 36 KB)
   │                           │   userspace tools
   └───────────────────────────┘

   ┌── nvidia-cuda repo ───────┐   nvidia-fabricmanager
   │                           │   libnvidia-nscq
   └───────────────────────────┘

   ┌── Leap repo-oss ──────────┐   ★ nvidia-open-driver...kmp-default
   │  (the DISTRO's own repo)  │     ← the actual kernel module, 9.5 MB
   └───────────────────────────┘
```

### Choosing the version — a three-way match

Every candidate had to satisfy three conditions at once: present in the driver repo, matching
Fabric Manager and NSCQ available, and kernel-ABI compatible with the host.

| Version | In driver repo? | FM + NSCQ exist? | Kernel match? | Verdict |
|---|---|---|---|---|
| 580.159.03 | yes | yes | built for `.29` — **newer than host** | risky |
| 580.126.18 | yes | **no** | `.26` | unusable |
| **580.126.09** | yes | **yes** | built for `.9` — older, same family | ✅ **chosen** |
| 580.119.02 | yes | **no** | `.7` | unusable |

**Story version of the kernel rule:** a spare part made for last year's model usually fits this
year's car, because the manufacturer keeps the mounting points the same. A part made for *next*
year's model might need a bracket that doesn't exist yet.

The host kernel was `160000.28`. The module built for `160000.9` was made earlier in the same family
→ safe. The one built for `160000.29` was made later → risky.

### Download without installing

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
- `nvidia-fabricmanager` and `libnvidia-nscq` have **no** `-580` branch suffix; modern packages carry
  the branch in the version field.

### ⚠️ The parcel you must throw away

One of the 65 downloaded files is **a whole new kernel** (`kernel-default`), newer than the host's.
The container has no kernel, so the resolver helpfully adds one.

**Story:** the courier came back with a replacement engine you never ordered. Fitting it would wreck
the car.

The platform manages its own kernel. Replacing it out-of-band risks breaking the node.

---

## Building the internal repository

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

## Loading the driver on the host

### Extract into the writable partition

```bash
mkdir -p /usr/local/nvidia && cd /usr/local/nvidia

curl -O http://<staging-vm-ip>:8000/nvidia-open-driver-G06-signed-kmp-default-580.126.09_k6.12.0_160000.9-160000.1.1.x86_64.rpm
curl -O http://<staging-vm-ip>:8000/nvidia-fabricmanager-580.126.09-1.x86_64.rpm
curl -O http://<staging-vm-ip>:8000/libnvidia-nscq-580.126.09-1.x86_64.rpm
curl -O http://<staging-vm-ip>:8000/nvidia-modprobe-580.126.09-160000.22.1.x86_64.rpm

for f in *.rpm; do rpm2cpio $f | cpio -idm; done
```

`rpm2cpio | cpio -idm` unpacks an RPM's contents into the current directory without touching the RPM
database or the system. It's just "unzip".

### Decompress and load the module

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

No symbol or version errors — the compatibility gamble paid off.

> If Secure Boot is enforced, an unenrolled module signature is rejected here. Check with
> `mokutil --sb-state`, or `dmesg | grep -i "secure boot"` if `mokutil` is absent.

### The moment of truth — both must be true

```bash
lspci -k -s <nvswitch-bdf>
lspci -k -s <gpu-bdf>
```

```
Bridge: NVIDIA Corporation GH100 [H100 NVSwitch]
	Kernel driver in use: nvidia-nvswitch     ← ✅ junction switched on

3D controller: NVIDIA Corporation GH100 [H200 SXM 141GB]
	Kernel driver in use: vfio-pci            ← ✅ tenants undisturbed
```

The new driver could have grabbed the GPUs away from the VMs. If a GPU shows `nvidia`, **stop** —
see the binding-protection note in the persistence section.

---

## Making door handles — device nodes

### Story

The junction is powered on. But there's no door into the control room — no handle, no keyhole. The
policeman can't get in. You have to fit the handles yourself.

### Technical

Linux programs reach hardware through files in `/dev`. Normally `udev` creates these automatically,
but this minimal OS has no rules for NVSwitch. And `nvidia-modprobe -c 0` won't help — it creates
*GPU* nodes, and all GPUs are vfio-bound and invisible to the NVIDIA driver.

```bash
cat /proc/devices | grep -i nvidia
ls /proc/driver/nvidia-nvswitch/devices/
```
```
507 nvidia-nvswitch                                        ← the "house number"
0000:xx:00.0  0000:xx:00.0  0000:xx:00.0  0000:xx:00.0     ← all 4 switches present
```

One door per switch, plus a master control door at minor 255:

```bash
MAJOR=$(awk '/nvidia-nvswitch/{print $1}' /proc/devices)
mknod -m 666 /dev/nvidia-nvswitchctl c $MAJOR 255
for i in 0 1 2 3; do mknod -m 666 /dev/nvidia-nvswitch$i c $MAJOR $i; done
ls -la /dev/nvidia-nvswitch*
```

> Read the major from `/proc/devices` rather than hardcoding it — dynamic majors can change between
> boots.

---

## Sending in the policeman — Fabric Manager

### Story

The policeman arrives with a map of the building, but his map has the wrong address printed on it —
it points to a control room that doesn't exist here. Correct the address, and he walks straight in.

### Technical

The stock config references absolute paths under `/usr/share` and `/var`, which don't exist here.
Copy it and repoint everything at the extracted tree.

```bash
cd /usr/local/nvidia
cp ./usr/share/nvidia/nvswitch/fabricmanager.cfg fm.cfg

sed -i 's|^TOPOLOGY_FILE_PATH=.*|TOPOLOGY_FILE_PATH=/usr/local/nvidia/usr/share/nvidia/nvswitch|' fm.cfg
sed -i 's|^LOG_FILE_NAME=.*|LOG_FILE_NAME=/usr/local/nvidia/fabricmanager.log|'                   fm.cfg
sed -i 's|^STATE_FILE_NAME=.*|STATE_FILE_NAME=/usr/local/nvidia/fabricmanager.state|'             fm.cfg
sed -i 's|^DAEMONIZE=.*|DAEMONIZE=0|'                                                             fm.cfg

export LD_LIBRARY_PATH=/usr/local/nvidia/usr/lib64:/usr/local/nvidia/usr/lib:$LD_LIBRARY_PATH
./usr/bin/nv-fabricmanager -c /usr/local/nvidia/fm.cfg
```

```
Successfully configured all the available NVSwitches to route GPU NVLink traffic.
NVLink Peer-to-Peer support will be enabled once the GPUs are successfully
registered with the NVLink fabric.
```

**That sentence is the goal of the entire exercise.**

### What's a topology file?

The junction's blueprint. Different server models are wired differently, so NVIDIA ships one
blueprint per board — the HGX H100/H200 baseboard uses `dgxh100_hgxh100_topology`. Fabric Manager
picks the right one automatically once the folder path is correct.

### FABRIC_MODE — the one lucky break

| Value | Meaning |
|---|---|
| `0` | Bare metal — FM assumes one owner for the whole baseboard |
| `1` | Shared NVSwitch — FM configures the switches, then **waits for the hypervisor to call its partition-activation API** as VMs come and go |

By the book, this setup is mode `1`: GPUs split across separate VMs is exactly what Shared NVSwitch
is for. The problem is that mode `1` only completes if the virtualisation platform actively calls
Fabric Manager's partition API — and KubeVirt has no such integration. Mode `1` would have been a
wall with nothing on the other side.

**Mode `0` worked anyway**, even with every GPU vfio-bound and invisible to the host driver. The
switches initialise, and each GPU registers with the fabric when its driver starts inside its guest.

> ⚠️ **What I tested, and what I didn't.**
> Mode `0` brought the fabric up and CUDA returned `True` — that part is reproducible.
> What I have *not* verified is isolation. Mode `1` exists specifically to partition the fabric
> between tenants; mode `0` makes no such claim, and may well leave NVLink routing open across all
> eight GPUs regardless of which VM holds them.
>
> For a single-tenant box this probably doesn't matter. For separately-owned workloads sharing one
> baseboard, check `nvidia-smi topo -m` and run a peer-to-peer bandwidth test **between GPUs in
> different VMs** before trusting it. If you've done that test, I'd like to hear the result.

---

## Verification

### On the host

```bash
systemctl status nvidia-fabricmanager-local     # active (running)
pgrep -af nv-fabricmanager                      # plain pgrep fails — name exceeds 15 chars
tail -30 /usr/local/nvidia/fabricmanager.log
journalctl -u nvidia-fabricmanager-local -n 30

lspci -k -s <nvswitch-bdf>    # nvidia-nvswitch
lspci -k -s <gpu-bdf>         # vfio-pci
```

### In the guest VM

Power-cycle the VM after Fabric Manager starts. The fabric handshake happens during GPU driver init
inside the guest and is not retried, so a VM that was already running stays broken.

```bash
nvidia-smi -q | grep -A5 Fabric
```
```
Fabric
    State   : Completed        ← was "In Progress"
    Status  : Success
    CliqueId: 0
```
```bash
python -c "import torch; print(torch.cuda.is_available())"     # True
python -c "import torch; print(torch.__version__, torch.version.cuda)"
```

### The full chain, finally connected

```
  ┌─ HOST ──────────────────────────────────────────────┐
  │                                                     │
  │  1. insmod nvidia.ko                                │
  │         ↓                                           │
  │  2. NVSwitch chips claimed by nvidia-nvswitch       │
  │         ↓                                           │
  │  3. /dev/nvidia-nvswitch* door handles created      │
  │         ↓                                           │
  │  4. Fabric Manager programs all routes  ✅          │
  │         ↓                                           │
  │  5. GPU hardware records "fabric ready"             │
  └───────────────────┬─────────────────────────────────┘
                      │  (passthrough)
  ┌─ GUEST VM ────────┴─────────────────────────────────┐
  │  6. GPU driver starts, reads the flag               │
  │  7. Fabric State: Completed                         │
  │  8. torch.cuda.is_available() → True    🎉          │
  └─────────────────────────────────────────────────────┘
```

---

## Making it survive a reboot

### Story

Everything above was written in pencil. Reboot the machine and it's rubbed out — the driver unplugs,
the door handles vanish, the policeman goes home.

The *parts* stay in the drawer (`/usr/local` survives). But somebody has to redo the assembly each
morning. So you write the instructions down and hire someone to follow them at 6 a.m. daily.

### The startup script

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

### The systemd unit

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

### The DAEMONIZE puzzle

The first attempt showed `inactive (dead)` — but the logs said it succeeded. Confusing.

**Story:** you hired a supervisor to watch the worker. The worker walked in the front door, slipped
out the back, and got on with the job through a side entrance. The supervisor saw him leave and
wrote "gone home." Work was happening; supervision wasn't.

**Technical:** Fabric Manager daemonises itself by default. With `Type=simple`, systemd watches the
original process, sees it exit, and marks the service dead — while FM runs on untracked.
`Restart=on-failure` becomes useless, because systemd can't tell when it dies.

Setting `DAEMONIZE=0` keeps it in the foreground:

```
Active: active (running)
Main PID: <pid> (nv-fabricmanage)
```

Properly supervised, restartable, and logs go to journald.

> Alternative: keep `DAEMONIZE=1` and use `Type=forking`. The `DAEMONIZE=0` route is cleaner.

### Surviving OS upgrades

On an immutable OS, `/etc` may be reset from the image at boot, and is definitely replaced on an OS
upgrade. To make the unit file reappear every boot, write it via the platform's own cloud-init
mechanism, which writes into the persistent `/oem` partition:

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

### Protecting the passthrough binding

If GPU→`vfio-pci` binding is performed at runtime by a controller pod rather than at boot, there is
now a race: the `nvidia` driver exists on the host and may claim a GPU before the controller binds
it. If `lspci -k` ever shows a GPU on `nvidia` instead of `vfio-pci` after a reboot, pin it:

```
# /etc/modprobe.d/10-vfio-gpu-pin.conf
options vfio-pci ids=10de:2335
softdep nvidia pre: vfio-pci
```

`10de:2335` is the H200 SXM PCI ID. Do **not** add the NVSwitch ID — the switches must be claimed by
`nvidia`.

---

# References

## NVIDIA — fabric, drivers, concepts

| Link | What it covers |
|---|---|
| [Fabric Manager User Guide](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html) | The primary reference. Deployment models, config options, service management, SDK, high-availability modes, troubleshooting |
| [Fabric Manager — full contents](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/contents.html) | Section-level index; jump straight to config options or a specific virtualisation model |
| [HGX Software User Guide](https://docs.nvidia.com/datacenter/tesla/hgx-software-guide/index.html) | The complete HGX software stack and install order — driver, NSCQ, FM, DCGM |
| [NVLink & NVSwitch product page](https://www.nvidia.com/en-us/data-center/nvlink/) | Conceptual overview of the interconnect and switch generations |
| [Fabric Manager Client (GitHub)](https://github.com/NVIDIA/Fabric-Manager-Client) | Partition management CLI for Shared NVSwitch mode; documents `FABRIC_MODE_RESTART` and resiliency |
| [NVIDIA open GPU kernel modules (GitHub)](https://github.com/NVIDIA/open-gpu-kernel-modules) | Source of the open driver — the same code SUSE builds into the KMP used here |
| [NVIDIA CUDA repo for SLES](https://developer.download.nvidia.com/compute/cuda/repos/sles15/x86_64/) | Where `nvidia-fabricmanager` and `libnvidia-nscq` come from |
| [NVIDIA driver repo for SLE](https://download.nvidia.com/suse/sle16/) | Userspace and meta-packages (note: **not** the kernel module) |

## Harvester / KubeVirt / immutable OS

| Link | What it covers |
|---|---|
| [Harvester PCI Devices add-on](https://docs.harvesterhci.io/v1.4/advanced/addons/pcidevices/) | Enabling passthrough, `PCIDevice` and `PCIDeviceClaim`, UI workflow |
| [Harvester CloudInit CRD](https://docs.harvesterhci.io/v1.8/advanced/cloudinitcrd/) | Persisting host config on an immutable node via `/oem` |
| [Harvester NVIDIA driver toolkit add-on](https://docs.harvesterhci.io/v1.8/advanced/addons/nvidiadrivertoolkit/) | The vGPU/GRID path — requires a licence, no NVSwitch support |
| [`harvester/pcidevices` (GitHub)](https://github.com/harvester/pcidevices) | Controller internals; how and when devices get bound to `vfio-pci` |
| [KubeVirt host devices / GPU assignment](https://kubevirt.io/user-guide/compute/host-devices/) | `permittedHostDevices`, resource names, VM spec syntax |
| [SUSE Linux Micro documentation](https://documentation.suse.com/sl-micro/6.2/) | Transactional/immutable OS model underlying the Harvester host |

## VFIO, IOMMU and passthrough background

| Link | What it covers |
|---|---|
| [Linux kernel VFIO documentation](https://docs.kernel.org/driver-api/vfio.html) | How VFIO groups, containers and device binding actually work |
| [Gentoo Wiki — GPU passthrough](https://wiki.gentoo.org/wiki/GPU_passthrough_with_virt-manager,_QEMU,_and_KVM) | Practical guide; good coverage of large-BAR GPUs and "Above 4G decoding" |
| [ArchWiki — PCI passthrough via OVMF](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF) | The most thorough community reference on IOMMU groups and ACS |
| [SUSE KMP documentation](https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-tuning-kernel.html) | Kernel Module Packages and kABI stability within a codestream |

---

# Summary

| | |
|---|---|
| **Symptom** | CUDA Error 802 in guest; `Fabric State: In Progress` |
| **Root cause** | NVSwitch bridges on the host had no kernel driver bound |
| **Why it was hard** | Immutable read-only root; no package installation possible; no vGPU licence; air-gapped; the real kernel module ships from the distro repo, not NVIDIA's |
| **Solution** | Extract RPMs into the writable persistent partition, `insmod` the module directly, create NVSwitch device nodes manually, run Fabric Manager from the extracted tree |
| **Result** | `Fabric State: Completed`; `torch.cuda.is_available() == True` |

## Lessons worth carrying forward

- Fabric Manager belongs on the **host**, never in a passthrough guest.
- Fabric Manager alone is useless — it needs the kernel driver and NSCQ, all at the **same version**.
- On SUSE, NVIDIA ships meta-packages; the **distribution** ships the signed kernel module.
- Version selection is a three-way intersection: driver repo × CUDA repo × kernel ABI.
- An immutable root blocks *installation*, not *module loading*. `insmod` takes a path.
- NVSwitch (NVLink fabric) and PCIe switches (IOMMU grouping) are different problems. Don't conflate them.

## The five-line version

1. NVSwitch is a junction that lets eight GPUs talk at full speed. It belongs to the **host**, never a VM.
2. Fabric Manager is the policeman who programs that junction. It runs on the **host**, never in a VM.
3. The junction had **no driver at all** — so Fabric Manager could never run, so every VM's CUDA was dead.
4. The OS refused all installation, so the driver was **unzipped into the one writable folder and
   loaded by hand.**
5. Fabric Manager started, the fabric came up, and CUDA returned `True`.