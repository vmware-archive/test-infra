#!/bin/bash -e

# Copyright 2016 Bitnami
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

DOCKER_PROJECT=${DOCKER_PROJECT:-bitnami}
DOCKERFILE=${DOCKERFILE:-Dockerfile}

IMAGE_TAG=${CIRCLE_TAG#che-*}

CHART_IMAGE=${CHART_IMAGE:-$DOCKER_PROJECT/$IMAGE_NAME:$IMAGE_TAG}
CHART_REPO=${CHART_REPO:-https://github.com/bitnami/charts}

GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-Bitnami Containers}
GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-containers@bitnami.com}

GITHUB_TOKEN=${GITHUB_TOKEN:-$GITHUB_PASSWORD}   # required by hub
export GITHUB_TOKEN

DISABLE_PULL_REQUEST=${DISABLE_PULL_REQUEST:-0}

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
  info "Authenticating with Docker Hub..."
  docker login -e $DOCKER_EMAIL -u $DOCKER_USER -p $DOCKER_PASS
}

docker_build() {
  info "Building '${1}' image..."
  docker build --rm=false -f $DOCKERFILE -t ${1} .
}

docker_push() {
  info "Pushing '${1}' image..."
  docker push ${1}
}

docker_build_and_push() {
  docker_build ${1} && docker_push ${1}
}

gcloud_docker_push() {
  info "Pushing '${1}' image..."
  gcloud docker -- push ${1}
}

gcloud_login() {
  info "Authenticating with Google Cloud..."
  echo $GCLOUD_SERVICE_KEY | base64 --decode > ${HOME}/gcloud-service-key.json
  gcloud auth activate-service-account --key-file ${HOME}/gcloud-service-key.json
}

docker_build_and_gcloud_push() {
  docker_build ${1} && gcloud_docker_push ${1}
}

git_configure() {
  git config --global user.name "$GIT_AUTHOR_NAME"
  git config --global user.email "$GIT_AUTHOR_EMAIL"

  if [[ -n $GITHUB_USER && -n $GITHUB_PASSWORD ]]; then
    git config --global credential.helper store
    echo "https://$GITHUB_USER:$GITHUB_PASSWORD@github.com" > ~/.git-credentials
  fi
}

git_create_branch() {
  git fetch development 2>/dev/null || return 1
  if ! git checkout $1-$2 2>/dev/null; then
    info "Creating branch for new pull-request..."
    git checkout -b $1-$2
  else
    info "Amending updates to existing branch..."
    BRANCH_AMEND_COMMITS=1
  fi
  return 0
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

install_hub() {
  if ! which hub >/dev/null ; then
    info "Downloading hub..."
    if ! wget -q https://github.com/github/hub/releases/download/v2.2.9/hub-linux-amd64-2.2.9.tgz; then
      error "Could not download hub..."
      return 1
    fi

    info "Installing hub..."
    if ! tar zxf hub-linux-amd64-2.2.9.tgz --strip 2 hub-linux-amd64-2.2.9/bin/hub; then
      error "Could not install hub..."
      return 1
    fi
    chmod +x hub
    sudo mv hub /usr/local/bin/hub

    if ! hub version; then
      return 1
    fi
  fi
}

install_helm() {
  if ! which helm >/dev/null ; then
    log "Downloading helm..."
    if ! wget -q https://storage.googleapis.com/kubernetes-helm/helm-v2.1.3-linux-amd64.tar.gz; then
      log "Could not download helm..."
      return 1
    fi

    log "Installing helm..."
    if ! tar zxf helm-v2.1.3-linux-amd64.tar.gz --strip 1 linux-amd64/helm; then
      log "Could not install helm..."
      return 1
    fi
    chmod +x helm
    sudo mv helm /usr/local/bin/helm

    if ! helm version --client; then
      return 1
    fi

    if ! helm init --client-only >/dev/null; then
      return 1
    fi
  fi
}

chart_update_image() {
  CHART_NEW_IMAGE_VERSION=${2#*:}
  CHART_CURRENT_IMAGE_VERSION=$(grep ${2%:*} ${1}/values.yaml)
  CHART_CURRENT_IMAGE_VERSION=${CHART_CURRENT_IMAGE_VERSION##*:}
  case $(vercmp $CHART_CURRENT_IMAGE_VERSION $CHART_NEW_IMAGE_VERSION) in
    "0" )
      warn "Chart image has not changed!"
      return 1
      ;;
    "-1" )
      warn "Chart image cannot be downgraded!"
      return 1
      ;;
    "1" )
      info "Updating chart image to '${2}'..."
      sed -i 's|image: '"${2%:*}"':.*|image: '"${2}"'|' ${1}/values.yaml
      git add ${1}/values.yaml
      git commit -m "$CHART_NAME: update to \`${2}\`" >/dev/null
      ;;
  esac
}

