#!/bin/bash -e

# Copyright 2017 Bitnami
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

DOCKERFILE=${DOCKERFILE:-Dockerfile}
SUPPORTED_VARIANTS="dev onbuild buildpack"

log() {
  echo -e "$(date "+%T.%2N") ${@}"
}

info() {
  log "INFO  ==> ${@}"
}

warn() {
  log "WARN  ==> ${@}"
}

error() {
  log "ERROR ==> ${@}"
}

docker_pull() {
  local IMAGE_BUILD_TAG=${1}

  info "Pulling '${IMAGE_BUILD_TAG}'..."
  docker pull $IMAGE_BUILD_TAG

  for VARIANT in $SUPPORTED_VARIANTS
  do
    if [[ -f $RS/$VARIANT/Dockerfile ]]; then
      info "Pulling '${IMAGE_BUILD_TAG}-${VARIANT}'..."
      docker pull $IMAGE_BUILD_TAG-$VARIANT
    fi
  done
}

if [[ -n $RELEASE_SERIES_LIST ]]; then
  IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
  for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
    docker_pull $DOCKER_PROJECT/$IMAGE_NAME:$RS-development || true
  done
else
  docker_pull $DOCKER_PROJECT/$IMAGE_NAME:development || true
fi
