# OpenShift Logging with Loki: Step-by-Step Guide

**Target: OpenShift Container Platform 4.20.**  
Storage for the log store: **OpenShift Data Foundation (ODF)**.

This guide supports **hub-and-spoke** topologies: Loki can run on the same cluster that produces the logs (**internal**, e.g. on a spoke) or on another cluster (**external**, e.g. on the hub). In both cases Loki uses ODF for storage.

---

## Internal vs external: where Loki runs

| Scenario | Where Loki runs | Where logs are collected |
|----------|-----------------|---------------------------|
| **Internal** | **Spoke cluster** (same cluster that produces the logs) | Spoke. Loki and log collection run on the same spoke. |
| **External** | **Hub cluster** (a different cluster) | Spoke. Logs are collected on the spoke and forwarded to Loki on the hub. |

- **Internal Loki**: Deploy Loki (Loki Operator + LokiStack with ODF) **on the spoke**. Then deploy OpenShift Logging Operator and ClusterLogForwarder on that same spoke so logs go to the in-cluster LokiStack. Optionally add Cluster Observability Operator + UIPlugin on the spoke for **Observe → Logs** in the spoke console.
- **External Loki**: Deploy Loki (Loki Operator + LokiStack with ODF) **on the hub**. On each **spoke**, deploy only the OpenShift Logging Operator and configure ClusterLogForwarder to send logs to the hub’s Loki URL. Do **not** install the Loki Operator or LokiStack on the spoke. Use **Observe → Logs** on the hub (or Grafana) to query logs; the spoke does not host the log store.

## Quick reference: where to run what

| What to do | Internal (Loki on spoke) | External (Loki on hub) |
|------------|--------------------------|-------------------------|
| **Deploy Loki** (Operator + LokiStack + ODF) | On the **spoke** | On the **hub** |
| **Deploy OpenShift Logging Operator** | On the **spoke** | On the **spoke** |
| **Configure forwarding** (ClusterLogForwarder) | On the **spoke** → in-cluster LokiStack | On the **spoke** → hub Loki URL |
| **Deploy COO + UIPlugin** (Observe → Logs) | On the **spoke** (optional) | On the **hub** (optional); not on spoke for Loki UI |

## Requirements

- **OpenShift 4.20** on both hub and spoke (or compatible versions).  
- `oc` CLI and admin access to the cluster(s) you are configuring.  
- **ODF** on the cluster where Loki runs (hub for external, spoke for internal) for LokiStack storage (ObjectBucketClaim).  
- **External only**: The spoke must reach the hub’s Loki push endpoint (HTTPS recommended; network/ingress and optional TLS auth).

## Installation order (by scenario)

**Internal (Loki on spoke):**  
On the **spoke**: Loki Operator (namespaces, OperatorGroup, subscription) → LokiStack (ODF) → OpenShift Logging Operator → ClusterLogForwarder (to LokiStack) → Cluster Observability Operator → UIPlugin.

**External (Loki on hub):**  
1. On the **hub**: Loki Operator (namespaces, OperatorGroup, subscription) → LokiStack (ODF). Optionally COO + UIPlugin for Observe → Logs on the hub.  
2. On the **spoke**: OpenShift Logging Operator (namespace, OperatorGroup, subscription) only → ClusterLogForwarder (to hub Loki URL). Do **not** install Loki Operator or LokiStack on the spoke.

---

## Step 1: Deploy Loki on the cluster where Loki runs

**Where:**  
- **Internal**: Run on the **spoke** (the cluster that will store its own logs).  
- **External**: Run on the **hub** (the cluster that will host the central Loki).  

Do **not** run this step on the spoke when using external Loki; the spoke only forwards logs to the hub.

### 1.1 Create namespaces and OperatorGroup, then subscribe to the Loki Operator

All Loki-related resources (namespaces, **loki-operator** OperatorGroup, subscription) are in `config/01-loki-operator/`.

**Using the Makefile:**

```bash
make install-loki
```

**Using oc apply** (namespaces and OperatorGroup first, then subscription):

```bash
oc apply -f config/01-loki-operator/openshift-operators-redhat-namespace.yaml
oc apply -f config/01-loki-operator/openshift-operators-redhat-operatorgroup.yaml
oc apply -f config/01-loki-operator/openshift-logging-namespace.yaml
oc apply -f config/01-loki-operator/loki-operator-subscription.yaml
```

### 1.2 Approve the InstallPlan

Wait until an InstallPlan appears, then approve it:

```bash
# Wait for: oc get installplan -n openshift-operators-redhat | grep loki
make approve-loki
# Or: ./scripts/approve-installplan.sh openshift-operators-redhat
```

### 1.3 Verify Loki Operator

```bash
oc get csv -n openshift-operators-redhat | grep loki
oc get pods -n openshift-operators-redhat | grep loki
```

### 1.4 Deploy a LokiStack instance (ODF storage)

On the same cluster where you installed the Loki Operator (spoke for internal, hub for external), deploy the LokiStack using **ODF**:

1. Create the ObjectBucketClaim:

   ```bash
   oc apply -f config/01-loki-operator/objectbucketclaim.yaml
   ```