chart_update_requirements() {
  if [[ -f ${1}/requirements.lock ]]; then
    install_helm || exit 1

    rm -rf ${1}/requirements.lock
    helm dependency update ${1} >/dev/null

    if git diff | grep -q '^+[ ]*version:' ; then
      info "Updating chart requirements.lock..."
      git add ${1}/requirements.lock
      git commit -m "$CHART_NAME: updated chart requirements" >/dev/null
    else
      git checkout ${1}/requirements.lock
    fi
  fi
}

chart_update_version() {
  if [[ -z $BRANCH_AMEND_COMMITS ]]; then
    info "Updating chart version to '$2'..."
    sed -i 's|^version:.*|version: '"${2}"'|g' ${1}/Chart.yaml
    git add $CHART_PATH/Chart.yaml
    git commit -m "$CHART_NAME: bump chart version to \`$CHART_VERSION_NEXT\`" >/dev/null
  fi
}

if [[ -n $DOCKER_PASS ]]; then
  docker_login                                                  || exit 1
  docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:_           || exit 1
  docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:latest      || exit 1
  docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$IMAGE_TAG  || exit 1
fi

if [[ -n $GCLOUD_SERVICE_KEY ]]; then
  echo 'ENV BITNAMI_CONTAINER_ORIGIN=GCR' >> Dockerfile

  gcloud_login                                                                || exit 1
  docker_build_and_gcloud_push gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:latest      || exit 1
  docker_build_and_gcloud_push gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$IMAGE_TAG  || exit 1
fi

if [ -n "$STACKSMITH_API_KEY" ]; then
  info "Registering image release '$IMAGE_TAG' with Stacksmith..."
  curl "https://stacksmith.bitnami.com/api/v1/components/$IMAGE_NAME/versions?api_key=$STACKSMITH_API_KEY" \
    -H 'Content-Type: application/json' \
    --data '{"version": "'"${IMAGE_TAG%-r*}"'", "revision": "'"${IMAGE_TAG#*-r}"'", "published": true}'
fi

if [[ -n $CHART_NAME && -n $DOCKER_PASS ]]; then
  info "Cloning '$CHART_REPO' repo..."
  if ! git clone --quiet --single-branch $CHART_REPO charts; then
    error "Could not clone $CHART_REPO..."
    exit 1
  fi
  cd charts

  # add development remote
  git remote add development https://$GITHUB_USER@github.com/$GITHUB_USER/$(echo ${CHART_REPO/https:\/\/github.com\/} | tr / -).git

  # lookup chart in the chart repo
  CHART_PATH=
  for d in $(find * -type d -name $CHART_NAME )
  do
    if [ -f $d/Chart.yaml ]; then
      CHART_PATH=$d
      break
    fi
  done

  if [[ -n $CHART_PATH ]]; then
    if [[ -z $GITHUB_USER || -z $GITHUB_PASSWORD ]]; then
      error "GitHub credentials not configured. Aborting..."
      exit 1
    fi

    git_configure

    # generate next chart version
    CHART_VERSION=$(grep '^version:' $CHART_PATH/Chart.yaml | awk '{print $2}')
    CHART_VERSION_NEXT="${CHART_VERSION%.*}.$((${CHART_VERSION##*.}+1))"

    # create a branch for the updates
    git_create_branch $CHART_NAME $CHART_VERSION_NEXT

    if chart_update_image $CHART_PATH $CHART_IMAGE; then
      chart_update_requirements $CHART_PATH
      chart_update_version $CHART_PATH $CHART_VERSION_NEXT

      info "Publishing branch to remote repo..."
      git push development $CHART_NAME-$CHART_VERSION_NEXT >/dev/null

      if [[ $DISABLE_PULL_REQUEST -eq 0 && -z $BRANCH_AMEND_COMMITS ]]; then
        install_hub || exit 1

        info "Creating pull request with '$CHART_REPO' repo..."
        if ! hub pull-request -m "[$CHART_PATH] Release $CHART_VERSION_NEXT"; then
          error "Could not create pull request"
          exit 1
        fi
      fi
    else
      warn "Chart release skipped!"
    fi
  else
    info "Chart '$CHART_NAME' could not be found in '$CHART_REPO' repo"
  fi
fi
