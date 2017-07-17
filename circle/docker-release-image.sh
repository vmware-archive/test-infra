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

DOCKER_PROJECT=${DOCKER_PROJECT:-bitnami}
QUAY_PROJECT=${QUAY_PROJECT:-bitnami}
GCLOUD_PROJECT=${GCLOUD_PROJECT:-bitnami-containers}

IMAGE_TAG=${CIRCLE_TAG#che-*}

TAGS_TO_UPDATE+=($IMAGE_TAG)

# RELEASE_SERIES_LIST will be an array of comma separated release series
if [[ -n $RELEASE_SERIES_LIST && -z $LATEST_STABLE ]]; then
  error "Found a list of release series defined but 'LATEST_STABLE' is undefined."
  error "You should mark one of the list of release series as 'LATEST_STABLE'"
  exit 1
fi
IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"

MATCHING_RS_FOUND=0
for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
  if [[ "$IMAGE_TAG" == "$RS"* ]]; then
    RELEASE_SERIES=$RS
    let MATCHING_RS_FOUND+=1
    TAGS_TO_UPDATE+=($RELEASE_SERIES)
  fi
done

if [[ $MATCHING_RS_FOUND > 1 ]]; then
  error "Found several possible release series that matches $IMAGE_TAG."
  error "Please review the definition of possible release series"
  exit 1
fi

if [[ -n $RELEASE_SERIES ]]; then
  if [[ $RELEASE_SERIES == $LATEST_STABLE ]]; then
    TAGS_TO_UPDATE+=('latest')
  fi
else
  TAGS_TO_UPDATE+=('latest')
fi

DOCKERFILE=${DOCKERFILE:-Dockerfile}
SUPPORTED_VARIANTS="dev onbuild buildpack"

CHART_IMAGE=${CHART_IMAGE:-$DOCKER_PROJECT/$IMAGE_NAME:$IMAGE_TAG}
CHART_REPO=${CHART_REPO:-https://github.com/bitnami/charts}

GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-Bitnami Containers}
GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-containers@bitnami.com}

GITHUB_TOKEN=${GITHUB_TOKEN:-$GITHUB_PASSWORD}   # required by hub
export GITHUB_TOKEN

SKIP_CHART_PULL_REQUEST=${SKIP_CHART_PULL_REQUEST:-0}

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
  local IMAGE_BUILD_ORIGIN

  case "${IMAGE_BUILD_TAG%%/*}" in
    "quay.io" ) IMAGE_BUILD_ORIGIN=QUAY ;;
    "gcr.io" ) IMAGE_BUILD_ORIGIN=GCR ;;
  esac

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
  if ! docker_build ${1} ${2}; then
    return 1
  fi
  docker_push ${1}
}

gcloud_docker_push() {
  local IMAGE_BUILD_TAG=${1}

  info "Pushing '${IMAGE_BUILD_TAG}'..."
  gcloud docker -- push $IMAGE_BUILD_TAG

  for VARIANT in $SUPPORTED_VARIANTS
  do
    if [[ -f $RS/$VARIANT/Dockerfile ]]; then
      info "Pushing '${IMAGE_BUILD_TAG}-${VARIANT}'..."
      gcloud docker -- push $IMAGE_BUILD_TAG-$VARIANT
    fi
  done
}

gcloud_login() {
  info "Authenticating with Google Cloud..."
  echo $GCLOUD_SERVICE_KEY | base64 --decode > ${HOME}/gcloud-service-key.json
  gcloud auth activate-service-account --key-file ${HOME}/gcloud-service-key.json
}

