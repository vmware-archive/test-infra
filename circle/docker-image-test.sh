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

DOCKER_SERVER_VERSION=$(docker version --format '{{.Server.Version}}')
DOCKER_CLIENT_VERSION=$(docker version --format '{{.Client.Version}}')

DOCKERFILE=${DOCKERFILE:-Dockerfile}
SUPPORTED_VARIANTS="dev prod onbuild buildpack"
IMAGE_TAG=${CIRCLE_TAG#che-*}

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

vercmp() {
  if [[ $1 == $2 ]]; then
    echo "0"
  else
    if [[ $( ( echo "$1"; echo "$2" ) | sort -rV | head -n1 ) == $1 ]]; then
      echo "-1"
    else
      echo "1"
    fi
  fi
}

## docker cache load should probably be performed in the circle.yml build steps,
## but we noticed that the cache was not being loaded properly when done this way.
## As a workaround, the cache load/save is being performed from the script itself.
docker_load_cache() {
  if [[ $(vercmp 1.13 ${DOCKER_SERVER_VERSION%%-*}) -ge 0 ]] && [[ -f /cache/layers.tar ]]; then
    log "Loading docker image layer cache..."
    docker load -i /cache/layers.tar
  fi
}

docker_save_cache() {
  if [[ $(vercmp 1.13 ${DOCKER_SERVER_VERSION%%-*}) -ge 0 ]]; then
    log "Saving docker image layer cache..."
    mkdir -p /cache
    docker save -o /cache/layers.tar $1
  fi
}

docker_build() {
  local IMAGE_BUILD_TAG=${1}
  local IMAGE_BUILD_DIR=${2:-.}
  local IMAGE_BUILD_ORIGIN

  case "${IMAGE_BUILD_TAG%%/*}" in
    "quay.io" ) IMAGE_BUILD_ORIGIN=QUAY ;;
    "gcr.io" ) IMAGE_BUILD_ORIGIN=GCR ;;
  esac

  if [[ -n $IMAGE_BUILD_ORIGIN ]]; then
    echo "ENV BITNAMI_CONTAINER_ORIGIN=$IMAGE_BUILD_ORIGIN" >> $IMAGE_BUILD_DIR/$DOCKERFILE
  fi

  if [[ ! -f $IMAGE_BUILD_DIR/$DOCKERFILE ]]; then
    error "$IMAGE_BUILD_DIR/$DOCKERFILE does not exist, please inspect the release configuration in circle.yml"
    return 1
  fi

  info "Building '$IMAGE_BUILD_TAG' from '$IMAGE_BUILD_DIR/'..."
  docker build --rm=false -f $IMAGE_BUILD_DIR/$DOCKERFILE -t $IMAGE_BUILD_TAG $IMAGE_BUILD_DIR || return 1
  for VARIANT in $SUPPORTED_VARIANTS
  do
    if [[ -f $IMAGE_BUILD_DIR/$VARIANT/Dockerfile ]]; then
      info "Building '$IMAGE_BUILD_TAG-$VARIANT' from '$IMAGE_BUILD_DIR/$VARIANT/'..."
      if grep -q "^FROM " $IMAGE_BUILD_DIR/$VARIANT/Dockerfile; then
        docker build --rm=false -t $IMAGE_BUILD_TAG-$VARIANT $IMAGE_BUILD_DIR/$VARIANT/ || return 1
      else
        echo -e "FROM $IMAGE_BUILD_TAG\n$(cat $IMAGE_BUILD_DIR/$VARIANT/Dockerfile)" | docker build --rm=false -t $IMAGE_BUILD_TAG-$VARIANT - || return 1
      fi
    fi
  done
}

docker_load_cache

if [[ -n $RELEASE_SERIES_LIST ]]; then
  IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
  for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
    if [[ -n $IMAGE_TAG ]]; then
      if [[ "$IMAGE_TAG" == "$RS"* ]]; then
        docker_build $DOCKER_PROJECT/$IMAGE_NAME:$RS $RS || exit 1
      fi
    else
      docker_build $DOCKER_PROJECT/$IMAGE_NAME:$RS $RS || exit 1
    fi
  done
else
  docker_build $DOCKER_PROJECT/$IMAGE_NAME . || exit 1
fi

docker_save_cache $DOCKER_PROJECT/$IMAGE_NAME
