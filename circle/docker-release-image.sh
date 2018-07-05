#!/bin/bash -e

# Copyright 2016 - 2017 Bitnami
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

CIRCLE_CI_FUNCTIONS_URL=${CIRCLE_CI_FUNCTIONS_URL:-https://raw.githubusercontent.com/bitnami/test-infra/master/circle/functions}
source <(curl -sSL $CIRCLE_CI_FUNCTIONS_URL)

# RELEASE_SERIES_LIST will be an array of comma separated release series
if [[ -n $RELEASE_SERIES_LIST && -z $LATEST_STABLE ]]; then
  error "Found a list of release series defined but 'LATEST_STABLE' is undefined."
  error "You should mark one of the list of release series as 'LATEST_STABLE'"
  exit 1
fi
IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"

if is_base_image; then
  TARGET_BRANCH="$(get_target_branch "${IMAGE_TAG}" "${RELEASE_SERIES_ARRAY[@]}")"
  BUILD_DIR="${TARGET_BRANCH}"
  CACHE_TAG="${BUILD_DIR}"

  # Example of tags to update:
  #  - is latest base image:     distro distro-r68 latest
  #  - is not latest base image: distro distro-r68
  TAGS_TO_UPDATE=($IMAGE_TAG $ROLLING_IMAGE_TAG)
  if [[ $TARGET_BRANCH == $LATEST_STABLE && $LATEST_TAG_SOURCE == "LATEST_STABLE" ]]; then
    TAGS_TO_UPDATE+=('latest')
  fi
else
  DISTRO="$(get_distro "${IMAGE_TAG}")"
  IS_DEFAULT_DISTRO=1
  if ! is_default_distro "${DISTRO}"; then
    IS_DEFAULT_DISTRO=0
    if [[ "${DISTRO}" = "rhel-"* ]]; then
      info "Skipped publishing ${DISTRO} image: RHEL releases are disabled."
      exit 0
    fi
  fi

  VARIANT="$(get_variant "${IMAGE_TAG}" "${DISTRO}")"

  IS_DEFAULT_IMAGE=1
  if ! is_default_image "${DISTRO}" "${VARIANT}"; then
      IS_DEFAULT_IMAGE=0
  fi

  TARGET_BRANCH="$(get_target_branch "${IMAGE_TAG}" "${RELEASE_SERIES_ARRAY[@]}")"

  BUILD_DIR="${TARGET_BRANCH}"
  if [ -n "${VARIANT}" ]; then
    BUILD_DIR+="-${VARIANT}"
  fi

  CACHE_TAG=${BUILD_DIR}-${DISTRO}

  # TODO(jdrios) remove the conditional once debian-8 is fully deprecated
  if [[ "${DISTRO}" != "debian-8" ]]; then
    BUILD_DIR+="/${DISTRO}"
  fi

  # Example of tags to update:
  #  - is default distro:     1.2-distro 1.2.3-distro 1.2.3-distro-r1 1.2 1.2.3 1.2.3-r1 latest
  #  - is not default distro: 1.2-distro 1.2.3-distro 1.2.3-distro-r1
  TAGS_TO_UPDATE+=($CACHE_TAG $IMAGE_TAG $ROLLING_IMAGE_TAG)
  if [[ "${IS_DEFAULT_DISTRO}" == 1 ]]; then
    TAGS_TO_UPDATE+=(${CACHE_TAG//-$DISTRO/} ${IMAGE_TAG//-$DISTRO/} ${ROLLING_IMAGE_TAG//-$DISTRO/})
    if [[ $TARGET_BRANCH == $LATEST_STABLE && $LATEST_TAG_SOURCE == "LATEST_STABLE" ]]; then
      TAGS_TO_UPDATE+=('latest')
    fi
  fi
fi

# Execute custom pre-release scripts
if [[ -d .circleci/scripts/pre-release.d/ ]]; then
  for script in $(find .circleci/scripts/pre-release.d/*.sh | sort -n)
  do
    info "Triggering $script..."
    source $script
  done
fi
if [[ -n $DOCKER_PROJECT && -n $DOCKER_PASS ]]; then
  docker_login || exit 1
  echo "The following tags will be updated: ${TAGS_TO_UPDATE[@]}"
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$TAG $BUILD_DIR ${CACHE_TAG:+$DOCKER_PROJECT/$IMAGE_NAME:$CACHE_TAG} || exit 1

    # workaround: publish dreamfactory docker image to dreamfactorysoftware/df-docker as well
    if [[ $IMAGE_NAME == dreamfactory ]]; then
      docker_build_and_push dreamfactorysoftware/df-docker:$TAG $BUILD_DIR ${CACHE_TAG:+$DOCKER_PROJECT/$IMAGE_NAME:$CACHE_TAG} || exit 1
      if [[ -f README.md ]]; then
        if ! curl -sSf "https://hub.docker.com/v2/users/login/" \
          -H "Content-Type: application/json" \
          --data '{"username": "'${DOCKER_USER}'", "password": "'${DOCKER_PASS}'"}' -o /tmp/token.json; then
          return 1
        fi
        DOCKER_TOKEN=$(grep token /tmp/token.json | cut -d':' -f2 | cut -d'"' -f2)

        info "Updating image description on Docker Hub..."
        echo "{\"full_description\": \"$(sed 's/bitnami\/dreamfactory:latest/dreamfactorysoftware\/df-docker:latest/g' README.md | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed -E ':a;N;$!ba;s/\r{0,1}\n/\\n/g')\"}" > /tmp/description.json
        if ! curl -sSf "https://hub.docker.com/v2/repositories/dreamfactorysoftware/df-docker/" -o /dev/null \
          -H "Content-Type: application/json" \
          -H "Authorization: JWT ${DOCKER_TOKEN}" \
          -X PATCH --data @/tmp/description.json; then
          return 1
        fi
      fi
    fi
  done
fi

if [[ -n $QUAY_PROJECT && -n $QUAY_PASS ]]; then
  docker_login quay.io || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_push quay.io/$QUAY_PROJECT/$IMAGE_NAME:$TAG $BUILD_DIR ${CACHE_TAG:+$DOCKER_PROJECT/$IMAGE_NAME:$CACHE_TAG} || exit 1
  done
fi

if [[ -n $GCLOUD_PROJECT && -n $GCLOUD_SERVICE_KEY ]]; then
  gcloud_login || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_gcloud_push gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$TAG $BUILD_DIR ${CACHE_TAG:+$DOCKER_PROJECT/$IMAGE_NAME:$CACHE_TAG} || exit 1
  done
fi

# For now we will only publish debian-8 images to Azure Registry
if [[ "${DISTRO}" == "debian-8" && -n $AZURE_PROJECT && -n $AZURE_PORTAL_PASS && -n $AZURE_PORTAL_USER ]]; then
  az_login || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_push $AZURE_PORTAL_REGISTRY.azurecr.io/$AZURE_PROJECT/$IMAGE_NAME:$TAG $BUILD_DIR ${CACHE_TAG:+$DOCKER_PROJECT/$IMAGE_NAME:$CACHE_TAG} || exit 1
  done
fi

if [[ -n $IBM_PROJECT && -n $IBM_API_KEY ]]; then
  ibm_login || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_push registry.ng.bluemix.net/$IBM_PROJECT/$IMAGE_NAME:$TAG $BUILD_DIR ${CACHE_TAG:+$DOCKER_PROJECT/$IMAGE_NAME:$CACHE_TAG} || exit 1
  done
fi

if [[ -n $CHART_REPO && -n $CHART_NAME && -n $DOCKER_PROJECT && -n $DOCKER_PASS && "${IS_DEFAULT_IMAGE}" == 1 ]]; then
  # perform chart updates only for the specified LATEST_STABLE release
  if [[ -n $LATEST_STABLE && "$IMAGE_TAG" == "$LATEST_STABLE"* ]] || [[ -z $LATEST_STABLE ]]; then
    # Update main chart repository
    info "Going to update main chart repository"
    update_chart_in_repo $CHART_REPO
    info "Updated $CHART_NAME in main repository"

    # Also update extra chart repository if exists
    if [[ -n $EXTRA_CHART_REPOS_LIST ]]; then
      IFS=',' read -ra CHART_REPOS_TO_UPDATE_ARRAY <<< "$EXTRA_CHART_REPOS_LIST"
      for chart_repository in ${CHART_REPOS_TO_UPDATE_ARRAY[@]}
      do
        info "Going to update $CHART_NAME in $chart_repository repository"
        update_chart_in_repo $chart_repository
      	info "Updated $CHART_NAME in $chart_repository repository"
      done
    fi

  fi
fi

# Execute custom post-release scripts
if [[ -d .circleci/scripts/post-release.d/ ]]; then
  for script in $(find .circleci/scripts/post-release.d/*.sh | sort -n)
  do
    info "Triggering $script..."
    source $script
  done
fi
