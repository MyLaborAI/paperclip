# syntax=docker/dockerfile:1.20
FROM node:24-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl gh git wget ripgrep python3 tini \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# Modify the existing node user/group to have the specified UID/GID to match host user
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
# One glob per workspace root in pnpm-workspace.yaml, instead of a hand-listed
# COPY per package. The hand-listed form silently drifted from the workspace
# (packages/plugins/create-paperclip-plugin and the four
# packages/plugins/examples/* members were in pnpm-lock.yaml but never copied
# here), which leaves this stage installing a different importer set than the
# lockfile describes. Globs cannot drift: adding a package to the workspace
# adds it here automatically.
#
# sandbox-providers and plugin-orchestration-smoke-example are deliberately NOT
# workspace members (see pnpm-workspace.yaml), so pnpm ignores their manifests
# — but the root postinstall (scripts/link-plugin-dev-sdk.mjs) walks those
# directories to link the in-repo plugin SDK into them, so their package.json
# files still have to be present.
COPY --parents \
  ./*/package.json \
  ./packages/*/package.json \
  ./packages/adapters/*/package.json \
  ./packages/plugins/*/package.json \
  ./packages/plugins/examples/*/package.json \
  ./packages/plugins/sandbox-providers/*/package.json \
  ./
COPY patches/ patches/
COPY scripts/link-plugin-dev-sdk.mjs scripts/

RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
# The server build runs scripts/write-build-stamp.mjs, which stamps the built
# commit into dist/build-info.json. The build context has no .git, so the
# script reads PAPERCLIP_BUILD_COMMIT instead. Docker exposes an ARG to the
# next RUN as an environment variable, so declare it here — in the build
# stage — before the server build. The production stage below declares the
# same ARG again for the runtime fallback; an ARG goes out of scope at the
# end of its stage. Empty for local `docker build`, which then writes no stamp.
ARG PAPERCLIP_BUILD_COMMIT=""
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
# Real version for this build, computed from `git describe` on the CI runner
# (the image has no .git, so the server cannot derive it at runtime). Empty for
# local `docker build`, which just leaves the server on its normal fallbacks.
ARG PAPERCLIP_BUILD_VERSION=""
# The exact commit this image was built from, for the same reason: server-info
# falls back to PAPERCLIP_BUILD_COMMIT when git is unavailable, which feeds the
# /api/health `commit` field that deploy tooling verifies. Empty locally.
ARG PAPERCLIP_BUILD_COMMIT=""
# Refreshes the tool layer below when it changes (CI stamps an ISO week, so
# the @latest CLI tools advance weekly). Without it the cached layer would
# freeze the tools until an unrelated cache bust.
ARG CLI_TOOLS_CACHE_EPOCH=""
WORKDIR /app
# Tool and OS layer BEFORE the app copy: it references nothing from /app, and
# the app copy changes on every commit — ordered the other way around, this
# (the single most expensive layer: four CLI toolchains + apt, per arch) can
# never hit the layer cache and rebuilds on every build.
RUN echo "cli-tools-epoch: ${CLI_TOOLS_CACHE_EPOCH}" \
  && npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai @google/gemini-cli@latest @moonshot-ai/kimi-code@latest \
  && apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --chown=node:node --from=build /app /app

ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_BUILD_VERSION=${PAPERCLIP_BUILD_VERSION} \
  PAPERCLIP_BUILD_COMMIT=${PAPERCLIP_BUILD_COMMIT} \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true \
  GEMINI_SANDBOX=false

EXPOSE 3100

# GET /api/health needs no auth and answers 200 while the database probe
# succeeds, 503 on `database_unreachable` — so it distinguishes "process is up"
# from "actually serving", which is what a rolling deploy has to gate on.
# 127.0.0.1 is always allowed past the private-hostname guard regardless of
# PAPERCLIP_ALLOWED_HOSTNAMES, so this never needs updating per deployment.
# The start period is generous: a first boot applies the bundled migrations
# (and initialises the embedded cluster when DATABASE_URL is unset) before the
# listener comes up.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null || exit 1

# tini, not node, is PID 1. The entrypoint ends in `exec`, so without an init
# node inherits PID 1 and never wait()s the orphans the kernel re-parents onto
# it -- agent runs spawn git/claude/esbuild/sh descendants that outlive their
# leader, so they pile up as permanent zombies (~79/h measured) until the
# cgroup pid limit is exhausted and *every* fork() in the container fails.
# tini reaps adopted orphans and forwards signals, so the exec chain below and
# graceful shutdown are unchanged. Mirrors docker/agent-runtime/Dockerfile.base.
ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]

# Cloud image variant (build with `--target cloud`): the production image
# plus built bundled sandbox-provider plugins. Managed instances receive a
# `plugins.autoInstall` key list through PAPERCLIP_MANAGED_CONFIG and
# install those plugins from the bundled catalog at boot
# (server/src/services/bundled-plugins.ts), which requires each plugin's
# dist/ to exist in the image — the default image ships only their source,
# so auto-install logs "bundle not present" and skips. The plugins are
# built in this separate target so the default (self-hosted) image stays
# lean; CI pins the default build to `--target production`, which is
# byte-identical to before this stage existed.
#
# The sandbox providers are intentionally excluded from the pnpm workspace
# (see pnpm-workspace.yaml), so each installs standalone exactly as its
# README prescribes. Installing in a `build`-based stage (not `production`)
# keeps devDependencies available for tsc: `production` sets
# NODE_ENV=production, which would make pnpm skip them.
#
# CLOUD_BUNDLED_PLUGINS is the space-separated list of sandbox-provider
# directory names to build into the variant. Only what managed deployments
# actually auto-install belongs here — every entry adds its node_modules
# to the image. Growing the list is a one-line workflow change.
FROM build AS cloud-plugins
ARG CLOUD_BUNDLED_PLUGINS="daytona"
RUN set -eu; \
  for name in $CLOUD_BUNDLED_PLUGINS; do \
    dir="packages/plugins/sandbox-providers/$name"; \
    test -d "$dir" || { echo "ERROR: unknown sandbox provider '$name'" >&2; exit 1; }; \
    pnpm -C "$dir" install --ignore-workspace --no-lockfile; \
    pnpm -C "$dir" build; \
    test -f "$dir/dist/manifest.js" || { echo "ERROR: $dir is missing dist/manifest.js after build" >&2; exit 1; }; \
  done

FROM production AS cloud
COPY --chown=node:node --from=cloud-plugins /app/packages/plugins/sandbox-providers /app/packages/plugins/sandbox-providers
