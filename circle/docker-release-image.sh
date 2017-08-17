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

TAGS_TO_UPDATE+=($IMAGE_TAG)

if [[ -n $RELEASE_SERIES ]]; then
  if [[ $RELEASE_SERIES == $LATEST_STABLE ]]; then
    TAGS_TO_UPDATE+=('latest')
  fi
else
  TAGS_TO_UPDATE+=('latest')
fi

if [[ -n $DOCKER_PROJECT && -n $DOCKER_PASS ]]; then
  docker_login || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$TAG $RELEASE_SERIES $DOCKER_PROJECT/$IMAGE_NAME:$RELEASE_SERIES || exit 1

    # workaround: publish dreamfactory docker image to dreamfactorysoftware/df-docker as well
    if [[ $IMAGE_NAME == dreamfactory ]]; then
      docker_build_and_push dreamfactorysoftware/df-docker:$TAG $RELEASE_SERIES $DOCKER_PROJECT/$IMAGE_NAME:$RELEASE_SERIES || exit 1
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
    docker_build_and_push quay.io/$QUAY_PROJECT/$IMAGE_NAME:$TAG $RELEASE_SERIES $DOCKER_PROJECT/$IMAGE_NAME:$RELEASE_SERIES || exit 1
  done
fi

if [[ -n $GCLOUD_PROJECT && -n $GCLOUD_SERVICE_KEY ]]; then
  gcloud_login || exit 1
  for TAG in "${TAGS_TO_UPDATE[@]}"; do
    docker_build_and_gcloud_push gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$TAG $RELEASE_SERIES $DOCKER_PROJECT/$IMAGE_NAME:$RELEASE_SERIES || exit 1
  done
fi

if [ -n "$STACKSMITH_API_KEY" ]; then
  info "Registering image release '$IMAGE_TAG' with Stacksmith..."
  curl "https://stacksmith.bitnami.com/api/v1/components/$IMAGE_NAME/versions?api_key=$STACKSMITH_API_KEY" \
    -H 'Content-Type: application/json' \
    --data '{"version": "'"${IMAGE_TAG%-r*}"'", "revision": "'"${IMAGE_TAG#*-r}"'", "published": true}'
fi

if [[ -n $CHART_REPO && -n $CHART_NAME && -n $DOCKER_PROJECT && -n $DOCKER_PASS ]]; then
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
    chart_update_appVersion $CHART_PATH $CHART_IMAGE
    chart_update_version $CHART_PATH $CHART_VERSION_NEXT

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
