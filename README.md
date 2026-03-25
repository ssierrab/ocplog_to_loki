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

**Operator channel:** Loki and **cluster-logging** subscription YAML uses placeholder **`__OPERATOR_CHANNEL__`**. Apply via **`make install-loki`** / **`make install-logging`** (or **`scripts/render-operator-channel.sh`** piped to **`oc apply`**). The script **prompts for the channel** in the terminal unless **`OPERATOR_CHANNEL`** is already set (use that for CI or to avoid a second prompt: `export OPERATOR_CHANNEL=stable-6.4`). Do not **`oc apply -f`** those subscription files unrendered.

## Installation order (by scenario)

**Internal (Loki on spoke):**  
On the **spoke**: Loki Operator (namespaces, subscription) → LokiStack (ODF) → OpenShift Logging Operator → **2.4.1** (ClusterLogForwarder to LokiStack) → Cluster Observability Operator → UIPlugin.

**External (Loki on hub):**  
1. On the **hub**: Step 1 (Loki namespaces + subscription + LokiStack).  
2. On the **spoke**: Step 2 through 2.3 (OpenShift Logging Operator only). Do **not** install Loki or LokiStack on the spoke.  
3. **2.4.2** (hub then spoke): hub `remote-log-writer`, JWT, gateway CA, push URL; spoke `to-loki-secret` and external ClusterLogForwarder.  
4. Optionally on the **hub**: Step 3 (COO + UIPlugin for Observe → Logs).

---

## Step 1: Deploy Loki on the cluster where Loki runs

**Where:**  
- **Internal**: Run on the **spoke** (the cluster that will store its own logs).  
- **External**: Run on the **hub** (the cluster that will host the central Loki).  

Do **not** run this step on the spoke when using external Loki; the spoke only forwards logs to the hub.

### 1.1 Create namespaces and subscribe to the Loki Operator

Loki-related manifests live in `config/01-loki-operator/`.

**OperatorGroup in `openshift-operators-redhat`:** That namespace must contain **at most one** OperatorGroup. OpenShift usually ships with one already. **`make install-loki` does not apply** `openshift-operators-redhat-operatorgroup.yaml` so you do not create a duplicate. Apply it **only** if `oc get operatorgroup -n openshift-operators-redhat` shows **no** resources (unusual lab clusters):

```bash
make install-loki-operatorgroup
# or: oc apply -f config/01-loki-operator/openshift-operators-redhat-operatorgroup.yaml
```

**Using the Makefile** (you are prompted for the OLM channel unless **`OPERATOR_CHANNEL`** is exported or passed: `make install-loki OPERATOR_CHANNEL=stable-6.4`):

```bash
make install-loki
```

**Using oc apply** (namespaces, then subscription — skip OperatorGroup unless none exists). Pipe the subscription through the script so you are prompted for the channel (or set **`OPERATOR_CHANNEL`** first):

