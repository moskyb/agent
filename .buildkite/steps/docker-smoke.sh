#!/usr/bin/env bash
set -euo pipefail

# Run from the checkout root, just like the upstream CI scripts.
export SMOKE_RUN_ID="${BUILDKITE_JOB_ID:-local-$(date +%s)-$$}"
project="agent-smoke-${SMOKE_RUN_ID}"
image="${project}:smoke"
output=tmp/docker-smoke
mkdir -p "$output"
context=$(mktemp -d "$output/context.XXXXXX")
builder=""
compose=(docker compose --project-name "$project" -f .buildkite/docker-compose.yml -f .buildkite/docker-compose.smoke.yml)

cleanup() {
  local status=$?
  trap - EXIT
  # Capture diagnostics before removing only this job's resources.
  "${compose[@]}" logs --no-color > "$output/compose.log" 2>&1 || true
  "${compose[@]}" down --volumes --remove-orphans --rmi local || status=1
  if [[ -n "$builder" ]]; then
    docker buildx rm "$builder" || status=1
  fi
  if docker image inspect "$image" >/dev/null 2>&1; then
    docker image rm "$image" || status=1
  fi
  rm -rf "$context"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo '--- Docker capabilities'
docker version | tee "$output/docker-version.txt"
docker info | tee "$output/docker-info.txt"
docker compose version
docker buildx version
arch=$(docker version --format '{{.Server.Arch}}')
case "$arch" in
  amd64 | arm64) ;;
  *) echo "Unsupported smoke-test architecture: $arch" >&2; exit 1 ;;
esac

echo '--- Compose build, service DNS and shared volume'
"${compose[@]}" build agent
"${compose[@]}" up --detach --wait --wait-timeout 60 smoke-http
# shellcheck disable=SC2016 # Expand these variables inside the Compose container.
"${compose[@]}" run --rm --no-deps -T agent bash -euo pipefail -c '
  grep -Fx "module github.com/buildkite/agent/v4" go.mod
  test "$(curl --fail --silent --show-error http://smoke-http:8080/probe)" = compose-network-ok
  test ! -e /smoke-data/run-id
  printf "%s\n" "$SMOKE_RUN_ID" > /smoke-data/run-id

  # A bounded subset of real tests, without Test Engine or the private S3 cache.
  go test -count=1 -timeout=5m ./env ./internal/process ./jobapi
  CGO_ENABLED=0 go build -o tmp/docker-smoke/buildkite-agent .
  tmp/docker-smoke/buildkite-agent --version > tmp/docker-smoke/agent-version.txt
' 2>&1 | tee "$output/agent-build.log"

# A second container must see the first container's named-volume write.
# shellcheck disable=SC2016 # Expand these variables inside the Compose container.
"${compose[@]}" run --rm --no-deps -T agent bash -euo pipefail -c '
  test "$(cat /smoke-data/run-id)" = "$SMOKE_RUN_ID"
  test -s tmp/docker-smoke/agent-version.txt
  printf "compose-network-and-volume-ok\n" > tmp/docker-smoke/compose-result.txt
'

echo '--- Build the upstream Alpine agent image for the native architecture'
cp -R packaging/docker/alpine/. "$context/"
cp "$output/buildkite-agent" "$context/buildkite-agent-linux-$arch"
builder=$(docker buildx create --driver docker-container --name "$project")
# Use the builder explicitly rather than changing the daemon's default builder.
for run in first warm; do
  time docker buildx build --builder "$builder" --platform "linux/$arch" \
    --progress plain --load --tag "$image" "$context" 2>&1 | tee "$output/image-build-$run.log"
done

echo '--- Run the existing image tests, including Docker socket forwarding'
bash .buildkite/steps/test-docker-image.sh alpine "$image" "linux/$arch" 2>&1 | tee "$output/image-tests.log"
docker run --rm "$image" --version > "$output/image-version.txt"
cmp "$output/agent-version.txt" "$output/image-version.txt"

# Generated before artifact upload and checked in a separate Buildkite job.
# compose.log is collected later by the EXIT trap, so exclude it explicitly.
sha256sum "$output"/{docker-version.txt,docker-info.txt,agent-version.txt,compose-result.txt,image-version.txt,agent-build.log,image-build-first.log,image-build-warm.log,image-tests.log} > "$output/checksums.sha256"
echo '--- Docker smoke tests passed'
