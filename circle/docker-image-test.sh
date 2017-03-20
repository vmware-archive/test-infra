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
SUPPORTED_VARIANTS="onbuild buildpack"

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

docker_build() {
  local IMAGE_BUILD_TAG=${1}
  local IMAGE_BUILD_DIR=${2:-.}
  local IMAGE_BUILD_ORIGIN=${3}

  if [[ -n $IMAGE_BUILD_ORIGIN ]]; then
    echo "ENV BITNAMI_CONTAINER_ORIGIN=$IMAGE_BUILD_ORIGIN" >> $IMAGE_BUILD_DIR/$DOCKERFILE
  fi

  info "Building '${IMAGE_BUILD_TAG}'..."
  if [[ ! -f $IMAGE_BUILD_DIR/$DOCKERFILE ]]; then
    error "$IMAGE_BUILD_DIR/$DOCKERFILE does not exist"
    return 1
  fi

  docker build --rm=false -f $IMAGE_BUILD_DIR/$DOCKERFILE -t $IMAGE_BUILD_TAG $IMAGE_BUILD_DIR
  for VARIANT in $SUPPORTED_VARIANTS
  do
    if [[ -f $RS/$VARIANT/Dockerfile ]]; then
      info "Building '${IMAGE_BUILD_TAG}-${VARIANT}'..."
      echo -e "FROM $IMAGE_BUILD_TAG\n$(cat $RS/$VARIANT/Dockerfile)" | \
        docker build --rm=false -t $IMAGE_BUILD_TAG-$VARIANT -
    fi
  done
}

if [[ -n $RELEASE_SERIES_LIST ]]; then
  IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
  for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
    docker_build $DOCKER_PROJECT/$IMAGE_NAME:$RS-$CIRCLE_BUILD_NUM $RS || exit 1
  done
else
  docker_build $DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_BUILD_NUM . || exit 1
fi
