#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  gcp_pubsub_to_newrelic_smoke_test.sh [--cleanup]

Description:
  Runs a GCP smoke test for the Pub/Sub to New Relic Dataflow template,
  the same way a customer would run it: stage the template once, then
  launch it with `gcloud dataflow jobs run` (no Maven/source needed to run).
  By default, it will:
    1) Create a test Pub/Sub topic and subscription
    2) Build and stage the Dataflow template to GCS (from source)
    3) Launch the staged template as a Dataflow job
    4) Publish a unique test log message
    5) Print verification steps for New Relic

  With --cleanup, it deletes the test Pub/Sub resources and cancels the job.
  TOPIC_NAME, SUB_NAME, and JOB_NAME must match the values printed by the
  run you are cleaning up (or the ones you passed in explicitly).

  If the script fails before the Dataflow job is launched, it automatically
  rolls back any Pub/Sub topic/subscription it created.

Required environment variables:
  PROJECT_ID        GCP project ID
  REGION            Dataflow region (for example: us-central1)
  BUCKET            GCS bucket URI for staging/temp/template (for example: gs://my-bucket)
  NR_LICENSE_KEY    New Relic license key (or set NR_LICENSE_KEY_FILE instead)

Optional environment variables:
  NR_LICENSE_KEY_FILE Path to a file containing the New Relic license key.
                    Use this instead of NR_LICENSE_KEY to avoid the secret
                    appearing in shell history or process listings.
  NR_ENDPOINT       New Relic logs endpoint
                    Default: https://log-api.newrelic.com/log/v1
  TOPIC_NAME        Pub/Sub topic name to create/use
                    Default: nr-smoke-topic-<timestamp>
  SUB_NAME          Pub/Sub subscription name to create/use
                    Default: nr-smoke-sub-<timestamp>
  JOB_NAME          Dataflow job name
                    Default: nr-smoke-<timestamp>
  BATCH_COUNT       Default: 10
  FLUSH_DELAY       Default: 2
  PARALLELISM       Default: 1
  USE_COMPRESSION   Default: true
  DISABLE_CERT_VALIDATION Default: false
  NETWORK           Compute Engine network for worker VMs (omit if using SUBNETWORK)
  SUBNETWORK        Compute Engine subnetwork self-link for worker VMs.
                    Required in projects without a "default" network.
  DISABLE_PUBLIC_IPS Default: false. Set to true if the project enforces the
                    compute.vmExternalIpAccess org policy (workers must not
                    get external IPs). Requires the subnetwork to have
                    Private Google Access enabled AND Cloud NAT configured
                    on that subnetwork/region (workers otherwise have no
                    path to reach the New Relic Logs API over the internet).
  SKIP_TEMPLATE_BUILD Default: false. Set to true to reuse an already-staged
                    template at ${BUCKET}/template/PubsubToNewRelic instead of
                    rebuilding it.

Examples:
  PROJECT_ID=my-proj REGION=us-central1 BUCKET=gs://my-bucket NR_LICENSE_KEY=xxxx \
  ./scripts/gcp_pubsub_to_newrelic_smoke_test.sh

  PROJECT_ID=my-proj REGION=us-central1 BUCKET=gs://my-bucket NR_LICENSE_KEY_FILE=./nr_key.txt \
  SUBNETWORK=https://www.googleapis.com/compute/v1/projects/my-proj/regions/us-central1/subnetworks/my-subnet \
  DISABLE_PUBLIC_IPS=true \
  TOPIC_NAME=nr-test-topic SUB_NAME=nr-test-sub JOB_NAME=nr-smoke-manual \
  ./scripts/gcp_pubsub_to_newrelic_smoke_test.sh

  PROJECT_ID=my-proj REGION=us-central1 BUCKET=gs://my-bucket NR_LICENSE_KEY=xxxx \
  TOPIC_NAME=nr-test-topic SUB_NAME=nr-test-sub JOB_NAME=nr-smoke-manual \
  ./scripts/gcp_pubsub_to_newrelic_smoke_test.sh --cleanup
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Error: required environment variable is not set: $name" >&2
    exit 1
  fi
}