```bash
oc apply -f config/01-loki-operator/openshift-operators-redhat-namespace.yaml
oc apply -f config/01-loki-operator/openshift-logging-namespace.yaml
./scripts/render-operator-channel.sh config/01-loki-operator/loki-operator-subscription.yaml | oc apply -f -
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

## Step 2: Install Red Hat OpenShift Logging Operator (on the cluster that collects logs)

**Where:** On the **spoke** in both scenarios (the cluster that produces the logs). For internal, install after Loki is ready on that same spoke. For external, the hub does not need the Logging Operator for receiving logs; only the spoke does.

### 2.1 Create namespace and OperatorGroup, then subscribe to the OpenShift Logging Operator

All Logging-related resources (namespace, **cluster-logging** OperatorGroup, subscription) are in `config/02-openshift-logging/`.

**Using the Makefile** (same channel prompt as **`install-loki`**; reuse **`export OPERATOR_CHANNEL=…`** so you are not asked again):

```bash
make install-logging
```

**Using oc apply** (namespace and OperatorGroup first, then subscription — same prompt or **`OPERATOR_CHANNEL`** as for Loki):

```bash
oc apply -f config/02-openshift-logging/openshift-logging-namespace.yaml
oc apply -f config/02-openshift-logging/openshift-logging-operatorgroup.yaml
./scripts/render-operator-channel.sh config/02-openshift-logging/openshift-logging-operator-subscription.yaml | oc apply -f -
```

**`openshift-logging-operator-subscription.yaml`** and **`logging-v6-subscription.yaml`** both install **cluster-logging**; use the **same OLM channel** you chose for **loki-operator** (for example **stable-6.4**, **stable-6.3** — check OperatorHub or `oc get packagemanifest cluster-logging -n openshift-marketplace`). Use **`logging-v6-subscription.yaml`** only if you prefer that filename (**`make install-logging-v6`**); do not apply both subscription files to the same namespace.

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

Follow **2.4.1** for internal Loki (LokiStack on this cluster) or **2.4.2** for external Loki (forward to the hub).

#### 2.4.1 Internal — LokiStack on this spoke

- **Logging 6.x**: Create the `logcollector` service account, create the **Bearer token Secret** for LokiStack, then apply the ClusterLogForwarder:

  ```bash
  bash config/02-openshift-logging/serviceaccount.sh
  ./scripts/create-lokistack-bearer-secret.sh
  oc apply -f config/02-openshift-logging/clusterlogforwarder.yaml
  ```

  **LokiStack auth** uses a token from a **Secret** (`lokiStack.authentication.token.from: secret`), Secret **`loki-stack-bearer-token`**, key **`token`**. The script fills it using `oc create token logcollector` (or a legacy SA token). `spec.serviceAccount.name: logcollector` is still required for the collector pods. Re-run `create-lokistack-bearer-secret.sh` to rotate. Manual template: `config/02-openshift-logging/secret-lokistack-bearer.example.yaml`.

- **Logging 5.x**: Use a ClusterLogging CR with `logStore.type: lokistack` and `logStore.lokistack.name: logging-loki` (see Red Hat documentation), or use the ClusterLogForwarder if your 5.x version supports it.

#### 2.4.2 External — forward to Loki on the hub

Use when Loki runs on the **hub** and this **spoke** collects logs. Authentication is a **Bearer token** in Secret **`to-loki-secret`** on the spoke (key **`token`**) plus **hub CA** PEM (key **`ca-bundle.crt`**) so the spoke trusts the hub Loki gateway TLS. Complete the **hub** subsection first (with `oc` on the hub), then the **spoke** subsection.

**On the hub** (after Step 1 and LokiStack are healthy):

1. **ServiceAccount `remote-log-writer`** in `openshift-logging` and roles for pushing through the LokiStack gateway:

   ```bash
   make apply-hub-remote-log-writer
   # or: oc apply -f config/02-openshift-logging/hub-remote-log-writer/
   ```

   The manifests bind **`cluster-logging-write-application-logs`**, **`cluster-logging-write-audit-logs`**, and **`cluster-logging-write-infrastructure-logs`** to that service account (same write model as the in-cluster log collector).

2. **Obtain a token** for `remote-log-writer` and **copy the raw JWT** for the spoke Secret. Store **only the JWT**—do **not** prefix with `Bearer `; the forwarder adds `Authorization: Bearer` automatically.

   **Method 1 — Long-lived token (Secret on the hub)**  
   If you ran `make apply-hub-remote-log-writer`, **`03-long-lived-token-secret.yaml`** is included. Otherwise: `oc apply -f config/02-openshift-logging/hub-remote-log-writer/`. Then:

   ```bash
   oc wait --for=jsonpath='{.data.token}' secret/remote-log-writer-token -n openshift-logging --timeout=120s
   oc get secret remote-log-writer-token -n openshift-logging -o jsonpath='{.data.token}' | base64 -d
   ```

   If you use **Method 2** instead, the long-lived Secret on the hub is optional (unused Secret is harmless, or apply only `01-serviceaccount.yaml` and `02-rbac.yaml`).

   **Method 2 — Short-lived token (`oc create token`)**  
   Bounded lifetime; **re-issue before expiry** and **update `to-loki-secret`** on the spoke or forwarding returns 401.

   ```bash
   # Example: 24 hours — adjust --duration per policy (e.g. 168h, 720h)
   oc create token remote-log-writer -n openshift-logging --duration=24h
   ```

3. **Hub gateway CA (PEM)** for the spoke to verify TLS to **`https://<route-host>/...`**.

   - If the push URL uses an **OpenShift Route** (`*.apps.<cluster>`), the certificate is signed by the **default ingress / router CA**, not the in-namespace **service CA**. On the **hub**:

     ```bash
     oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' | base64 -d > hub-loki-tls-ca.crt
     ```

     Confirm with `openssl s_client -servername <route-host> -connect <route-host>:443 -CAfile hub-loki-tls-ca.crt` → **`Verify return code: 0`**.

   - If you use **in-cluster Service DNS** and **service CA**-signed TLS only, you can use **`openshift-service-ca.crt`** from **`openshift-logging`** instead.

