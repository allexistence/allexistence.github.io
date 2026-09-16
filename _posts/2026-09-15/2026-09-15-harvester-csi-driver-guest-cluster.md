---
title: "Installing the Harvester CSI Driver in a Guest Cluster"
date: 2026-09-15 09:00:00 +0800
categories: [Kubernetes, CSI Driver]
tags: [harvester, csi, kubernetes, storage, longhorn, kubevirt, rke2]
---

## Why We Need a CSI Driver

Kubernetes workloads need persistent storage that survives pod restarts and reschedules, but a guest cluster running on Harvester VMs has no native way to ask the underlying hypervisor for a disk. Without a CSI driver, storage has to be provisioned manually on the Harvester side and mapped into the VM by hand — there's no `PersistentVolumeClaim`, no dynamic provisioning, and no lifecycle management from inside Kubernetes.

The Container Storage Interface (CSI) standardizes how a Kubernetes cluster talks to a storage backend. A CSI driver is what turns "I want 5Gi of storage" (a PVC) into an actual attached, formatted, mounted volume — without an operator ever touching the storage layer directly. For clusters running as guest VMs on Harvester, that storage backend is Harvester's own built-in Longhorn.

## About the Harvester CSI Driver

The Harvester CSI driver lets a guest Kubernetes cluster (RKE2/K3s running on Harvester VMs) provision PersistentVolumes backed by Harvester's built-in Longhorn storage. When a PVC is created in the guest cluster, the driver calls the Harvester API to create a Longhorn volume and hot-plugs it into the VM running the pod, as a virtio block device.

```
Guest Pod → PVC → Harvester CSI Driver (guest) → Harvester API → Longhorn → node disks
```

Because the volume is hot-plugged as a virtio block device, guest nodes never need to speak iSCSI — that happens entirely on the Harvester host side. `open-iscsi` inside the guest is only relevant if you're running Longhorn *inside* the guest cluster itself, which is a completely different setup. The one exception is **RWX** volumes, which are backed by NFS and do require an `nfs-client` package on guest nodes.

Some prerequisites worth calling out before going further:

- Guest cluster nodes must be Harvester VMs, all in the **same Harvester namespace** — guest VMs spread across namespaces aren't supported
- Guest nodes need network access to the Harvester API (VIP, port 6443)
- `kubectl`, `jq`, and `curl` are needed wherever the config generator script is run
- Access to the Harvester host cluster's kubeconfig (typically `/etc/rancher/rke2/rke2.yaml` on a management node)

## Steps to Install

### 1. Prepare guest nodes

Nothing storage-specific is required for RWO volumes. Only install the NFS client if you plan to use RWX volumes:

```bash
# Only if you plan to use RWX (NFS-backed) volumes
sudo zypper install -y nfs-client
```

### 2. Generate the cloud-provider config on Harvester

Run the generator script on a Harvester management node. It creates a ServiceAccount + RBAC on the Harvester host cluster and prints a kubeconfig the CSI driver will use.

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

curl -LO https://raw.githubusercontent.com/harvester/harvester-csi-driver/master/deploy/generate_addon_csi.sh
chmod +x generate_addon_csi.sh

# <serviceaccount name> = usually your guest cluster name
# <namespace>           = Harvester namespace containing the guest VMs
./generate_addon_csi.sh <serviceaccount name> <namespace> RKE2
# For K3s:  ./generate_addon_csi.sh <serviceaccount name> <namespace> k3s
```

The output has two parts: a **cloud-config** kubeconfig pointing at the Harvester VIP with a token, and a **cloud-init user data** block that places that kubeconfig at `/var/lib/rancher/rke2/etc/config-files/cloud-provider-config` on each guest node.

### 3. Deliver the config to the guest nodes

**Rancher-managed cluster:** paste the cloud-init user data into **Machine Pools > Show Advanced > User Data**, set Cloud Provider to *Default - RKE2 Embedded* or *External*, then create the cluster.

**Existing / manual cluster:** copy the cloud-config kubeconfig to every node:

```bash
sudo mkdir -p /var/lib/rancher/rke2/etc/config-files
sudo vi /var/lib/rancher/rke2/etc/config-files/cloud-provider-config   # paste cloud-config
sudo chmod 0644 /var/lib/rancher/rke2/etc/config-files/cloud-provider-config
```

### 4. Install the CSI driver in the guest cluster

Via Rancher: **Apps > Charts > Harvester CSI Driver** (keep the default cloud-config path).

Via Helm:

```bash
export KUBECONFIG=/path/to/guest-cluster.kubeconfig

