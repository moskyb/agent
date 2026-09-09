# Docker runtime smoke tests

The fork's default `.buildkite/pipeline.yml` runs a Linux, native-architecture Docker smoke test. The upstream pipeline is retained in `pipeline.upstream.yml`; it isn't uploaded by the smoke pipeline. No releases, private ECR repositories, AWS roles, Test Engine credentials or private S3 caches are used.

Configure the Buildkite pipeline's initial step to run `buildkite-agent pipeline upload`. Set `DOCKER_SMOKE_QUEUE` on that upload step to select the experiment queue; it defaults to `default`. The upload step itself must also be assigned to a suitable queue in the pipeline settings. Agent credentials and working Buildkite artifact storage are still required.

## What a green build establishes

1. The pinned Docker plugin can start Alpine, read this repository through its checkout bind mount, and write an artifact back into the checkout.
2. Docker Compose can build the existing upstream `agent` service image and reach a healthy HTTP service by Compose DNS name. Two sequential containers can exchange a job-specific value through a named volume.
3. The repository's `env`, `internal/process` and `jobapi` tests pass inside the Compose container, and the checked-out agent source compiles into a native Linux binary.
4. Buildx's `docker-container` driver can build and load the real Alpine agent packaging image. A second build exercises warm cache reuse; logs and elapsed times are available for comparison, but timing/cache-hit thresholds aren't pass criteria.
5. The upstream image tests pass, including forwarding the Docker socket into a container. The packaged binary's version matches the binary compiled from the checkout.
6. Buildkite uploads the reports and downloads them in another job, where their SHA-256 checksums are verified. No shared Docker daemon or workspace is assumed between pipeline steps.

This isn't the full agent test suite, a release build, a security certification or a benchmark. It doesn't generate release acknowledgements. It doesn't yet test registry push/authentication, explicit host port publication, multi-architecture emulation, resource enforcement, or job cancellation under load. Warm Buildx cache is tested within one job, not retained between jobs.

## Agent requirements

- Linux AMD64 or ARM64, Bash, Docker CLI, Compose v2-compatible CLI, Buildx and `sha256sum`. The current `buildkite/agent:4` image includes these tools.
- A working Docker daemon with support for Compose networking and the Buildx `docker-container` driver. An agent-only Deployment without a daemon is expected to fail.
- Checkout paths visible at identical absolute paths to the agent and daemon. The image tests also expect the daemon's socket at `/var/run/docker.sock`; rootless/remote setups must provide that mapping or deliberately adapt this test.
- Outbound access to public GitHub, Docker Hub, public ECR and Go module sources, plus the configured Buildkite agent/artifact endpoints. Local `.localhost` aliases aren't automatically inherited by Docker-created containers.
- Enough CPU, RAM and disk for Go compilation and image builds. The earlier lightweight 1 GiB agent limit isn't a sizing recommendation for the daemon and its nested workloads.

Every runtime job uses a unique Compose project, Buildx builder and image tag. Cleanup removes only those resources, including the project's named volume, on normal success/failure and handled termination. It doesn't run global prune commands or remove shared base images/build cache. SIGKILL or a daemon outage can still leave resources behind; they carry the `agent-smoke-<job-id>` prefix. Buildx builders are private to a job, so concurrent jobs don't change each other's selected builder.

## Run locally

From the repository root, against a disposable or trusted local Docker daemon:

```sh
bash .buildkite/steps/docker-smoke.sh
```

This runs the Compose/build/image checks and leaves diagnostics under the ignored `tmp/docker-smoke/` directory. It doesn't execute the Buildkite Docker plugin or the artifact round trip; those need a Buildkite run. The pipeline pins plugin/image versions where specified, but upstream Dockerfiles still download dependencies, so cold builds depend on public services.
