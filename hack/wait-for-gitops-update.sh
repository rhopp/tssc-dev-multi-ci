#!/bin/bash
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

# Manages the custom root CA for system-wide trust
setup_custom_ca() {
  local ca_file_path="/etc/pki/ca-trust/source/anchors/custom-provided-ca.crt"
  local ca_env_var_name="CUSTOM_ROOT_CA"
  local run_update_ca_trust=false

  if [[ -n "${!ca_env_var_name:-}" ]]; then
    local current_ca_content="${!ca_env_var_name}"
    if [[ -f "$ca_file_path" ]]; then
      local existing_ca_content
      existing_ca_content=$(cat "$ca_file_path")
      if [[ "$current_ca_content" != "$existing_ca_content" ]]; then
        echo "INFO: Custom CA content differs or file exists with different content. Updating $ca_file_path." >&2
        if ! (echo "${current_ca_content}" | sudo tee "$ca_file_path" > /dev/null); then
            echo "ERROR: Failed to write custom CA to $ca_file_path. Permissions issue?" >&2
            return 1
        fi
        run_update_ca_trust=true
      fi
    else
      echo "INFO: Custom CA file $ca_file_path does not exist. Creating it." >&2
      if ! (echo "${current_ca_content}" | sudo tee "$ca_file_path" > /dev/null); then
        echo "ERROR: Failed to write custom CA to $ca_file_path. Permissions issue?" >&2
        return 1
      fi
      run_update_ca_trust=true
    fi
  else
    if [[ -f "$ca_file_path" ]]; then
      echo "INFO: CUSTOM_ROOT_CA is not set. Removing existing custom CA file $ca_file_path." >&2
      if ! sudo rm -f "$ca_file_path"; then
        echo "ERROR: Failed to remove custom CA file $ca_file_path. Permissions issue?" >&2
      fi
      run_update_ca_trust=true
    fi
  fi

  if [[ "$run_update_ca_trust" = true ]]; then
    echo "INFO: Running update-ca-trust to apply CA changes." >&2
    if ! sudo update-ca-trust; then
      echo "ERROR: 'update-ca-trust' command failed." >&2
      return 1
    fi
  fi
  return 0
}
setup_custom_ca
# Consider checking the return status:
# if ! setup_custom_ca; then
#   echo "ERROR: Failed to set up custom CA in $(basename "$0"). Exiting." >&2
#   exit 1
# fi

GITHUB_REPO=https://github.com/$MY_GITHUB_USER/tssc-dev-gitops
GITLAB_REPO=https://gitlab.com/$MY_GITLAB_USER/tssc-dev-gitops
JENKINS_REPO=https://github.com/$MY_GITHUB_USER/tssc-dev-gitops-jenkins

DEFAULT_INIT_IMAGES=(
    'quay.io/redhat-appstudio/dance-bootstrap-app:latest'
    'registry.redhat.io/ubi9/httpd-24:latest'
)

WORK=$(mktemp -d)

GH_LOCAL=$WORK/gh-gitops
GL_LOCAL=$WORK/gl-gitops
J_LOCAL=$WORK/j-gitops
git clone $GITHUB_REPO $GH_LOCAL --quiet
git clone $GITLAB_REPO $GL_LOCAL --quiet
git clone $JENKINS_REPO $J_LOCAL --quiet
WATCH=components/tssc-dev/overlays/development/deployment-patch.yaml
function getImage() {
    (
        cd $1
        yq .spec.template.spec.containers[0].image $WATCH
    )
}

# Note, the env var name PREV_IMAGE_ENV_NAME is passed so it can be updated
function promoteIfUpdated() {
    PREV_IMAGE_ENV_NAME=$1
    CURRENT_IMAGE=$2
    REPO=$3

    echo "$REPO"
    echo "P: ${!PREV_IMAGE_ENV_NAME}"
    echo "C: $CURRENT_IMAGE"

    DEFAULT_INIT_IMAGE="quay.io/redhat-appstudio/dance-bootstrap-app:latest"
    if [[ "${!PREV_IMAGE_ENV_NAME}" != "$CURRENT_IMAGE" ]]; then
        echo "$REPO dev changes, from ${!PREV_IMAGE_ENV_NAME} to $CURRENT_IMAGE"

        is_default=false
        for default_image in "${DEFAULT_INIT_IMAGES[@]}"; do
            if [[ "$CURRENT_IMAGE" == "$default_image" ]]; then
                echo "Image changed back to default, skipping using PR to promote image"
                is_default=true
                break
            fi
        done

        if ! "$is_default"; then
            bash $SCRIPTDIR/rhtap-promote --repo $REPO
        fi

        eval "$PREV_IMAGE_ENV_NAME"="$CURRENT_IMAGE"
    fi
}
function pushIfUpdated() {
    PREV_IMAGE_ENV_NAME=$1
    CURRENT_IMAGE=$2
    REPO=$3

    echo "$REPO"
    echo "P: ${!PREV_IMAGE_ENV_NAME}"
    echo "C: $CURRENT_IMAGE"

    if [[ "${!PREV_IMAGE_ENV_NAME}" != "$CURRENT_IMAGE" ]]; then
        echo "$REPO dev changes, from ${!PREV_IMAGE_ENV_NAME} to $CURRENT_IMAGE"
        if [[ "$CURRENT_IMAGE" == "$DEFAULT_INIT_IMAGE" ]]; then
            echo "Image changed, skipping reset for default base image"
        else
            # jenkins update the gitops repo with a push and then run the job
            bash $SCRIPTDIR/rhtap-push-dev --repo $REPO
            JOB=$(basename $REPO)
            echo "Running Jenkins Job"
            bash $SCRIPTDIR/jenkins-run-pipeline $JOB
        fi
        eval "$PREV_IMAGE_ENV_NAME"="$CURRENT_IMAGE"
    fi
}

GH_PREV=$(getImage $GH_LOCAL)
GL_PREV=$(getImage $GL_LOCAL)
J_PREV=$(getImage $J_LOCAL)
# count down and reprint the messages
COUNT=0
while true; do
    if [[ $COUNT == 0 ]]; then
        COUNT=10
        echo
        echo "Github Repo: $GITHUB_REPO"
        echo "Waiting for Github image $GH_PREV to be updated"
        echo
        echo "Gitlab Repo: $GITLAB_REPO"
        echo "Waiting for Gitlab image $GL_PREV to be updated"
        echo
        echo "Jenkins Repo: $JENKINS_REPO"
        echo "Waiting for Jenkins image $J_PREV to be updated"
    fi
    let COUNT--

    echo "Checking repo contents ..."
    for repo in $GH_LOCAL $GL_LOCAL $J_LOCAL; do
        (
            cd $repo
            git pull --quiet
        )
    done
    # pass the var name to hold the previus value so it can be updated
    GH_CURRENT=$(getImage $GH_LOCAL)
    promoteIfUpdated GH_PREV $GH_CURRENT $GITHUB_REPO
    GL_CURRENT=$(getImage $GL_LOCAL)
    promoteIfUpdated GL_PREV $GL_CURRENT $GITLAB_REPO
    J_CURRENT=$(getImage $J_LOCAL)
    pushIfUpdated J_PREV $J_CURRENT $JENKINS_REPO
    SLEEP=10
    echo "Sleep..."
    while [[ $SLEEP != 0 ]]; do
        sleep 1
        echo -n "$SLEEP."
        let SLEEP--
    done

done
