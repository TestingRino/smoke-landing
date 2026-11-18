#!/usr/bin/env bash
# GCP resources for DefectDojo team access (IAP) and backups. Run in Cloud Shell, one step at a time:
#
#   ./gcp/defectdojo.sh firewall     network tag on the VM + firewall rule: IAP range -> tcp/8088 only
#   ./gcp/defectdojo.sh role         custom role smokeDojoTunnel (lets gcloud look up the VM by name)
#   ./gcp/defectdojo.sh bucket       backup bucket: uniform access, no public access, 30-day retention, delete after 90 days
#   ./gcp/defectdojo.sh backup-sa    service account that may only CREATE objects in that bucket, attached to the VM
#                                    (STOPS and restarts the VM: the runner is offline for ~2 minutes)
#
# Every step is idempotent. Grant people access afterwards with: bin/smokectl grant-dojo <email>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../smoke.config.env
source "$ROOT/smoke.config.env"
# shellcheck source=lib.sh
source "$ROOT/gcp/lib.sh"
P="$GCP_PROJECT"; G=(--project "$P" --quiet)
PORT="$DEFECTDOJO_PORT"; BUCKET="$DEFECTDOJO_BACKUP_BUCKET"
SA="$DEFECTDOJO_BACKUP_SA@$P.iam.gserviceaccount.com"
RULE="allow-iap-defectdojo"
IAP_RANGE="35.235.240.0/20"   # Google IAP TCP forwarding source range

firewall() {
  say "network tag $VM_DOJO_TAG on $VM_NAME"
  gcloud compute instances add-tags "$VM_NAME" "${G[@]}" --zone "$VM_ZONE" --tags "$VM_DOJO_TAG"
  say "firewall rule $RULE: $IAP_RANGE -> tcp:$PORT on tag $VM_DOJO_TAG"
  local net; net="$(gcloud compute instances describe "$VM_NAME" "${G[@]}" --zone "$VM_ZONE" --format='value(networkInterfaces[0].network.basename())')"
  if gcloud compute firewall-rules describe "$RULE" "${G[@]}" >/dev/null 2>&1; then
    gcloud compute firewall-rules update "$RULE" "${G[@]}" --source-ranges "$IAP_RANGE" --allow "tcp:$PORT" --target-tags "$VM_DOJO_TAG"
  else
    gcloud compute firewall-rules create "$RULE" "${G[@]}" --network "$net" --direction INGRESS --priority 1000 \
      --source-ranges "$IAP_RANGE" --allow "tcp:$PORT" --target-tags "$VM_DOJO_TAG" \
      --description "DefectDojo via Google IAP TCP forwarding only (smoke-landing)"
  fi
  say "check: rules open to the whole internet (none may allow tcp:$PORT or 'all')"
  gcloud compute firewall-rules list "${G[@]}" --filter="direction=INGRESS AND sourceRanges:0.0.0.0/0" \
    --format='table(name,allowed[].map().firewall_rule().list():label=ALLOW,targetTags.list():label=TARGET_TAGS)'
}

role() {
  say "custom role smokeDojoTunnel (compute.instances.get: lets start-iap-tunnel find the VM by name)"
  local args=(--title "smoke-landing DefectDojo tunnel" --permissions compute.instances.get --stage GA
              --description "Look up the DevSecOps VM for gcloud compute start-iap-tunnel. Granted with an IAM condition by smokectl grant-dojo.")
  if gcloud iam roles describe smokeDojoTunnel "${G[@]}" >/dev/null 2>&1; then
    gcloud iam roles update smokeDojoTunnel "${G[@]}" "${args[@]}" >/dev/null
  else
    gcloud iam roles create smokeDojoTunnel "${G[@]}" "${args[@]}" >/dev/null
  fi
  echo "ok"
}

bucket() {
  say "bucket gs://$BUCKET"
  gcloud storage buckets describe "gs://$BUCKET" "${G[@]}" >/dev/null 2>&1 || \
    gcloud storage buckets create "gs://$BUCKET" "${G[@]}" --location "$GCP_REGION" --default-storage-class STANDARD \
      --uniform-bucket-level-access --public-access-prevention
  # Retention policy (30 days): no object can be deleted or replaced for 30 days, by anyone.
  # Cloud Storage doesn't allow Object Versioning on a bucket with a retention policy; retention is the
  # stronger guarantee here, and the VM can't overwrite anything anyway (create-only uploads).
  gcloud storage buckets update "gs://$BUCKET" "${G[@]}" --retention-period 30d
  local lc; lc="$(mktemp)"
  echo '{"rule":[{"action":{"type":"Delete"},"condition":{"age":90}}]}' > "$lc"
  gcloud storage buckets update "gs://$BUCKET" "${G[@]}" --lifecycle-file "$lc"; rm -f "$lc"
  gcloud storage buckets describe "gs://$BUCKET" "${G[@]}" \
    --format='yaml(name,location,uniform_bucket_level_access,public_access_prevention,retention_policy,lifecycle_config)'
}

backup_sa() {
  say "service account $SA"
  gcloud iam service-accounts describe "$SA" "${G[@]}" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$DEFECTDOJO_BACKUP_SA" "${G[@]}" --display-name "DefectDojo backups (create-only)"
  say "grant roles/storage.objectCreator on gs://$BUCKET only"
  bind gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" "${G[@]}" --member "serviceAccount:$SA" --role roles/storage.objectCreator
  local cur; cur="$(gcloud compute instances describe "$VM_NAME" "${G[@]}" --zone "$VM_ZONE" --format='value(serviceAccounts[0].email)')"
  if [[ "$cur" == "$SA" ]]; then echo "already attached to $VM_NAME"; return 0; fi
  say "attach to $VM_NAME (scope devstorage.read_write only)"
  echo "The VM must be STOPPED to change its service account. The GitHub runner will be offline for ~2 minutes."
  read -r -p "Stop $VM_NAME now? [y/N] " ans; [[ "$ans" == [yY] ]] || { echo "skipped"; return 0; }
  gcloud compute instances stop "$VM_NAME" "${G[@]}" --zone "$VM_ZONE"
  gcloud compute instances set-service-account "$VM_NAME" "${G[@]}" --zone "$VM_ZONE" \
    --service-account "$SA" --scopes https://www.googleapis.com/auth/devstorage.read_write
  gcloud compute instances start "$VM_NAME" "${G[@]}" --zone "$VM_ZONE"
  echo "Done. On the VM, check it with: sudo /opt/defectdojo/backup.sh"
}

case "${1:-}" in
  firewall) firewall ;; role) role ;; bucket) bucket ;; backup-sa) backup_sa ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