topic_created=false
sub_created=false
job_launched=false

rollback_on_failure() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    return
  fi
  echo >&2
  echo "Failed (exit $exit_code)." >&2
  if [[ "$job_launched" == "true" ]]; then
    echo "Dataflow job may already be running. Nothing was auto-cancelled; use --cleanup to remove resources:" >&2
    echo "  PROJECT_ID=$PROJECT_ID REGION=$REGION BUCKET=$BUCKET NR_LICENSE_KEY=*** TOPIC_NAME=$TOPIC_NAME SUB_NAME=$SUB_NAME JOB_NAME=$JOB_NAME $0 --cleanup" >&2
    return
  fi
  echo "Rolling back Pub/Sub resources created by this run..." >&2
  if [[ "$sub_created" == "true" ]]; then
    gcloud pubsub subscriptions delete "$SUB_NAME" --project "$PROJECT_ID" || true
  fi
  if [[ "$topic_created" == "true" ]]; then
    gcloud pubsub topics delete "$TOPIC_NAME" --project "$PROJECT_ID" || true
  fi
}
trap rollback_on_failure EXIT

cleanup_mode=false
if [[ "${1:-}" == "--cleanup" ]]; then
  cleanup_mode=true
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
elif [[ -n "${1:-}" ]]; then
  echo "Error: unknown argument: $1" >&2
  usage
  exit 1
fi

require_cmd gcloud

require_env PROJECT_ID
require_env REGION
require_env BUCKET

