# OpenShift Logging with Loki – apply configs and verify
# Run from repository root with oc logged in.

CONFIG_DIR := config
SCRIPTS_DIR := scripts

# --- Loki Operator (namespaces, OperatorGroup, subscription) ---
LOKI_DIR := $(CONFIG_DIR)/01-loki-operator
install-loki:
	oc apply -f $(LOKI_DIR)/openshift-operators-redhat-namespace.yaml
	oc apply -f $(LOKI_DIR)/openshift-operators-redhat-operatorgroup.yaml
	oc apply -f $(LOKI_DIR)/openshift-logging-namespace.yaml
	oc apply -f $(LOKI_DIR)/loki-operator-subscription.yaml

approve-loki:
	@echo "Approving InstallPlans in openshift-operators-redhat..."
	@for ip in $$(oc get installplan -o name -n openshift-operators-redhat 2>/dev/null || true); do \
		oc patch $$ip --namespace openshift-operators-redhat --type merge --patch '{"spec":{"approved":true}}'; \
	done

# Deploy LokiStack (ODF path: OBC + secret script + LokiStack)
deploy-lokistack: deploy-loki-obc deploy-loki-secret deploy-lokistack-cr

deploy-loki-obc:
	oc apply -f $(CONFIG_DIR)/01-loki-operator/objectbucketclaim.yaml

deploy-loki-secret:
	$(SCRIPTS_DIR)/create-loki-odf-secret.sh

deploy-lokistack-cr:
	oc apply -f $(CONFIG_DIR)/01-loki-operator/lokistack.yaml

# --- OpenShift Logging Operator (namespace, OperatorGroup, subscription) ---
LOGGING_DIR := $(CONFIG_DIR)/02-openshift-logging
install-logging:
	oc apply -f $(LOGGING_DIR)/openshift-logging-namespace.yaml
	oc apply -f $(LOGGING_DIR)/openshift-logging-operatorgroup.yaml
	oc apply -f $(LOGGING_DIR)/openshift-logging-operator-subscription.yaml

install-logging-v6:
	oc apply -f $(LOGGING_DIR)/openshift-logging-namespace.yaml
	oc apply -f $(LOGGING_DIR)/openshift-logging-operatorgroup.yaml
	oc apply -f $(LOGGING_DIR)/logging-v6-subscription.yaml

approve-logging:
	@echo "Approving InstallPlans in openshift-logging..."
	@for ip in $$(oc get installplan -o name -n openshift-logging 2>/dev/null || true); do \
		oc patch $$ip --namespace openshift-logging --type merge --patch '{"spec":{"approved":true}}'; \
	done

# Logging 6.x: SA + bearer token Secret + ClusterLogForwarder (token from secret)
deploy-logforwarder:
	bash $(CONFIG_DIR)/02-openshift-logging/serviceaccount.sh
	bash $(SCRIPTS_DIR)/create-lokistack-bearer-secret.sh
	oc apply -f $(CONFIG_DIR)/02-openshift-logging/clusterlogforwarder.yaml

# External Loki: on spoke, Secret to-loki-secret (token + ca-bundle.crt); edit URL in YAML.
# Optional: TO_LOKI_TOKEN=... HUB_LOKI_CA_FILE=./hub-ca.crt make deploy-logforwarder-external
# HUB: make apply-hub-remote-log-writer (creates remote-log-writer SA + RBAC)
# Logging 5.x: oc apply -f $(CONFIG_DIR)/02-openshift-logging/clusterlogforwarder-external-loki-logging5.yaml
apply-hub-remote-log-writer:
	oc apply -f $(CONFIG_DIR)/02-openshift-logging/hub-remote-log-writer/

deploy-logforwarder-external:
	bash $(CONFIG_DIR)/02-openshift-logging/serviceaccount.sh
	@if [ -n "$$TO_LOKI_TOKEN" ] && [ -n "$$HUB_LOKI_CA_FILE" ]; then \
		$(SCRIPTS_DIR)/create-to-loki-secret.sh; \
	fi
	oc apply -f $(CONFIG_DIR)/02-openshift-logging/clusterlogforwarder-external-loki.yaml

# --- Cluster Observability Operator ---
install-coo:
	oc apply -f $(CONFIG_DIR)/03-cluster-observability-operator/cluster-observability-operator-subscription.yaml

deploy-uiplugin:
	oc apply -f $(CONFIG_DIR)/03-cluster-observability-operator/uiplugin-logging.yaml

# --- Verify ---
verify:
	@echo "=== Namespaces ==="
	@oc get ns openshift-operators-redhat openshift-logging 2>/dev/null || true
	@echo "\n=== Loki Operator (openshift-operators-redhat) ==="
	@oc get csv -n openshift-operators-redhat 2>/dev/null | grep -E "NAME|loki" || true
	@oc get pods -n openshift-operators-redhat 2>/dev/null | grep -E "NAME|loki" || true
	@echo "\n=== OpenShift Logging (openshift-logging) ==="
	@oc get csv -n openshift-logging 2>/dev/null | grep -E "NAME|cluster-logging" || true
	@oc get pods -n openshift-logging 2>/dev/null | head -25
	@echo "\n=== Cluster Observability Operator (openshift-operators) ==="
	@oc get csv -n openshift-operators 2>/dev/null | grep -E "NAME|cluster-observability" || true
	@oc get uiplugin 2>/dev/null || true

.PHONY: install-loki approve-loki deploy-lokistack deploy-loki-obc deploy-loki-secret deploy-lokistack-cr \
	install-logging install-logging-v6 approve-logging deploy-logforwarder deploy-logforwarder-external \
	apply-hub-remote-log-writer install-coo deploy-uiplugin verify