docker_build_and_gcloud_push() {
  if ! docker_build ${1} ${2}; then
    return 1
  fi
  gcloud_docker_push ${1}
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

HELM_VERSION=2.4.2
install_helm() {
  if ! which helm >/dev/null ; then
    log "Downloading helm..."
    if ! wget -q https://storage.googleapis.com/kubernetes-helm/helm-v${HELM_VERSION}-linux-amd64.tar.gz; then
      log "Could not download helm..."
      return 1
    fi

    log "Installing helm..."
    if ! tar zxf helm-v${HELM_VERSION}-linux-amd64.tar.gz --strip 1 linux-amd64/helm; then
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
  local CHART_NEW_IMAGE_VERSION=${2#*:}
  local CHART_CURRENT_IMAGE_VERSION=$(grep ${2%:*} ${1}/values.yaml)
  local CHART_CURRENT_IMAGE_VERSION=${CHART_CURRENT_IMAGE_VERSION##*:}
  case $(vercmp $CHART_CURRENT_IMAGE_VERSION $CHART_NEW_IMAGE_VERSION) in
    "0" )
      warn "Chart image has not changed!"
      return 1
      ;;
    "-1" )
      info "Chart image version is higher"
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

chart_update_appVersion() {
  local CHART_IMAGE_VERSION=${2#*:}
  local CHART_CURRENT_APP_VERSION=$(grep ^appVersion ${1}/Chart.yaml | awk '{print $2}')
  local CHART_NEW_APP_VERSION=${CHART_IMAGE_VERSION%%-*}

  # adds appVersion field if its not present
  if ! grep -q ^appVersion ${1}/Chart.yaml; then
    sed -i '/^version/a appVersion: ' ${1}/Chart.yaml
  fi

  if [[ $(vercmp $CHART_CURRENT_APP_VERSION $CHART_NEW_APP_VERSION) -ne 0 ]]; then
    info "Updating chart appVersion to '$CHART_NEW_APP_VERSION'..."
    sed -i 's|^appVersion:.*|appVersion: '"${CHART_NEW_APP_VERSION}"'|g' ${1}/Chart.yaml
    git add ${1}/Chart.yaml
    git commit -m "$CHART_NAME: bump chart appVersion to \`$CHART_NEW_APP_VERSION\`" >/dev/null
  fi
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
    git add ${1}/Chart.yaml
    git commit -m "$CHART_NAME: bump chart version to \`$CHART_VERSION_NEXT\`" >/dev/null
  fi
}

if [[ -n $DOCKER_PASS ]]; then
  docker_login || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$TAG $RELEASE_SERIES || exit 1

    # workaround: publish dreamfactory docker image to dreamfactorysoftware/df-docker as well
    if [[ $IMAGE_NAME == dreamfactory ]]; then
      docker_build_and_push dreamfactorysoftware/df-docker:$TAG $RELEASE_SERIES || exit 1
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

if [[ -n $QUAY_PASS ]]; then
  docker_login quay.io || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_push quay.io/$QUAY_PROJECT/$IMAGE_NAME:$TAG $RELEASE_SERIES || exit 1
  done
fi

if [[ -n $GCLOUD_SERVICE_KEY ]]; then
  gcloud_login || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_gcloud_push gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$TAG $RELEASE_SERIES || exit 1
  done
fi

if [ -n "$STACKSMITH_API_KEY" ]; then
  info "Registering image release '$IMAGE_TAG' with Stacksmith..."
  curl "https://stacksmith.bitnami.com/api/v1/components/$IMAGE_NAME/versions?api_key=$STACKSMITH_API_KEY" \
    -H 'Content-Type: application/json' \
    --data '{"version": "'"${IMAGE_TAG%-r*}"'", "revision": "'"${IMAGE_TAG#*-r}"'", "published": true}'
fi

if [[ -n $CHART_REPO ]]; then
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

    if [[ -z $CHART_PATH ]]; then
      error "Chart '$CHART_NAME' could not be found in '$CHART_REPO' repo"
      exit 1
    fi

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
      chart_update_appVersion $CHART_PATH $CHART_IMAGE

      info "Publishing branch to remote repo..."
      git push development $CHART_NAME-$CHART_VERSION_NEXT >/dev/null

      if [[ $SKIP_CHART_PULL_REQUEST -eq 0 && -z $BRANCH_AMEND_COMMITS ]]; then
        install_hub || exit 1

        info "Creating pull request with '$CHART_REPO' repo..."
        if ! hub pull-request -m "[$CHART_PATH] Release $CHART_VERSION_NEXT"; then
          error "Could not create pull request"
          exit 1
        fi

        # auto merge updates to https://github.com/bitnami/charts
        if [[ $CHART_REPO == "https://github.com/bitnami/charts" ]]; then
          info "Auto-merging $CHART_NAME-$CHART_VERSION_NEXT..."
          git checkout master >/dev/null
          git merge --no-ff $CHART_NAME-$CHART_VERSION_NEXT >/dev/null
          git remote remove origin >/dev/null
          git remote add origin https://$GITHUB_USER@$(echo ${CHART_REPO/https:\/\/}).git >/dev/null
          git push origin master >/dev/null
        fi
      fi

      info "Cleaning up old branches..."
      git fetch development >/dev/null
      for branch in $(git branch --remote --list development/$CHART_NAME-* | sed 's?.*development/??' | grep -v "^$CHART_NAME-$CHART_VERSION_NEXT$")
      do
        log "Deleting $branch..."
        git push development :$branch >/dev/null
      done
    else
      warn "Chart release/updates skipped!"
    fi
  fi
fi