4. **Push URLs** (Red Hat **LokiStack gateway** with **`tenants.mode: openshift-logging`**): the Route does **not** serve **`/loki/api/v1/push`** at the host root. The **real** ingest URL is **`/api/logs/v1/<tenant>/loki/api/v1/push`**.

   **ClusterLogForwarder `loki.url` (Logging 6.x):** The collector’s **Vector** Loki sink sets **`endpoint`** from this field and **appends `/loki/api/v1/push` itself** ([Vector Loki sink](https://vector.dev/docs/reference/configuration/sinks/loki)). If you put the **full** path in `loki.url`, requests become **`.../loki/api/v1/push/loki/api/v1/push`** and the gateway returns **404**. Use the **tenant base only** (no trailing `/loki/api/v1/push`):

   | Input / tenant     | Value for **`spec.outputs[].loki.url`** |
   |--------------------|----------------------------------------|
   | `application`      | `https://<route-host>/api/logs/v1/application` |
   | `infrastructure` | `https://<route-host>/api/logs/v1/infrastructure` |
   | `audit`            | `https://<route-host>/api/logs/v1/audit` |

   Hostname from the hub: `oc get route logging-loki -n openshift-logging -o jsonpath='{.spec.host}{"\n"}'`.

   **Manual `curl` checks** must use the **full** path (Vector is not involved):  
   `https://<route-host>/api/logs/v1/<tenant>/loki/api/v1/push` → expect **204** when CA and token are correct.

**On the spoke** (after 2.3; do **not** install Loki or LokiStack here):

1. Collector service account (log collection RBAC):

   ```bash
   bash config/02-openshift-logging/serviceaccount.sh
   ```

2. **Secret `to-loki-secret`** in `openshift-logging`:
   - **`token`**: raw JWT from the hub (not `Bearer <jwt>`).
   - **`ca-bundle.crt`**: PEM that trusts the **Route** (usually **`router-ca`** from step 3) or **service CA** if you use only in-cluster URLs.

   ```bash
   oc create secret generic to-loki-secret -n openshift-logging \
     --from-literal=token="<PASTE_RAW_JWT_FROM_HUB>" \
     --from-file=ca-bundle.crt=hub-loki-tls-ca.crt
   ```

   Template: `config/02-openshift-logging/to-loki-secret.example.yaml`.

3. Edit **`clusterlogforwarder-external-loki.yaml`** (Logging 6.x): replace **`<loki-gateway-on-hub>`** in **all three** **`spec.outputs[].loki.url`** values with the hub **Route host**. URLs must end at **`/api/logs/v1/<tenant>`** — do **not** add **`/loki/api/v1/push`** (Vector adds it). **Three outputs** and **three pipelines** per step 4.

4. Apply the forwarder:
   - **Logging 6.x:** `oc apply -f config/02-openshift-logging/clusterlogforwarder-external-loki.yaml`
   - **Logging 5.x:** `oc apply -f config/02-openshift-logging/clusterlogforwarder-external-loki-logging5.yaml` (same Secret name; confirm key names for your release).

**Connectivity:** The spoke must resolve and reach the hub gateway hostname (DNS, routes, firewall).

**Makefile:** `make apply-hub-remote-log-writer` on the hub; on the spoke, after **`to-loki-secret`** and URL are set, `make deploy-logforwarder-external` runs `serviceaccount.sh` and applies the external ClusterLogForwarder.

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

This subscription uses `installPlanApproval: Manual`; approve the InstallPlan when it appears (same idea as `make approve-logging` / `approve-installplan.sh` for other operators).

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

## Removing this configuration

These steps undo what this repository installs. Run commands with `oc` pointed at the correct cluster. Order matters: remove forwarding and UI first, then operators, then Loki and storage.

**Which cluster:**  
- **External Loki:** run **On the spoke** on each spoke; run **On the Loki cluster** on the hub.  
- **Internal Loki:** run **both** subsections on the same cluster (it is both spoke and Loki host).

If you used **Logging 5.x** with a **ClusterLogging** CR instead of only ClusterLogForwarder, delete that CR first (see Red Hat docs for your version).

### On the spoke (log collection)

With `oc` on the spoke:

1. **ClusterLogForwarder** (this repo names it **`collector`**):

   ```bash
   oc delete clusterlogforwarder collector -n openshift-logging --ignore-not-found
   ```

2. **Secrets** (delete whichever you created):

   ```bash
   oc delete secret to-loki-secret -n openshift-logging --ignore-not-found
   oc delete secret loki-stack-bearer-token -n openshift-logging --ignore-not-found
   ```

3. **`logcollector` ServiceAccount and cluster RBAC** (reverse of `serviceaccount.sh`):

   ```bash
   oc adm policy remove-cluster-role-from-user collect-application-logs system:serviceaccount:openshift-logging:logcollector
   oc adm policy remove-cluster-role-from-user collect-infrastructure-logs system:serviceaccount:openshift-logging:logcollector
   oc adm policy remove-cluster-role-from-user collect-audit-logs system:serviceaccount:openshift-logging:logcollector
   oc adm policy remove-cluster-role-from-user cluster-logging-write-application-logs system:serviceaccount:openshift-logging:logcollector
   oc adm policy remove-cluster-role-from-user cluster-logging-write-audit-logs system:serviceaccount:openshift-logging:logcollector
   oc adm policy remove-cluster-role-from-user cluster-logging-write-infrastructure-logs system:serviceaccount:openshift-logging:logcollector
   oc delete serviceaccount logcollector -n openshift-logging --ignore-not-found
   ```

4. **OpenShift Logging Operator** (subscription in `openshift-logging`):

   ```bash
   oc delete subscriptions.operators.coreos.com cluster-logging -n openshift-logging --ignore-not-found
   ```

   Wait for the **cluster-logging** CSV to disappear from `openshift-logging`; if it remains, remove it (and any related InstallPlans) per your cluster policy.

### On the Loki cluster (hub, or the spoke for internal Loki)

With `oc` on the cluster where **Step 1** and LokiStack run:

1. **Cluster Observability Operator (optional)** — only if you applied Step 3 here:

   ```bash
   oc delete uiplugin logging --ignore-not-found
   oc delete subscriptions.operators.coreos.com cluster-observability-operator -n openshift-operators --ignore-not-found
   ```

   Wait for the **cluster-observability-operator** CSV to leave `openshift-operators` if you removed the subscription.

2. **Hub remote log writer** (external Loki only — skip on a pure internal spoke if you never ran `apply-hub-remote-log-writer`):

   ```bash
   oc delete secret remote-log-writer-token -n openshift-logging --ignore-not-found
   oc delete clusterrolebinding remote-log-writer-cluster-logging-write-application-logs --ignore-not-found
   oc delete clusterrolebinding remote-log-writer-cluster-logging-write-audit-logs --ignore-not-found
   oc delete clusterrolebinding remote-log-writer-cluster-logging-write-infrastructure-logs --ignore-not-found
   oc delete serviceaccount remote-log-writer -n openshift-logging --ignore-not-found
   ```

3. **LokiStack and ODF-backed storage objects** (names from this repo’s manifests):

   ```bash
   oc delete lokistack logging-loki -n openshift-logging --ignore-not-found
   oc delete secret logging-loki-odf -n openshift-logging --ignore-not-found
   oc delete objectbucketclaim loki-bucket-odf -n openshift-logging --ignore-not-found
   ```

   ODF may recreate or retain bucket data until the ObjectBucketClaim and related resources are fully released; resolve any finalizers or operator warnings if deletion hangs.

4. **Loki Operator:**

   ```bash
   oc delete subscriptions.operators.coreos.com loki-operator -n openshift-operators-redhat --ignore-not-found
   ```

   Wait for the Loki **CSV** to be removed from `openshift-operators-redhat`.

### After removal

- **PVCs and PVs:** They are **not guaranteed** to disappear just because you deleted subscriptions or namespaces. When you delete the **LokiStack**, the Loki Operator normally deletes the **PVCs** it created (this repo sets **`storageClassName: ocs-storagecluster-ceph-rbd`** on the LokiStack for those volumes). Whether the cluster removes the backing **PV** depends on the **StorageClass** **`reclaimPolicy`**: with **`Delete`**, the provisioner typically reclaims storage when the PVC is gone; with **`Retain`**, PVs often stay in **Released** until an administrator deletes them (data may remain on the backend). After teardown, check **`oc get pvc -n openshift-logging`** and **`oc get pv`** (including **Released**) and clean up anything your policy requires.

- **Object storage (ODF):** Chunk storage uses the **ObjectBucketClaim** **`loki-bucket-odf`**. Deleting the OBC starts bucket cleanup per ODF/NooBaa behavior; it may not be immediate, and finalizers or errors can require extra steps in ODF tooling. This is separate from RBD PVs above.

- **Namespaces** (`openshift-logging`, `openshift-operators-redhat`): this guide does not delete them. Remove them only if nothing else in the cluster needs them and your administrators allow it; deleting `openshift-logging` while other workloads depend on it can break the cluster.  
- **OperatorGroups** under `config/01-loki-operator/` and `config/02-openshift-logging/`: delete only if you are uninstalling every operator that uses that namespace’s OperatorGroup.  
- Re-run **`oc get pods -n openshift-logging`** and **`oc get csv -A | grep -E 'loki|cluster-logging|cluster-observability'`** to confirm resources are gone.

---

## Makefile targets

From the repository root. **OCP 4.20.**

| Target | Description |
|--------|-------------|
| `make install-loki` | Namespaces + Loki Operator subscription (prompts for channel unless **`OPERATOR_CHANNEL`** is set; does **not** add an OperatorGroup — see 1.1) |
| `make install-loki-operatorgroup` | Optional: apply `openshift-operators-redhat-operatorgroup.yaml` only if the namespace has **no** OperatorGroup |
| `make approve-loki` | Approve pending InstallPlans in openshift-operators-redhat |
| `make deploy-lokistack` | ODF: ObjectBucketClaim + secret script + LokiStack |
| `make install-logging` | Namespace, **cluster-logging** OperatorGroup, OpenShift Logging subscription (same channel prompt / **`OPERATOR_CHANNEL`** as Loki) |
| `make install-logging-v6` | Same as above via **`logging-v6-subscription.yaml`** (pick **`install-logging` *or* this, not both) |
| `make approve-logging` | Approve pending InstallPlans in openshift-logging |
| `make deploy-logforwarder` | SA + `loki-stack-bearer-token` Secret + ClusterLogForwarder (Logging 6.x, token from Secret) |
| `make apply-hub-remote-log-writer` | **Hub:** SA `remote-log-writer` + ClusterRoleBindings for Loki gateway write |
| `make deploy-logforwarder-external` | **Spoke:** collector SA + apply external ClusterLogForwarder (create **`to-loki-secret`** first with `oc create secret`) |
| `make install-coo` | Apply Cluster Observability Operator subscription |
| `make deploy-uiplugin` | Apply UIPlugin for Observe → Logs |
| `make verify` | Print status of operators and key resources |

**Internal (Loki on spoke):** On the spoke, run:  
`make install-loki approve-loki deploy-lokistack install-logging approve-logging deploy-logforwarder install-coo deploy-uiplugin`

**External (Loki on hub):**  
- On the **hub**: `make install-loki approve-loki deploy-lokistack`, then **2.4.2 (On the hub)** (`make apply-hub-remote-log-writer`, token, CA, push URL). Optionally `install-coo deploy-uiplugin` for Observe → Logs on the hub.  
- On the **spoke**: `make install-logging approve-logging`, then **2.4.2 (On the spoke)** (`to-loki-secret`, hub URL in the manifest, apply forwarder or `make deploy-logforwarder-external`).

---

## Folder structure

```
ocplog_to_loki/
├── README.md                 # This guide (OCP 4.20, internal + external Loki)
├── Makefile                  # Targets for apply and verify
├── config/
│   ├── 01-loki-operator/     # Namespaces, optional OperatorGroup manifest, subscription, LokiStack, OBC
│   ├── 02-openshift-logging/ # ClusterLogForwarder, SA, to-loki-secret example, hub-remote-log-writer/
│   └── 03-cluster-observability-operator/ # COO subscription, UIPlugin
└── scripts/
    ├── approve-installplan.sh
    ├── create-loki-odf-secret.sh
    └── create-lokistack-bearer-secret.sh
```

---

## References

- [Red Hat OpenShift Logging – Installing logging](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/)  
- [Red Hat OpenShift Cluster Observability Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/)  
- [OpenShift Loki Operator](https://catalog.redhat.com/software/containers/openshift-logging/loki-rhel9-operator/overview)
