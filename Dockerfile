# syntax=docker/dockerfile:1.7
# BIMHub — SINGLE image (web + worker from the same image), optimized.
#
# Behaviour is the same as the original Dockerfile:
#   web    : default CMD
#   worker : override the command with
#            node node_modules/tsx/dist/cli.mjs --tsconfig tsconfig.worker.json scripts/ifc-worker.ts
#            (set NODE_OPTIONS=--max-old-space-size=4096)
#   migrate: npx prisma migrate deploy   (same image)
#
# Build (from repo root):
#   docker build -t bimhub:latest --build-arg VERSION=$(git rev-parse --short HEAD) .
#
# Mount a persistent volume at /data (PVC on OpenShift) or uploads are lost.
# OpenShift/OKD: arbitrary UID in group 0 → files owned by 1001:0 with g=u.
#
# NOTE for Kubernetes/OpenShift: ENTRYPOINT is tini. In the worker Deployment set
#   `args:` (not `command:`) to the node ... tsx ... command, so tini is kept.

ARG NODE_IMAGE=public.ecr.aws/docker/library/node:22-bookworm-slim

# ---------- 1) deps ----------
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends openssl
# Only manifests → this layer is rebuilt only when dependencies change
# (not when prisma schema or source changes).
COPY frontend/package.json frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts

# ---------- 2) build ----------
FROM deps AS build
COPY frontend/ ./
ARG NEXT_PUBLIC_SHOW_CLONINGLAB=true
ARG NEXT_PUBLIC_LIBRARY_ALLOW_DOWNLOADS=false
ARG NEXT_PUBLIC_API_URL=
ENV NEXT_PUBLIC_SHOW_CLONINGLAB=$NEXT_PUBLIC_SHOW_CLONINGLAB \
    NEXT_PUBLIC_LIBRARY_ALLOW_DOWNLOADS=$NEXT_PUBLIC_LIBRARY_ALLOW_DOWNLOADS \
    NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_TELEMETRY_DISABLED=1
# rm .next/cache: often hundreds of MB, not needed at runtime.
RUN npx prisma generate && npm run build && rm -rf .next/cache

# ---------- 3) runtime ----------
FROM ${NODE_IMAGE} AS runtime
WORKDIR /usr/src/app

# qpdf: linearizes uploaded Library PDFs (skipped silently if missing).
# tini: forwards SIGTERM, reaps zombies (qpdf / worker children).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends qpdf openssl tini \
 && mkdir -p /data/library/data_lb /data/library/thumbnail_lb \
             /data/familycenter/files /data/familycenter/previews_fc /data/familycenter/thumbnail_fc \
             /data/thumbnail /data/cloning-storage /data/uploads \
 && chgrp -R 0 /data && chmod -R g=u /data      # /data is empty → cheap

ENV NODE_ENV=production \
    PORT=8080 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    AI_SEMANTIC=off \
    LIBRARY_DATA_ROOT=/data/library/data_lb \
    LIBRARY_THUMB_ROOT=/data/library/thumbnail_lb \
    FAMILY_DATA_ROOT=/data/familycenter/files \
    FAMILY_PREVIEW_ROOT=/data/familycenter/previews_fc \
    FAMILY_THUMB_ROOT=/data/familycenter/thumbnail_fc \
    FAMILY_LOCAL_STORAGE_ROOT=/data/thumbnail \
    CLONING_STORAGE_ROOT=/data/cloning-storage

# Ownership/permissions are set at COPY time. Do NOT run `chgrp -R`/`chmod -R`
# on /usr/src/app afterwards: that duplicates every file (incl. node_modules)
# into a new layer and roughly doubles the image.
# Full node_modules is kept on purpose: the worker runs through tsx and
# `prisma migrate deploy` needs the Prisma CLI (both are dev deps).
COPY --from=build --chown=1001:0 --chmod=g=u /app ./

# public/uploads → volume so avatars survive redeploys (tiny change, cheap layer).
RUN rm -rf public/uploads && ln -s /data/uploads public/uploads

ARG VERSION=latest
ENV IMAGE_VERSION=$VERSION
LABEL org.opencontainers.image.revision=$VERSION

USER 1001
EXPOSE 8080
# No VOLUME instruction: it creates orphan anonymous volumes. Mount /data via PVC.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "node_modules/next/dist/bin/next", "start", "-p", "8080"]
