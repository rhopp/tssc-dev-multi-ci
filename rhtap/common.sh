#!/bin/bash
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

# Manages the custom root CA for system-wide trust
setup_custom_ca() {
  local ca_file_path="/etc/pki/ca-trust/source/anchors/custom-provided-ca.crt"
  local ca_env_var_name="CUSTOM_ROOT_CA"
  local run_update_ca_trust=false

  if [[ -n "${!ca_env_var_name:-}" ]]; then
    # CA content is provided
    local current_ca_content="${!ca_env_var_name}"
    if [[ -f "$ca_file_path" ]]; then
      local existing_ca_content
      existing_ca_content=$(cat "$ca_file_path")
      if [[ "$current_ca_content" != "$existing_ca_content" ]]; then
        echo "INFO: Custom CA content differs or file exists with different content. Updating $ca_file_path." >&2
        # Deliberately using subshell for tee to handle potential permission errors gracefully if any part of the path doesn't exist initially for tee.
        # The script should generally run with permissions to write to this path.
        if ! (echo "${current_ca_content}" | sudo tee "$ca_file_path" > /dev/null); then
            echo "ERROR: Failed to write custom CA to $ca_file_path. Permissions issue?" >&2
            # Decide if this is a fatal error or if scripts can proceed without custom CA
            return 1 # Or some other error handling
        fi
        run_update_ca_trust=true
      else
        # echo "DEBUG: Custom CA file $ca_file_path already exists with the correct content." >&2
        : # No change needed, content is the same
      fi
    else
      echo "INFO: Custom CA file $ca_file_path does not exist. Creating it." >&2
      if ! (echo "${current_ca_content}" | sudo tee "$ca_file_path" > /dev/null); then
        echo "ERROR: Failed to write custom CA to $ca_file_path. Permissions issue?" >&2
        return 1 # Or some other error handling
      fi
      run_update_ca_trust=true
    fi
  else
    # CA content is NOT provided
    if [[ -f "$ca_file_path" ]]; then
      echo "INFO: CUSTOM_ROOT_CA is not set. Removing existing custom CA file $ca_file_path." >&2
      if ! sudo rm -f "$ca_file_path"; then
        echo "ERROR: Failed to remove custom CA file $ca_file_path. Permissions issue?" >&2
        # Non-fatal, but system trust might be stale if update-ca-trust doesn't run or CA is still present
      fi
      run_update_ca_trust=true
    else
      # echo "DEBUG: CUSTOM_ROOT_CA is not set and $ca_file_path does not exist. Nothing to do." >&2
      : # No CA provided, and no old CA file to remove
    fi
  fi

  if [[ "$run_update_ca_trust" = true ]]; then
    echo "INFO: Running update-ca-trust to apply CA changes." >&2
    if ! sudo update-ca-trust; then
      echo "ERROR: 'update-ca-trust' command failed." >&2
      # Decide if this is a fatal error
      return 1 # Or some other error handling
    fi
  # else
    # echo "DEBUG: No changes to custom CA, update-ca-trust not required." >&2
  fi
  return 0
}
setup_custom_ca
# Consider checking the return status of setup_custom_ca if it can fail fatally
# if ! setup_custom_ca; then
#   echo "ERROR: Failed to set up custom CA. Exiting." >&2
#   exit 1
# fi

# Vars for scripts
# Generated patterns to convert from Tekton.

# exit 0, write Succeeded to STATUS result
function exit_with_success_result() {
    echo "Succeeded" > $RESULTS/STATUS
    exit 0
}

# exit 1, write Failed to STATUS result
function exit_with_fail_result() {
    echo "Failed" > $RESULTS/STATUS
    exit 1
}

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

prepare-registry-user-pass() {
    local image_registry="$1"
    #
    # Check if the IMAGE_REGISTRY_USER and IMAGE_REGISTRY_PASSWORD are set and if not
    # compute the values from the image name (backward compitable with prior naming).
    #
    # Users should set IMAGE_REGISTRY_USER and IMAGE_REGISTRY_PASSWORD for the registry.
    # For backwards compatibility use the ARTIFACTORY or NEXUS or QUAY creds in place
    # and this code will determine which one to use.
    #
    if [[ -z "${IMAGE_REGISTRY_USER-""}" || -z "${IMAGE_REGISTRY_PASSWORD-""}" ]]; then
        # Determine credentials based on the registry
        echo "Using $image_registry to determine quay, nexus or artifactory"
        echo "Set IMAGE_REGISTRY_USER and IMAGE_REGISTRY_PASSWORD secrets to override detection"
        if [[ "$image_registry" == *"artifactory"* || "$image_registry" == *"jfrog"* ]]; then
            IMAGE_REGISTRY_USER="$ARTIFACTORY_IO_CREDS_USR"
            IMAGE_REGISTRY_PASSWORD="$ARTIFACTORY_IO_CREDS_PSW"
        elif [[ "$image_registry" == *"nexus"* ]]; then
            IMAGE_REGISTRY_USER="$NEXUS_IO_CREDS_USR"
            IMAGE_REGISTRY_PASSWORD="$NEXUS_IO_CREDS_PSW"
        else
            IMAGE_REGISTRY_USER="$QUAY_IO_CREDS_USR"
            IMAGE_REGISTRY_PASSWORD="$QUAY_IO_CREDS_PSW"
        fi
    else
        echo "Using IMAGE_REGISTRY_USER and IMAGE_REGISTRY_PASSWORD secrets for registry auth"
    fi
}

# Performs an image registry login. It takes a single parameter which could be either an image
# registry, e.g. quay.io, or a full image reference, e.g. quay.io/spam/bacon:crispy.
function registry-login() {
    local image_ref="$1"
    local image_registry="${image_ref/\/*/}"
    prepare-registry-user-pass "${image_registry}"
    # There are different tools that we can use to login to a registry. Here we choose to use cosign
    # because it's commonly used across the different tasks.
    cosign login --username="${IMAGE_REGISTRY_USER}" --password="${IMAGE_REGISTRY_PASSWORD}" "${image_registry}"
    ERR=$?
    if [ $ERR != 0 ]; then
        echo "Failed registry login ${image_registry} for user ${IMAGE_REGISTRY_USER}"
        exit $ERR
    fi
}

DIR=$(pwd)
export TASK_NAME=$(basename $0 .sh)
export BASE_RESULTS=$DIR/results
export RESULTS=$BASE_RESULTS/$TASK_NAME
export TEMP_DIR=$DIR/results/temp
# clean results per build
rm -rf $RESULTS
mkdir -p $RESULTS
mkdir -p $TEMP_DIR
mkdir -p $TEMP_DIR/files
echo
echo "Step: $TASK_NAME"
echo "Results: $RESULTS"
export PATH=$PATH:/usr/local/bin

# env.sh comes from the users repo in rhtap/env.sh
source $DIR/rhtap/env.sh
