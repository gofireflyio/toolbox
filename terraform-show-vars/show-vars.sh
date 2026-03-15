#!/bin/bash
# show-vars.sh
# Usage: ./show-vars.sh [-cmd tofu|terraform] [-var-file <file>]
# Example: ./show-vars.sh -cmd tofu -var-file prod.tfvars
#          ./show-vars.sh -cmd terraform
#          ./show-vars.sh

TF_CMD="tofu"
VAR_FILE="terraform.auto.tfvars"

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -cmd)
      TF_CMD="$2"
      shift 2
      ;;
    -var-file)
      VAR_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Usage: $0 [-cmd tofu|terraform] [-var-file <file>]" >&2
      echo "{}"
      exit 0
      ;;
  esac
done

# Build console args
CONSOLE_ARGS=""
if [ -f "$VAR_FILE" ]; then
  CONSOLE_ARGS="-var-file=$VAR_FILE"
else
  echo "Warning: var file '$VAR_FILE' not found, using defaults only" >&2
fi

log_error() {
  echo "Error: $1" >&2
}

empty_json() {
  echo "{}"
  exit 0
}

# Check dependencies
for cmd in "$TF_CMD" jq paste awk sed grep; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Missing required tool: $cmd"
    empty_json
  fi
done

# Check .tf files exist
if ! ls *.tf &>/dev/null; then
  log_error "No .tf files found in current directory"
  empty_json
fi

# Check tofu/terraform is initialized
if [ ! -d ".terraform" ]; then
  log_error "Not initialized. Run '$TF_CMD init' first"
  empty_json
fi

# Extract and resolve variables
VARS=$(grep -r '^variable ' *.tf 2>/dev/null | sed 's/.*variable "\(.*\)".*/\1/' | sort -u)

if [ -z "$VARS" ]; then
  log_error "No variables found in .tf files"
  empty_json
fi

VALUES=$(echo "$VARS" | sed 's|^|jsonencode(var.|;s|$|)|' | $TF_CMD console $CONSOLE_ARGS 2>/dev/null)

if [ $? -ne 0 ]; then
  log_error "$TF_CMD console failed"
  empty_json
fi

OUTPUT=$(paste <(echo "$VARS") <(echo "$VALUES") | \
  awk -F'\t' 'BEGIN{printf "{"} {printf "%s\"%s\":%s", sep, $1, $2; sep=","} END{printf "}"}' | \
  jq . 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$OUTPUT" ]; then
  log_error "Failed to generate JSON output"
  empty_json
fi

echo "$OUTPUT"
