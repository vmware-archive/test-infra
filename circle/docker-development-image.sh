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

docker_login() {
  local username=$DOCKER_USER
  local password=$DOCKER_PASS
  local email=$DOCKER_EMAIL
  local registry=${1}
  case "$1" in
    quay.io )
      username=$QUAY_USER
      password=$QUAY_PASS
      email=$QUAY_EMAIL
      ;;
  esac
  info "Authenticating with Docker Hub..."
  docker login -e $email -u $username -p $password $registry
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
    error "$IMAGE_BUILD_DIR/$DOCKERFILE does not exist, please inspect the release configuration in circle.yml"
    return 1
  fi

  docker build --rm=false -f $IMAGE_BUILD_DIR/$DOCKERFILE -t $IMAGE_BUILD_TAG $IMAGE_BUILD_DIR || return 1
  for VARIANT in $SUPPORTED_VARIANTS
  do
    if [[ -f $RS/$VARIANT/Dockerfile ]]; then
      info "Building '${IMAGE_BUILD_TAG}-${VARIANT}'..."
      echo -e "FROM $IMAGE_BUILD_TAG\n$(cat $RS/$VARIANT/Dockerfile)" | \
        docker build --rm=false -t $IMAGE_BUILD_TAG-$VARIANT - || return 1
    fi
  done
}

docker_push() {
  local IMAGE_BUILD_TAG=${1}

  info "Pushing '${IMAGE_BUILD_TAG}'..."
  docker push $IMAGE_BUILD_TAG

  for VARIANT in $SUPPORTED_VARIANTS
  do
    if [[ -f $RS/$VARIANT/Dockerfile ]]; then
      info "Pushing '${IMAGE_BUILD_TAG}-${VARIANT}'..."
      docker push $IMAGE_BUILD_TAG-$VARIANT
    fi
  done
}

docker_build_and_push() {
  if ! docker_build ${1} ${2} ${3}; then
    return 1
  fi
  docker_push ${1}
}

dockerhub_update_description() {
  if [[ -f README.md ]]; then
    if ! curl -sSf "https://hub.docker.com/v2/users/login/" \
      -H "Content-Type: application/json" \
      --data '{"username": "'${DOCKER_USER}'", "password": "'${DOCKER_PASS}'"}' -o /tmp/token.json; then
      return 1
    fi
    DOCKER_TOKEN=$(grep token /tmp/token.json | cut -d':' -f2 | cut -d'"' -f2)

    info "Updating image description on Docker Hub..."
    echo "{\"full_description\": \"$(sed 's/\\/\\\\/g' README.md | sed 's/"/\\"/g' | sed -E ':a;N;$!ba;s/\r{0,1}\n/\\n/g')\"}" > /tmp/description.json
    if ! curl -sSf "https://hub.docker.com/v2/repositories/$DOCKER_PROJECT/$IMAGE_NAME/" -o /dev/null \
      -H "Content-Type: application/json" \
      -H "Authorization: JWT ${DOCKER_TOKEN}" \
      -X PATCH --data @/tmp/description.json; then
      return 1
    fi
  fi
}

if [[ -n $DOCKER_PASS ]]; then
  docker_login || exit 1
  if [[ -n $RELEASE_SERIES_LIST ]]; then
    IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
    for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
      docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$RS-development $RS || exit 1
    done
  else
    docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:development . || exit 1
  fi
  dockerhub_update_description || exit 1
fi
