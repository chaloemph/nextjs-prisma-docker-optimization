# bimhub-docker-optimization

Optimized Dockerfiles for BIMHub (Next.js + Prisma + IFC worker) in two variants, with notes on what changed and why.

| Variant | File | Doc | Choose when |
|---|---|---|---|
| Single image | [`Dockerfile`](Dockerfile) | [docs/single-image.md](docs/single-image.md) | Want the quick win: one image for web + worker + migrate, no code/config changes (~40–50% smaller, not yet measured) |
| Split images | [`Dockerfile.split`](Dockerfile.split) | [docs/split-image.md](docs/split-image.md) | Want the smallest images: separate `web` / `worker` / `migrate` targets (needs `output: 'standalone'` in `next.config`) |

Also included: [`.dockerignore`](.dockerignore) (goes at the BIMHub repo root).

## Usage

These files are meant to be copied into the BIMHub repo root (the build context expects a `frontend/` folder).

```bash
# single
docker build -t bimhub:$(git rev-parse --short HEAD) .

# split
docker build -f Dockerfile.split --target web -t bimhub-web .
```

Status: not yet build-tested. Follow the checklist at the bottom of each doc before merging.
