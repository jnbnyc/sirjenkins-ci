#!/usr/bin/env bash

set -x # for debugging
# set -e

# docker build job with semantic versioning

# steps required

# find version by project type
# determine if version is replaceable
# if release version determine if it already exists
#     true: FAIL false: continue

# run publish test
# if publish test succeeds, tag container and push to registry

# DEBUG_PREFIX="echo" # for debugging
BIN_DIR=$(dirname "$0")
BUILD_ARGS=""

DOCKER_OPTIONS=${DOCKER_OPTIONS:-}
DOCKER_REPO=${DOCKER_REPO:-}

CONTAINER_PUSH=NO
CONTAINER_TAGS=""
CONTAINER_BUILD_CONTEXT=${CONTAINER_BUILD_CONTEXT:-.}
CONTAINER_BUILD_TAG="$JOB_BASE_NAME-$BUILD_NUMBER"  #  these vars supplied by Jenkins
CONTAINER_BUILD_NAME=$DOCKER_REPO:$CONTAINER_BUILD_TAG

# PROJECT_BRANCH=${PROJECT_BRANCH:-$(git branch | grep -oE '\*\s\K.*$')}
PROJECT_VERSION=$(bash ${BIN_DIR}/get_version.sh ${CONTAINER_BUILD_CONTEXT})

CONTAINER_VERSION_NAME=$DOCKER_REPO:$PROJECT_VERSION


function cleanup() {
    echo 'Stopped Containers'
    docker ps -a --filter "status=exited"

    echo Deleting stopped containers
    docker rm -v $(docker ps -a -q --no-trunc --filter "status=exited") || true

    echo Deleting dangling images
    docker rmi $(docker images -q --no-trunc --filter "dangling=true") || true

    echo Deleting dangling volumes
    docker volume rm $(docker volume ls -q --filter "dangling=true") || true

    echo Running containers are
    docker ps

    echo Remaining images are
    docker images
}


function container_add_tags() {
  case $PROJECT_BRANCH in
    master)
        CONTAINER_TAGS="$CONTAINER_TAGS latest"
        CONTAINER_PUSH=YES
      ;;
    develop)
        CONTAINER_PUSH=YES
      ;;
    release-*)
        CONTAINER_TAGS="$CONTAINER_TAGS release"
        CONTAINER_PUSH=YES
      ;;
    hotfix-*)
        CONTAINER_TAGS="$CONTAINER_TAGS hotfix"
        CONTAINER_PUSH=YES
      ;;
    *)
        echo "$PROJECT_BRANCH does not push."
      ;;
  esac
  CONTAINER_TAGS="$CONTAINER_TAGS $PROJECT_BRANCH $PROJECT_VERSION"
}


function container_build() {
    echo "Executing Docker build of $DOCKER_REPO"
    container_pull_parent
    docker_build
    CONTAINER_ID=$(docker images | grep -E "$DOCKER_REPO +$CONTAINER_BUILD_TAG " | awk '{print $3}')
}


function container_pull_parent() {
  PARENT_CONTAINER="$(grep FROM $CONTAINER_BUILD_CONTEXT/Dockerfile | awk '{ print $2 }')"
  
  if [ "$PARENT_CONTAINER" != "scratch" ]; then
    echo "Pulling parent container $PARENT_CONTAINER"
    $DEBUG_PREFIX docker pull "$PARENT_CONTAINER"
  fi
}


function container_push() {
    for tag in $CONTAINER_TAGS; do
        if [ $CONTAINER_PUSH == YES ]; then
            docker_push $tag || exit 1
        fi
    done
}


function container_tag() {
    for tag in $CONTAINER_TAGS; do
        docker_tag $tag || exit 1
    done

    docker rmi $CONTAINER_BUILD_NAME
}


function tag_and_push() {
    container_add_tags
    container_tag
    container_push
}


function docker_build() {
    $DEBUG_PREFIX docker build $DOCKER_OPTIONS \
        -t $CONTAINER_BUILD_NAME \
        $BUILD_ARGS \
        $CONTAINER_BUILD_CONTEXT
}


function docker_push() {
    echo "Pushing $DOCKER_REPO:$1"
    $DEBUG_PREFIX docker push $DOCKER_REPO:$1
}


function docker_tag() {
    echo "Tagging $CONTAINER_ID as $DOCKER_REPO:$1"
   $DEBUG_PREFIX docker tag $CONTAINER_ID $DOCKER_REPO:$1
}


function main() {
    validate_vars
    semver_build
    tag_and_push
}


function semver_build() {
    if docker pull $CONTAINER_VERSION_NAME; then
        if echo $PROJECT_VERSION | grep -qE "\-(\d+|SNAPSHOT)"; then
            container_build
        else
            echo Skipping docker build because container $CONTAINER_VERSION_NAME already exists
            CONTAINER_ID=$(docker inspect --format='{{.Id}}' $CONTAINER_VERSION_NAME)
        fi
    else
        container_build
    fi
}


function validate_vars() {
    if [ -z "$DOCKER_REPO" ]; then
        echo "No DOCKER_REPO specified!"
        exit 1
    fi

    if [ -z "$PROJECT_BRANCH" ]; then
        echo "No BRANCH specified!"
        exit 1
    fi

    if [ -z "$PROJECT_VERSION" ]; then
        echo "No PROJECT_VERSION found!"
        exit 1
    fi

    if grep -q 'ARG VERSION' ${CONTAINER_BUILD_CONTEXT}/Dockerfile; then
        BUILD_ARGS="--build-arg VERSION=$PROJECT_VERSION"
    fi
}


env
main
cleanup
