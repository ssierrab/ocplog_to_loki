# OpenShift Logging with Loki: Step-by-Step Guide

**Target: OpenShift Container Platform 4.20.**  
Storage for the log store: **OpenShift Data Foundation (ODF)**.

This repository provides a **step-by-step guide** and **config files** to install and configure:

1. **Loki Operator** – manages the Loki log store (internal deployment only)  
2. **Red Hat OpenShift Logging Operator** – manages log collection and forwarding  
3. **Cluster Observability Operator** – provides the logging UI plugin in the OpenShift console (Observe → Logs)

## Internal vs external Loki

You can use Loki in two ways; both can use ODF for log storage:

| Mode | Description | When to use |
|------|-------------|-------------|
| **Internal** | Loki runs **on the cluster** as a LokiStack. Logs are stored in **ODF** (ObjectBucketClaim + S3-compatible backend). | You want a fully on-cluster log store with Observe → Logs in the console. |
| **External** | Loki runs **outside the cluster**. OpenShift Logging forwards logs to its URL. The external Loki instance can use ODF or any other storage. | You already have a central Loki (or want to use an external ODF-backed Loki). |

- **Internal path**: Prerequisites → Loki Operator → LokiStack (ODF) → OpenShift Logging Operator → ClusterLogForwarder to LokiStack → Cluster Observability Operator → UIPlugin.  
- **External path**: Prerequisites → OpenShift Logging Operator only → ClusterLogForwarder to external Loki URL (no Loki Operator or LokiStack on cluster). The **Observe → Logs** console plugin may not integrate with an external Loki; use the external Loki UI or Grafana instead.

## Requirements

- **OpenShift 4.20** with admin access  
- `oc` CLI installed and logged in  
- **Internal**: Loki and OpenShift Logging operators must use compatible major/minor versions; **ODF** for LokiStack storage (ObjectBucketClaim).  
- **External**: A reachable Loki push endpoint (HTTPS recommended) and optional TLS/auth secret.  

## Installation order

**Internal (Loki on cluster with ODF):**  
Prerequisites → Loki Operator → LokiStack (ODF) → OpenShift Logging Operator → ClusterLogForwarder (to LokiStack) → Cluster Observability Operator → UIPlugin.

**External (forward to external Loki):**  
Prerequisites → OpenShift Logging Operator → ClusterLogForwarder (to external URL). No Loki Operator or UIPlugin required.

---

## Step 1: Prerequisites

Create namespaces and operator groups used by Loki and OpenShift Logging.

### Using the Makefile

```bash
make prereqs
```

### Using oc apply

```bash
oc apply -f config/00-prerequisites/
```

Verify:

```bash
oc get ns openshift-operators-redhat openshift-logging
oc get operatorgroup -n openshift-operators-redhat
oc get operatorgroup -n openshift-logging
```

---

## Step 2: Install Loki Operator (internal path only)

Skip this step if you are using **external** Loki.

### 2.1 Subscribe to the Loki Operator

```bash
oc apply -f config/01-loki-operator/loki-operator-subscription.yaml
```

### 2.2 Approve the InstallPlan

Wait until an InstallPlan appears, then approve it:

```bash
# Wait for: oc get installplan -n openshift-operators-redhat | grep loki
make approve-loki
# Or: ./scripts/approve-installplan.sh openshift-operators-redhat
```

### 2.3 Verify Loki Operator

```bash
oc get csv -n openshift-operators-redhat | grep loki
oc get pods -n openshift-operators-redhat | grep loki
```

### 2.4 Deploy a LokiStack instance (internal + ODF)

For **internal** Loki with **ODF** storage:

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

Adjust `config/01-loki-operator/lokistack.yaml` if you use a different storage class or secret name. Wait until LokiStack pods are running:

```bash
oc get pods -n openshift-logging | grep loki
```

---

## Step 2b: External Loki (no Loki Operator)

If you use **external** Loki:

1. Do **not** install the Loki Operator or deploy a LokiStack.
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
4. Edit `config/02-openshift-logging/clusterlogforwarder-external-loki.yaml` and set `spec.outputs[0].url` to your external Loki push URL (e.g. `https://loki.example.com:3100/loki/api/v1/push`). If your Loki does not require client certs, you can remove the `secret` reference or use a secret with only `ca-bundle.crt` for server verification.
5. Apply the external ClusterLogForwarder:
   - **Logging 6.x** (observability API): `oc apply -f config/02-openshift-logging/clusterlogforwarder-external-loki.yaml`
   - **Logging 5.x** (OCP 4.20 default): `oc apply -f config/02-openshift-logging/clusterlogforwarder-external-loki-logging5.yaml`

---

## Step 3: Install Red Hat OpenShift Logging Operator

Install **after** the Loki Operator (and optionally after the LokiStack is ready).

### 3.1 Subscribe to the OpenShift Logging Operator

