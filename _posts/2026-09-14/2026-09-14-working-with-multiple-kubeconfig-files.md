---
title: "Working with Multiple Kubeconfig Files"
date: 2026-09-14 09:00:00 +0800
categories: [Kubernetes]
tags: [kubernetes, kubectl, kubeconfig, multi-cluster]
---

## Working with Multiple Kubeconfig Files

When you work with more than one Kubernetes cluster, each cluster usually hands you its own kubeconfig file. Rather than swapping files in and out of `~/.kube/config`, you can merge them into a single config and switch between clusters with `kubectl config use-context`.

### 1. Back up your existing config

Always keep a copy of your current config before merging, so you can roll back if something goes wrong.

```bash
cp ~/.kube/config ~/.kube/config.bak
```

### 2. Point `KUBECONFIG` at all the files

`kubectl` reads every file listed in the `KUBECONFIG` environment variable (colon-separated on Linux/macOS) and treats them as one combined config for the current shell session.

```bash
export KUBECONFIG=~/.kube/config:/path/to/cluster1-config:/path/to/cluster2-config
```

At this point `kubectl` can already see all contexts. If you're happy managing the variable per shell, you can stop here.

### 3. Flatten and save into one file

To make the merge permanent, write the combined view out as a single file and replace your default config with it. `--flatten` inlines any certificate files referenced by path so the result is self-contained.

```bash
kubectl config view --flatten > ~/.kube/merged-config
mv ~/.kube/merged-config ~/.kube/config
```

Then unset `KUBECONFIG` (or open a new shell) so `kubectl` falls back to `~/.kube/config`:

```bash
unset KUBECONFIG
```

### 4. List available contexts

Shows every context in the merged config. The `*` marks the currently active one.

```bash
kubectl config get-contexts
```

### 5. Switch between clusters

```bash
kubectl config use-context <context-name>
```

All subsequent `kubectl` commands run against the selected cluster.

### Tips

- Rename contexts to something memorable: `kubectl config rename-context <old> <new>`
- After renaming, an old context with the original name may still show up in `get-contexts`. This happens when two files in `KUBECONFIG` define a context with the same name — only the first was visible before, and the rename touched just that one. If it's a duplicate, delete it: `kubectl config delete-context <old>`
- Check which cluster you're on before running anything destructive: `kubectl config current-context`
- If two files define the same context/cluster/user name, the first file in `KUBECONFIG` wins.