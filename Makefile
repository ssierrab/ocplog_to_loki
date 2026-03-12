# OpenShift Logging with Loki – apply configs and verify
# Run from repository root with oc logged in.

CONFIG_DIR := config
SCRIPTS_DIR := scripts

# Prerequisites: apply only what each cluster needs (see README Step 1).
# Loki prereqs: cluster where Loki runs (hub for external, spoke for internal).
prereqs-loki:
	oc apply -f $(CONFIG_DIR)/00a-loki/
# Logging prereqs: cluster where Logging Operator runs (spoke in both scenarios).
prereqs-logging:
	oc apply -f $(CONFIG_DIR)/00b-logging/
# Both (e.g. internal spoke).
prereqs: prereqs-loki prereqs-logging

# --- Loki Operator ---
install-loki:
	oc apply -f $(CONFIG_DIR)/01-loki-operator/loki-operator-subscription.yaml

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

# --- OpenShift Logging Operator ---
install-logging:
	oc apply -f $(CONFIG_DIR)/02-openshift-logging/openshift-logging-operator-subscription.yaml

install-logging-v6:
	oc apply -f $(CONFIG_DIR)/02-openshift-logging/logging-v6-subscription.yaml

approve-logging:
	@echo "Approving InstallPlans in openshift-logging..."
	@for ip in $$(oc get installplan -o name -n openshift-logging 2>/dev/null || true); do \
		oc patch $$ip --namespace openshift-logging --type merge --patch '{"spec":{"approved":true}}'; \
	done

# Logging 6.x: service account + ClusterLogForwarder to internal LokiStack
deploy-logforwarder:
	bash $(CONFIG_DIR)/02-openshift-logging/serviceaccount.sh
	oc apply -f $(CONFIG_DIR)/02-openshift-logging/clusterlogforwarder.yaml

# External Loki: edit clusterlogforwarder-external-loki.yaml URL (and secret) first, then run.
# Uses observability.openshift.io (Logging 6.x). For Logging 5.x use:
#   oc apply -f $(CONFIG_DIR)/02-openshift-logging/clusterlogforwarder-external-loki-logging5.yaml
deploy-logforwarder-external:
	bash $(CONFIG_DIR)/02-openshift-logging/serviceaccount.sh
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

.PHONY: prereqs prereqs-loki prereqs-logging install-loki approve-loki deploy-lokistack deploy-loki-obc deploy-loki-secret deploy-lokistack-cr \
	install-logging install-logging-v6 approve-logging deploy-logforwarder deploy-logforwarder-external \
	install-coo deploy-uiplugin verify
