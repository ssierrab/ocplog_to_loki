# OpenShift Logging with Loki: Step-by-Step Guide

**Target:** OpenShift Container Platform **4.20**.  
**Log store storage:** **OpenShift Data Foundation (ODF)**.

This repository holds manifests and scripts to deploy **Loki** and **Red Hat OpenShift Logging**, optionally with **Cluster Observability Operator** for **Observe → Logs** in the console.

---

## Contents

1. [Overview](#overview) — internal vs external Loki, requirements  
2. [Repository layout](#repository-layout) — what each directory is for  
3. [Scenario A: Internal Loki](#scenario-a-internal-loki-loki-on-the-same-cluster-as-log-collection) — Loki and logging on one cluster (e.g. a spoke)  
4. [Scenario B: External Loki](#scenario-b-external-loki-loki-on-hub-logs-from-spoke) — Loki on hub, collection on spoke  
5. [Makefile](#makefile-targets) — automation summary  
6. [References](#references)

---

## Overview

| Scenario | Where Loki runs | Where logs are collected |
|----------|-----------------|---------------------------|
| **Internal** | Same cluster as the workloads (e.g. **spoke**) | That same cluster |
| **External** | **Hub** (central cluster) | **Spoke(s)** forward to the hub |

**Internal:** Install Loki + LokiStack (ODF) and OpenShift Logging on the **same** cluster. Forward to the in-cluster LokiStack. Optionally install COO + UIPlugin there for **Observe → Logs**.

**External:** Install Loki + LokiStack on the **hub** only. On each **spoke**, install OpenShift Logging only and forward to the hub’s Loki URL using a **Bearer token** Secret (`to-loki-secret`). Do **not** install Loki on the spoke. Use **Observe → Logs** on the **hub** (or Grafana).

### Requirements

- OpenShift **4.20** (or compatible), `oc`, cluster-admin where you apply manifests.  
- **ODF** on the cluster that runs **Loki** (ObjectBucketClaim for LokiStack).  
- **External:** spokes must reach the hub Loki gateway (DNS, TLS, network).

---

## Repository layout

Paths are relative to the repo root. Names **`01-*` / `02-*` / `03-*`** only sort apply order; the descriptions below are what matters.

| Path | Purpose |
|------|---------|
| **`config/01-loki-operator/`** | Namespaces and **loki-operator** OperatorGroup, Loki subscription, ODF ObjectBucketClaim, LokiStack, scripts for Loki storage secrets |
| **`config/02-openshift-logging/`** | **openshift-logging** namespace, **cluster-logging** OperatorGroup, Logging subscription(s), ClusterLogForwarder (internal + external), collector **serviceaccount.sh**, **hub-remote-log-writer/** (hub SA + RBAC + optional long-lived token Secret), Secret examples (`to-loki-secret`, `secret-lokistack-bearer`, optional mTLS example) |
| **`config/03-cluster-observability-operator/`** | Cluster Observability Operator subscription and Logging **UIPlugin** |
| **`scripts/`** | `approve-installplan.sh`, `create-loki-odf-secret.sh`, `create-lokistack-bearer-secret.sh` |

---

## Scenario A: Internal Loki (Loki on the same cluster as log collection)

Run everything below on **one** cluster (e.g. a spoke). **Makefile** shortcuts are in [Makefile targets](#makefile-targets).

### A.1 Install Loki Operator and LokiStack (ODF)

Manifests live under **`config/01-loki-operator/`**.

```bash
make install-loki
# or apply the YAMLs in order: redhat namespace → OperatorGroup → openshift-logging namespace → subscription
```

Approve the InstallPlan, then verify:

```bash
make approve-loki
oc get csv -n openshift-operators-redhat | grep loki
```

Deploy LokiStack with ODF:

```bash
oc apply -f config/01-loki-operator/objectbucketclaim.yaml
./scripts/create-loki-odf-secret.sh
oc apply -f config/01-loki-operator/lokistack.yaml
```

> **ODF + Service CA:** With ODF object storage on the **same** cluster as Loki, you can use **`openshift-service-ca.crt`** for `spec.storage.tls.caName` in **`lokistack.yaml`** (no extra CA ConfigMap). See [Red Hat KB 7006107](https://access.redhat.com/solutions/7006107) for custom CAs.

Wait for Loki pods: `oc get pods -n openshift-logging | grep loki`

### A.2 Install OpenShift Logging Operator

Manifests live under **`config/02-openshift-logging/`**.

```bash
make install-logging          # Logging 5.x subscription
# For Logging 6.x instead:
# oc apply -f config/02-openshift-logging/openshift-logging-namespace.yaml
# oc apply -f config/02-openshift-logging/openshift-logging-operatorgroup.yaml
# oc apply -f config/02-openshift-logging/logging-v6-subscription.yaml
make approve-logging
oc get csv -n openshift-logging | grep cluster-logging
```

### A.3 Forward logs to the in-cluster LokiStack

**Logging 6.x** (`observability.openshift.io` ClusterLogForwarder):

1. Collector service account and RBAC: `bash config/02-openshift-logging/serviceaccount.sh`
2. Secret **`loki-stack-bearer-token`** (key **`token`**): `./scripts/create-lokistack-bearer-secret.sh`  
   (Or use **`config/02-openshift-logging/secret-lokistack-bearer.example.yaml`**.)

3. Apply the forwarder:

   ```bash
   oc apply -f config/02-openshift-logging/clusterlogforwarder.yaml
   ```

The manifest uses **`lokiStack.authentication.token.from: secret`** pointing at **`loki-stack-bearer-token`**. Re-run **`create-lokistack-bearer-secret.sh`** to rotate the token.

**Logging 5.x:** Use a **ClusterLogging** CR with **`logStore.type: lokistack`** and your LokiStack name, per Red Hat documentation for your version.

Verify: `oc get pods -n openshift-logging`

### A.4 Observe → Logs in the console (optional)

On **this same cluster**:

```bash
oc apply -f config/03-cluster-observability-operator/cluster-observability-operator-subscription.yaml
oc apply -f config/03-cluster-observability-operator/uiplugin-logging.yaml
```

Match the UIPlugin **`lokiStack.name`** to your LokiStack (e.g. **`logging-loki`**).

---

## Scenario B: External Loki (Loki on hub, logs from spoke)

Two clusters: complete **hub** steps first (Loki + token trust), then **spoke** steps (Logging + forwarder). No prior section needs to be “looked up”—each block is self-contained.

### B.1 Hub — Loki Operator and LokiStack

Use **`config/01-loki-operator/`** with `oc` **logged into the hub** (same flow as [A.1](#a1-install-loki-operator-and-lokistack-odf)):

```bash
make install-loki && make approve-loki && make deploy-lokistack
```

Confirm Loki is running: `oc get pods -n openshift-logging | grep loki`

### B.2 Hub — Identity for remote spokes (`remote-log-writer`)

Still on the **hub**, apply **`config/02-openshift-logging/hub-remote-log-writer/`** (ordered **`01` → `02` → `03`**):

```bash
make apply-hub-remote-log-writer
```

This creates ServiceAccount **`remote-log-writer`** and ClusterRoleBindings to **`cluster-logging-write-*`** roles (push through the LokiStack gateway).

**Get a JWT** for that SA (pick one method):

| Method | What to do |
|--------|------------|
| **Long-lived (Secret on hub)** | After apply, read token: `oc wait --for=jsonpath='{.data.token}' secret/remote-log-writer-token -n openshift-logging --timeout=120s` then `oc get secret remote-log-writer-token -n openshift-logging -o jsonpath='{.data.token}' \| base64 -d` |
| **Short-lived** | `oc create token remote-log-writer -n openshift-logging --duration=24h` (adjust `--duration`; rotate **`to-loki-secret`** on spokes before expiry) |

Copy the **raw JWT only** (no `Bearer ` prefix) for the spoke Secret.

**Hub gateway CA for spokes:** Save PEM to a file (e.g. **`hub-service-ca.crt`**):

```bash
oc get configmap openshift-service-ca.crt -n openshift-logging \
  -o jsonpath='{.data.service-ca\.crt}' > hub-service-ca.crt
```

If that ConfigMap is missing, use the CA that signed your route/ingress for the Loki gateway.

**Hub push URL** for spokes: `https://<loki-gateway-host>/loki/api/v1/push` (from routes/services in **`openshift-logging`** on the hub).

### B.3 Spoke — OpenShift Logging Operator only

With `oc` **logged into the spoke**. Do **not** install Loki here.

```bash
make install-logging    # or 6.x subscription files as in A.2
make approve-logging
```

### B.4 Spoke — Secret `to-loki-secret` and ClusterLogForwarder to the hub

1. Collector RBAC on the spoke:

   ```bash
   bash config/02-openshift-logging/serviceaccount.sh
   ```

2. Create **`to-loki-secret`** in **`openshift-logging`** with:
   - **`token`**: raw JWT from [B.2](#b2-hub--identity-for-remote-spokes-remote-log-writer)
   - **`ca-bundle.crt`**: same PEM as **`hub-service-ca.crt`**

   ```bash
   oc create secret generic to-loki-secret -n openshift-logging \
     --from-literal=token="<PASTE_RAW_JWT>" \
     --from-file=ca-bundle.crt=hub-service-ca.crt
   ```

   Template: **`config/02-openshift-logging/to-loki-secret.example.yaml`**.

3. Edit **`config/02-openshift-logging/clusterlogforwarder-external-loki.yaml`**: set **`spec.outputs[0].loki.url`** to the hub push URL. The file already references **`to-loki-secret`** for token and TLS CA.

4. Apply:

   ```bash
   oc apply -f config/02-openshift-logging/clusterlogforwarder-external-loki.yaml
   ```

   **Logging 5.x:** use **`clusterlogforwarder-external-loki-logging5.yaml`** instead if your cluster uses **`logging.openshift.io`**.

Optional: `make deploy-logforwarder-external` applies **`serviceaccount.sh`** and the Logging 6.x external forwarder (ensure **`to-loki-secret`** and URL are already set).

### B.5 Hub — Observe → Logs (optional)

On the **hub** (where Loki runs):

```bash
oc apply -f config/03-cluster-observability-operator/cluster-observability-operator-subscription.yaml
oc apply -f config/03-cluster-observability-operator/uiplugin-logging.yaml
```

Do **not** enable this UIPlugin on the spoke for Loki query; the spoke has no Loki.

---

## Makefile targets

Run from the repo root with `oc` pointing at the right cluster.

| Target | Use on | Description |
|--------|--------|-------------|
| `install-loki` | Hub or spoke (internal) | Loki namespaces, OperatorGroup, subscription |
| `approve-loki` | Same | Approve InstallPlans in **openshift-operators-redhat** |
| `deploy-lokistack` | Same | OBC + Loki ODF secret script + LokiStack |
| `install-logging` / `install-logging-v6` | Spoke (both scenarios) | Logging namespace, OperatorGroup, subscription |
| `approve-logging` | Spoke | Approve InstallPlans in **openshift-logging** |
| `deploy-logforwarder` | Spoke (internal) | SA + **`create-lokistack-bearer-secret.sh`** + internal ClusterLogForwarder |
| `apply-hub-remote-log-writer` | Hub (external) | **`remote-log-writer`** + RBAC + long-lived token Secret manifest |
| `deploy-logforwarder-external` | Spoke (external) | SA + external ClusterLogForwarder (create **`to-loki-secret`** first) |
| `install-coo` / `deploy-uiplugin` | Cluster with Loki UI need | COO + UIPlugin |
| `verify` | Any | Quick status |

**One-line sequences**

- **Internal (spoke):**  
  `make install-loki approve-loki deploy-lokistack install-logging approve-logging deploy-logforwarder install-coo deploy-uiplugin`

- **External:**  
  - **Hub:** `make install-loki approve-loki deploy-lokistack apply-hub-remote-log-writer` → then token + CA + URL per [B.2](#b2-hub--identity-for-remote-spokes-remote-log-writer); optional `install-coo deploy-uiplugin`  
  - **Spoke:** `make install-logging approve-logging` → complete [B.4](#b4-spoke--secret-to-loki-secret-and-clusterlogforwarder-to-the-hub) → `make deploy-logforwarder-external` if desired

---

## References

- [Red Hat OpenShift Logging – Installing logging](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/)  
- [Red Hat OpenShift Cluster Observability Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/)  
- [OpenShift Loki Operator](https://catalog.redhat.com/software/containers/openshift-logging/loki-rhel9-operator/overview)