if [[ "$BUCKET" != gs://* ]]; then
  echo "Error: BUCKET must be a gs:// URI (got: $BUCKET)" >&2
  exit 1
fi

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
  echo "Error: no active gcloud account. Run 'gcloud auth login' first." >&2
  exit 1
fi

if [[ -z "${NR_LICENSE_KEY:-}" && -n "${NR_LICENSE_KEY_FILE:-}" ]]; then
  NR_LICENSE_KEY="$(<"$NR_LICENSE_KEY_FILE")"
fi
require_env NR_LICENSE_KEY

NR_ENDPOINT="${NR_ENDPOINT:-https://log-api.newrelic.com/log/v1}"
BATCH_COUNT="${BATCH_COUNT:-10}"
FLUSH_DELAY="${FLUSH_DELAY:-2}"
PARALLELISM="${PARALLELISM:-1}"
USE_COMPRESSION="${USE_COMPRESSION:-true}"
DISABLE_CERT_VALIDATION="${DISABLE_CERT_VALIDATION:-false}"
NETWORK="${NETWORK:-}"
SUBNETWORK="${SUBNETWORK:-}"
DISABLE_PUBLIC_IPS="${DISABLE_PUBLIC_IPS:-false}"
SKIP_TEMPLATE_BUILD="${SKIP_TEMPLATE_BUILD:-false}"

timestamp="$(date +%Y%m%d-%H%M%S)"

if [[ "$cleanup_mode" == "true" ]]; then
  require_env TOPIC_NAME
  require_env SUB_NAME
  require_env JOB_NAME
  echo "Cleaning up test resources..."
  job_id="$(gcloud dataflow jobs list --region "$REGION" --project "$PROJECT_ID" \
    --filter="name:$JOB_NAME AND state:Running" --format="value(id)" | head -n1)"
  if [[ -n "$job_id" ]]; then
    gcloud dataflow jobs cancel "$job_id" --region "$REGION" --project "$PROJECT_ID" || true
  else
    echo "No running job found matching name: $JOB_NAME (already cancelled, or never launched)"
  fi
  gcloud pubsub subscriptions delete "$SUB_NAME" --project "$PROJECT_ID" || true
  gcloud pubsub topics delete "$TOPIC_NAME" --project "$PROJECT_ID" || true
  echo "Cleanup complete."
  trap - EXIT
  exit 0
fi

require_cmd mvn

TOPIC_NAME="${TOPIC_NAME:-nr-smoke-topic-$timestamp}"
SUB_NAME="${SUB_NAME:-nr-smoke-sub-$timestamp}"
JOB_NAME="${JOB_NAME:-nr-smoke-$timestamp}"
INPUT_SUBSCRIPTION="projects/${PROJECT_ID}/subscriptions/${SUB_NAME}"
TEMPLATE_LOCATION="${BUCKET}/template/PubsubToNewRelic"

echo "Using project: $PROJECT_ID"
echo "Using region: $REGION"
echo "Using bucket: $BUCKET"
echo "Using New Relic endpoint: $NR_ENDPOINT"
echo "Creating topic: $TOPIC_NAME"
echo "Creating subscription: $SUB_NAME"

gcloud pubsub topics create "$TOPIC_NAME" --project "$PROJECT_ID" \
  --labels=purpose=nr-pubsub-smoke-test
topic_created=true

gcloud pubsub subscriptions create "$SUB_NAME" --topic "$TOPIC_NAME" --project "$PROJECT_ID" \
  --labels=purpose=nr-pubsub-smoke-test
sub_created=true

if [[ "$SKIP_TEMPLATE_BUILD" == "true" ]]; then
  echo "Skipping template build, reusing: $TEMPLATE_LOCATION"
else
  echo "Building and staging template to: $TEMPLATE_LOCATION"
  mvn -DskipTests compile exec:java \
    -Dexec.mainClass=com.google.cloud.teleport.templates.PubsubToNewRelic \
    -Dexec.cleanupDaemonThreads=false \
    -Dexec.args="--runner=DataflowRunner \
--project=${PROJECT_ID} \
--region=${REGION} \
--stagingLocation=${BUCKET}/staging \
--tempLocation=${BUCKET}/temp \
--templateLocation=${TEMPLATE_LOCATION}"
fi

echo "Launching Dataflow job from template: $JOB_NAME"
network_args=()
if [[ -n "$SUBNETWORK" ]]; then
  network_args+=(--subnetwork="$SUBNETWORK")
fi
if [[ -n "$NETWORK" ]]; then
  network_args+=(--network="$NETWORK")
fi
if [[ "$DISABLE_PUBLIC_IPS" == "true" ]]; then
  network_args+=(--disable-public-ips)
fi

gcloud dataflow jobs run "$JOB_NAME" \
  --gcs-location="$TEMPLATE_LOCATION" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --additional-user-labels=purpose=nr-pubsub-smoke-test \
  "${network_args[@]}" \
  --parameters="inputSubscription=${INPUT_SUBSCRIPTION},licenseKey=${NR_LICENSE_KEY},logsApiUrl=${NR_ENDPOINT},batchCount=${BATCH_COUNT},flushDelay=${FLUSH_DELAY},parallelism=${PARALLELISM},disableCertificateValidation=${DISABLE_CERT_VALIDATION},useCompression=${USE_COMPRESSION}" \
  >/dev/null
job_launched=true

TOKEN="nr-test-${timestamp}"
MESSAGE="{\"message\":\"${TOKEN} from gcp smoke test\"}"

echo "Publishing test message..."
gcloud pubsub topics publish "$TOPIC_NAME" --project "$PROJECT_ID" --message "$MESSAGE"

echo
echo "Smoke test launched successfully."
echo "Job name: $JOB_NAME"
echo "Template: $TEMPLATE_LOCATION"
echo "Topic: $TOPIC_NAME"
echo "Subscription: $SUB_NAME"
echo "Verification token: $TOKEN"
echo
echo "Verify in New Relic Logs with query containing token: $TOKEN"
echo "Optionally filter by plugin.source = gcp-dataflow-1.0.0"
echo
echo "Useful commands:"
echo "  gcloud dataflow jobs list --region $REGION --project $PROJECT_ID"
echo "  gcloud dataflow jobs describe $JOB_NAME --region $REGION --project $PROJECT_ID"
echo
echo "Cleanup command:"
echo "  PROJECT_ID=$PROJECT_ID REGION=$REGION BUCKET=$BUCKET NR_LICENSE_KEY=*** TOPIC_NAME=$TOPIC_NAME SUB_NAME=$SUB_NAME JOB_NAME=$JOB_NAME $0 --cleanup"