helm repo add harvester https://charts.harvesterhci.io/
helm repo update
helm install harvester-csi-driver harvester/harvester-csi-driver \
  --namespace kube-system
```

### 5. Verify

```bash
kubectl get pods -n kube-system | grep harvester-csi
# harvester-csi-driver-controllers-...   Running
# harvester-csi-driver-... (one per node) Running

kubectl get storageclass
# harvester (default)   driver.harvesterhci.io   Delete   Immediate   true
```

## Creating a Test PVC

With the driver running and the `harvester` StorageClass showing up as default, a simple PVC confirms the whole chain — API call, Longhorn volume creation, and hot-plug — is working end to end.

```yaml
# test-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-harvester-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: harvester
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f test-pvc.yaml
kubectl get pvc test-harvester-pvc -w     # should reach Bound
```

Once bound, the backing volume shows up under **Volumes** in the Harvester UI — a useful sanity check that the guest-side PVC and the Harvester-side Longhorn volume are actually the same object.

> **Note:** a `harvester` RWO volume can only be hot-plugged into **one VM at a time**, so it can only ever back a single pod at once. Workloads that need multiple replicas each writing to their own volume, or replicas spread across nodes, need a different pattern (StatefulSet with `volumeClaimTemplates`, or an RWX StorageClass) — outside the scope of this basic test.

## Harvester CSI Driver Components

| Component | What It Does |
|---|---|
| **CSI Controller** (`harvester-csi-driver-controller`) | Runs as a Deployment in the guest cluster's `kube-system` namespace. Watches for PVC create/delete/resize/snapshot events and calls the Harvester API to create, delete, resize, or snapshot the corresponding Longhorn volume. |
| **CSI Node Plugin** (`harvester-csi-driver` DaemonSet) | Runs one pod per guest node. Handles the node-local half of the CSI spec — staging and mounting the hot-plugged virtio block device into the pod's filesystem once the controller has attached it. |
| **cloud-provider-config credential** | A scoped kubeconfig/token generated on the Harvester side (via `generate_addon_csi.sh`), pointing at the Harvester VIP. This is how the CSI components authenticate back to the Harvester API from inside the guest cluster. |
| **`harvester` StorageClass** | The default StorageClass installed with the driver, provisioner `driver.harvesterhci.io`. PVCs referencing it trigger dynamic Longhorn volume creation on Harvester. Additional StorageClasses can point at non-default Harvester storage via the `hostStorageClass` parameter. |
| **CSI Snapshot Controller + CRDs** | Required for volume snapshot support (driver ≥ 0.1.25). Bundled with RKE2 by default; needs to be installed separately on non-RKE2 guest distros before upgrading the driver. |

### Version Compatibility

| CSI Driver | Harvester | Notes |
| ---------- | --------- | ----- |
| 0.1.20     | v1.4+     | RWX support. **Do not use with Harvester ≤ v1.3.2** (volumes get stuck) |
| 0.1.24     | v1.6+     | Online resizing, third-party storage |
| 0.1.25     | v1.7+     | Volume snapshots (needs CSI snapshot controller; bundled in RKE2) |
| 0.1.28     | v1.8+     | Volume backups to Harvester backup target |

### A Few Gotchas

- **256 disks per VM max** (a KubeVirt limit, including root/cloud-init disks) — spread PVC-heavy workloads across nodes or attaches will fail with `Max Disk Limit (256) Exceeded`.
- Guest VMs spanning multiple Harvester namespaces are not supported.
- RWX volumes need `nfs-client` on every node plus a second NIC on the Harvester storage/RWX network.

## References

- Harvester docs – CSI Driver: [https://docs.harvesterhci.io/v1.8/rancher/csi-driver/](https://docs.harvesterhci.io/v1.8/rancher/csi-driver/)
- Chart source: [https://github.com/harvester/charts/tree/master/charts/harvester-csi-driver](https://github.com/harvester/charts/tree/master/charts/harvester-csi-driver)