- **Logging 5.x** (ClusterLogging CR):

  ```bash
  oc apply -f config/02-openshift-logging/openshift-logging-operator-subscription.yaml
  ```

- **Logging 6.x** (ClusterLogForwarder CR):

  ```bash
  oc apply -f config/02-openshift-logging/logging-v6-subscription.yaml
  ```

### 3.2 Approve the InstallPlan

```bash
# Wait for: oc get installplan -n openshift-logging
make approve-logging
# Or: ./scripts/approve-installplan.sh openshift-logging
```

### 3.3 Verify OpenShift Logging Operator

```bash
oc get csv -n openshift-logging | grep cluster-logging
oc get pods -n openshift-logging | grep cluster-logging
```

### 3.4 Configure logging to Loki

- **Internal (LokiStack on cluster)**  
  - **Logging 6.x**: Create the log collector service account, then apply the ClusterLogForwarder to the in-cluster LokiStack:
    ```bash
    bash config/02-openshift-logging/serviceaccount.sh
    oc apply -f config/02-openshift-logging/clusterlogforwarder.yaml
    ```
  - **Logging 5.x**: Use a ClusterLogging CR with `logStore.type: lokistack` and `logStore.lokistack.name: logging-loki` (see Red Hat documentation), or use the ClusterLogForwarder if your 5.x version supports it.

- **External Loki**  
  See **Step 2b** above (ClusterLogForwarder with `type: loki` and your URL).

Verify collectors/forwarder pods:

```bash
oc get pods -n openshift-logging
```

---

## Step 4: Install Cluster Observability Operator

The Cluster Observability Operator provides the **Logging UI plugin** (Observe → Logs in the console).

### 4.1 Subscribe to the Cluster Observability Operator

```bash
oc apply -f config/03-cluster-observability-operator/cluster-observability-operator-subscription.yaml
```

This subscription uses `installPlanApproval: Automatic`; no manual approval is required.

### 4.2 Wait for the operator

```bash
oc get csv -n openshift-operators | grep cluster-observability
oc get pods -n openshift-operators | grep cluster-observability
```

### 4.3 Enable the Logging UI plugin (internal path only)

Only for **internal** LokiStack. Not used for external Loki.

```bash
oc apply -f config/03-cluster-observability-operator/uiplugin-logging.yaml
```

Ensure the `logging-loki` LokiStack name in the UIPlugin matches your LokiStack. After a few minutes, **Observe → Logs** should appear in the OpenShift web console.

---

## Makefile targets

From the repository root. **OCP 4.20.**

| Target | Description |
|--------|-------------|
| `make prereqs` | Apply prerequisite namespaces and operator groups |
| `make install-loki` | Apply Loki Operator subscription (internal only) |
| `make approve-loki` | Approve pending InstallPlans in openshift-operators-redhat |
| `make deploy-lokistack` | ODF: ObjectBucketClaim + secret script + LokiStack (internal) |
| `make install-logging` | Apply OpenShift Logging Operator subscription (5.x, OCP 4.20) |
| `make approve-logging` | Approve pending InstallPlans in openshift-logging |
| `make deploy-logforwarder` | SA + ClusterLogForwarder to **internal** LokiStack (Logging 6.x) |
| `make deploy-logforwarder-external` | ClusterLogForwarder to **external** Loki URL (edit URL/secret first) |
| `make install-coo` | Apply Cluster Observability Operator subscription |
| `make deploy-uiplugin` | Apply UIPlugin for Observe → Logs (internal only) |
| `make verify` | Print status of operators and key resources |

**Internal (ODF) full install:**  
`make prereqs install-loki approve-loki deploy-lokistack install-logging approve-logging deploy-logforwarder install-coo deploy-uiplugin`

**External Loki:**  
`make prereqs install-logging approve-logging` then create secret, edit `clusterlogforwarder-external-loki.yaml` URL, and `make deploy-logforwarder-external`.

---

## Folder structure

```
ocplog_to_loki/
├── README.md                 # This guide (OCP 4.20, internal + external Loki)
├── Makefile                  # Targets for apply and verify
├── config/
│   ├── 00-prerequisites/     # Namespaces and OperatorGroups
│   ├── 01-loki-operator/    # Loki subscription, LokiStack, OBC (internal + ODF)
│   ├── 02-openshift-logging/ # Logging subscription; ClusterLogForwarder (internal + external), SA, secret example
│   └── 03-cluster-observability-operator/ # COO subscription, UIPlugin (internal only)
└── scripts/
    ├── approve-installplan.sh      # Approve InstallPlans in a namespace
    └── create-loki-odf-secret.sh   # Create Loki ODF storage secret from OBC (internal)
```

---

## References

- [Red Hat OpenShift Logging – Installing logging](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/)  
- [Red Hat OpenShift Cluster Observability Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/)  
- [OpenShift Loki Operator](https://catalog.redhat.com/software/containers/openshift-logging/loki-rhel9-operator/overview)