2. Create the Loki storage secret from the OBC:

   ```bash
   ./scripts/create-loki-odf-secret.sh
   ```

3. Deploy the LokiStack:

   ```bash
   oc apply -f config/01-loki-operator/lokistack.yaml
   ```

> **ODF object storage on the same OpenShift cluster as the Loki pods**  
> When you use **OpenShift Data Foundation (ODF)** for object storage **in the same cluster** as Loki, the S3 endpoint is often secured with the **OpenShift Service CA**. In that case you **do not need to create an extra ConfigMap** for the object-storage CA: the **`openshift-service-ca.crt`** ConfigMap (present in namespaces when they are created) can be referenced so Loki trusts the cluster’s service CA—for example via `spec.storage.tls.caName: openshift-service-ca.crt` in `lokistack.yaml`, as in this repo’s default.  
> For custom or external object-storage certificates, see Red Hat: [How to configure Loki Object Storage CA certificate in RHOCP 4](https://access.redhat.com/solutions/7006107).

Adjust `config/01-loki-operator/lokistack.yaml` if you use a different storage class or secret name. Wait until LokiStack pods are running:

```bash
oc get pods -n openshift-logging | grep loki
```

---

## Step 1b: On the spoke only (external) – forward logs to the hub’s Loki

**Where:** **Spoke cluster(s)** only. Use this when Loki runs on the hub and this cluster should send logs to it.

1. Do **not** install the Loki Operator or deploy a LokiStack on the spoke.
2. Create the log collector service account (same as internal):
   ```bash
   bash config/02-openshift-logging/serviceaccount.sh
   ```
3. Create a secret for your external Loki (TLS/client auth). Copy the example and set your URL:
   ```bash
   cp config/02-openshift-logging/secret-external-loki.example.yaml config/02-openshift-logging/secret-external-loki.yaml
   # Edit secret-external-loki.yaml and set tls.crt, tls.key, ca-bundle.crt if needed
   oc apply -f config/02-openshift-logging/secret-external-loki.yaml
   ```
4. Edit `config/02-openshift-logging/clusterlogforwarder-external-loki.yaml` and set `spec.outputs[0].url` to the **hub’s** Loki push URL (e.g. `https://<loki-gateway-on-hub>:443/loki/api/v1/push`). Use the Loki gateway route or ingress hostname on the hub. If your Loki does not require client certs, you can remove the `secret` reference or use a secret with only `ca-bundle.crt` for server verification.
5. Apply the external ClusterLogForwarder:
   - **Logging 6.x** (observability API): `oc apply -f config/02-openshift-logging/clusterlogforwarder-external-loki.yaml`
   - **Logging 5.x** (OCP 4.20 default): `oc apply -f config/02-openshift-logging/clusterlogforwarder-external-loki-logging5.yaml`

**Getting the hub’s Loki URL:** On the hub, after the LokiStack is deployed, get the Loki gateway route (e.g. `oc get route -n openshift-logging -l loki.grafana.com/name=logging-loki`) and use its HTTPS URL plus `/loki/api/v1/push` as the ClusterLogForwarder output URL. Ensure the spoke cluster can resolve and reach that hostname (network/DNS and any ingress or load balancer).

---

## Step 2: Install Red Hat OpenShift Logging Operator (on the cluster that collects logs)

**Where:** On the **spoke** in both scenarios (the cluster that produces the logs). For internal, install after Loki is ready on that same spoke. For external, the hub does not need the Logging Operator for receiving logs; only the spoke does.

### 2.1 Create namespace and OperatorGroup, then subscribe to the OpenShift Logging Operator

All Logging-related resources (namespace, **cluster-logging** OperatorGroup, subscription) are in `config/02-openshift-logging/`.

**Using the Makefile:**

```bash
make install-logging
```

**Using oc apply** (namespace and OperatorGroup first, then subscription):

```bash
oc apply -f config/02-openshift-logging/openshift-logging-namespace.yaml
oc apply -f config/02-openshift-logging/openshift-logging-operatorgroup.yaml
oc apply -f config/02-openshift-logging/openshift-logging-operator-subscription.yaml
```

For **Logging 6.x** (ClusterLogForwarder) use the v6 subscription instead:

```bash
oc apply -f config/02-openshift-logging/logging-v6-subscription.yaml
```

### 2.2 Approve the InstallPlan

```bash
# Wait for: oc get installplan -n openshift-logging
make approve-logging
# Or: ./scripts/approve-installplan.sh openshift-logging
```

### 2.3 Verify OpenShift Logging Operator

```bash
oc get csv -n openshift-logging | grep cluster-logging
oc get pods -n openshift-logging | grep cluster-logging
```

### 2.4 Configure logging to Loki

- **Internal (LokiStack on this spoke)**  
  - **Logging 6.x**: Create the `logcollector` service account, create the **Bearer token Secret** for LokiStack, then apply the ClusterLogForwarder:
    ```bash
    bash config/02-openshift-logging/serviceaccount.sh
    ./scripts/create-lokistack-bearer-secret.sh
    oc apply -f config/02-openshift-logging/clusterlogforwarder.yaml
    ```
    **LokiStack auth** uses a token from a **Secret** (`lokiStack.authentication.token.from: secret`), Secret **`loki-stack-bearer-token`**, key **`token`**. The script fills it using `oc create token logcollector` (or a legacy SA token). `spec.serviceAccount.name: logcollector` is still required for the collector pods. Re-run `create-lokistack-bearer-secret.sh` to rotate. Manual template: `config/02-openshift-logging/secret-lokistack-bearer.example.yaml`.
  - **Logging 5.x**: Use a ClusterLogging CR with `logStore.type: lokistack` and `logStore.lokistack.name: logging-loki` (see Red Hat documentation), or use the ClusterLogForwarder if your 5.x version supports it.

- **External (forward to hub’s Loki)**  
  See **Step 1b** above (ClusterLogForwarder with `type: loki` and the hub’s Loki URL).

Verify collectors/forwarder pods:

```bash
oc get pods -n openshift-logging
```

---

## Step 3: Install Cluster Observability Operator (optional, for Observe → Logs)

**Where:**  
- **Internal**: On the **spoke** (so Observe → Logs is available in the spoke console).  
- **External**: On the **hub** if you want Observe → Logs on the hub; do not install for Loki on the spoke.

The Cluster Observability Operator provides the **Logging UI plugin** (Observe → Logs in the console).

### 3.1 Subscribe to the Cluster Observability Operator

```bash
oc apply -f config/03-cluster-observability-operator/cluster-observability-operator-subscription.yaml
```

This subscription uses `installPlanApproval: Automatic`; no manual approval is required.

### 3.2 Wait for the operator

```bash
oc get csv -n openshift-operators | grep cluster-observability
oc get pods -n openshift-operators | grep cluster-observability
```

### 3.3 Enable the Logging UI plugin

Enable on the cluster where Loki runs and where you want **Observe → Logs**: the spoke for internal, the hub for external. Do not enable on the spoke when using external Loki (the spoke has no Loki to query).

```bash
oc apply -f config/03-cluster-observability-operator/uiplugin-logging.yaml
```

Ensure the `logging-loki` LokiStack name in the UIPlugin matches your LokiStack. After a few minutes, **Observe → Logs** should appear in the OpenShift web console.

---

## Makefile targets

From the repository root. **OCP 4.20.**

| Target | Description |
|--------|-------------|
| `make install-loki` | Namespaces, **loki-operator** OperatorGroup, Loki Operator subscription (cluster where Loki runs) |
| `make approve-loki` | Approve pending InstallPlans in openshift-operators-redhat |
| `make deploy-lokistack` | ODF: ObjectBucketClaim + secret script + LokiStack |
| `make install-logging` | Namespace, **cluster-logging** OperatorGroup, OpenShift Logging Operator subscription (5.x) |
| `make install-logging-v6` | Same with Logging 6.x subscription |
| `make approve-logging` | Approve pending InstallPlans in openshift-logging |
| `make deploy-logforwarder` | SA + `loki-stack-bearer-token` Secret + ClusterLogForwarder (Logging 6.x, token from Secret) |
| `make deploy-logforwarder-external` | ClusterLogForwarder to **external** Loki URL (edit URL/secret first) |
| `make install-coo` | Apply Cluster Observability Operator subscription |
| `make deploy-uiplugin` | Apply UIPlugin for Observe → Logs |
| `make verify` | Print status of operators and key resources |

**Internal (Loki on spoke):** On the spoke, run:  
`make install-loki approve-loki deploy-lokistack install-logging approve-logging deploy-logforwarder install-coo deploy-uiplugin`

**External (Loki on hub):**  
- On the **hub**: `make install-loki approve-loki deploy-lokistack` (optionally `install-coo deploy-uiplugin` for Observe → Logs on the hub).  
- On the **spoke**: `make install-logging approve-logging`, then create secret, set the hub Loki URL in `clusterlogforwarder-external-loki.yaml`, and `make deploy-logforwarder-external`.

---

## Folder structure

```
ocplog_to_loki/
├── README.md                 # This guide (OCP 4.20, internal + external Loki)
├── Makefile                  # Targets for apply and verify
├── config/
│   ├── 01-loki-operator/     # Namespaces, loki-operator OperatorGroup, subscription, LokiStack, OBC
│   ├── 02-openshift-logging/ # Namespace, cluster-logging OperatorGroup, subscription, ClusterLogForwarder, SA, secret example
│   └── 03-cluster-observability-operator/ # COO subscription, UIPlugin
└── scripts/
    ├── approve-installplan.sh           # Approve InstallPlans in a namespace
    ├── create-loki-odf-secret.sh        # Loki ODF storage secret from ObjectBucketClaim
    └── create-lokistack-bearer-secret.sh # Bearer token Secret for LokiStack (internal forwarder)
```

---

## References

- [Red Hat OpenShift Logging – Installing logging](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/)  
- [Red Hat OpenShift Cluster Observability Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/)  
- [OpenShift Loki Operator](https://catalog.redhat.com/software/containers/openshift-logging/loki-rhel9-operator/overview)
