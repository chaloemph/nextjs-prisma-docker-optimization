# Dockerfile.split (แยก web / worker / migrate): สิ่งที่เปลี่ยนและวิธีใช้

ไฟล์: `Dockerfile.split` (+ `.dockerignore` ที่ repo root)
แนวคิด: **Dockerfile เดียว แต่ 3 target → 3 image** แต่ละตัวมีเฉพาะของที่ต้องใช้
ผลคาดการณ์: web ~150–250MB, worker เล็กลงมาก, migrate ไม่ต้องอยู่ใน pod ที่รับ traffic (ยังไม่ได้วัดจริง)

---

## 1. ต้องทำก่อน build

1. เพิ่ม `output: 'standalone'` ใน `frontend/next.config.*` ไม่งั้น target `web` จะ fail (ไม่มี `.next/standalone`)
2. เช็คว่า standalone trace เก็บไฟล์ครบ: Prisma engine/client และไฟล์ที่ `src/lib/familyLocalStorage.ts` อ่านแบบ dynamic ถ้าไม่ครบให้เพิ่ม `outputFileTracingIncludes`
3. เช็คว่า worker ที่ bundle ด้วย esbuild resolve path alias จาก `tsconfig.worker.json` ได้ถูกต้อง

---

## 2. สามตัวนี้ต่างกันอย่างไร

| Target | เนื้อหา | ใช้ทำอะไร |
|---|---|---|
| `web` | Next.js standalone → `node server.js` | Deployment ที่รับ traffic |
| `worker` | `ifc-worker.ts` ที่ bundle แล้ว → `node dist/ifc-worker.js` + prod deps เท่านั้น | Deployment ของ IFC converter |
| `migrate` | build stage + Prisma CLI → `prisma migrate deploy` | Job / initContainer รันก่อน deploy |

**ทำไมแยก:**
- pod เล็ก pull/scale เร็ว และ attack surface น้อย (ไม่มี compiler/CLI ใน web)
- worker ไม่ต้อง compile TS ทุกครั้งที่ start (เดิมผ่าน `tsx`) start เร็วขึ้น กิน RAM น้อยลง ซึ่งสำคัญเพราะต้องตั้ง heap 4GB อยู่แล้ว
- migration เป็น Job แยก คุมลำดับ deploy ได้ และ web หลาย replica ไม่แย่งกัน migrate

---

## 3. สิ่งที่แก้ เมื่อเทียบกับ Dockerfile เดิม

| # | ของเดิม | ปัญหา | ที่แก้ |
|---|---|---|---|
| 1 | `chgrp -R` / `chmod -R` ทั้ง `/usr/src/app` | ทุกไฟล์ถูก copy ซ้ำลง layer ใหม่ image ใหญ่เกือบ 2 เท่า | `COPY --chown=1001:0 --chmod=g=u` และเหลือ `chgrp/chmod` เฉพาะ `/data` ที่ว่าง |
| 2 | ไม่มี `.dockerignore` | `node_modules` ของเครื่อง dev ทับของที่ `npm ci` ลงไว้ พา `.env*`/`.git`/`.next` เข้า image | เพิ่ม `.dockerignore` |
| 3 | copy `/app` ทั้งก้อน (source, `.next/cache`, dev deps) | image บวม | web copy เฉพาะ `.next/standalone`, `.next/static`, `public`; worker copy เฉพาะ `dist` + prod `node_modules` |
| 4 | copy `prisma/` ก่อน `npm ci` | แก้ schema ทีไร ต้อง `npm ci` ใหม่ทั้งหมด | copy แค่ `package*.json` ก่อน + cache mount ของ npm/apt |
| 5 | `VOLUME ["/data"]` | anonymous volume ค้าง และ RUN หลังบรรทัดนี้ที่แตะ `/data` ถูกทิ้ง | ลบออก ใช้ PVC mount `/data` |
| 6 | `sh -c "exec ..."` ไม่มี init | SIGTERM/zombie process (qpdf, worker) | `tini` เป็น ENTRYPOINT + CMD แบบ exec form |
| 7 | ไม่มี label | trace กลับไปหา commit ไม่ได้ | เพิ่ม `org.opencontainers.image.revision` |

---

## 4. Build

รันจาก **repo root** ต้องใช้ BuildKit

```bash
VER=$(git rev-parse --short HEAD)

docker build -f Dockerfile.split --target web \
  --build-arg VERSION=$VER \
  --build-arg NEXT_PUBLIC_SHOW_CLONINGLAB=true \
  --build-arg NEXT_PUBLIC_LIBRARY_ALLOW_DOWNLOADS=false \
  --build-arg NEXT_PUBLIC_API_URL= \
  -t bimhub-web:$VER .

docker build -f Dockerfile.split --target worker  --build-arg VERSION=$VER -t bimhub-worker:$VER .
docker build -f Dockerfile.split --target migrate -t bimhub-migrate:$VER .
```

`NEXT_PUBLIC_*` ส่งตอน build เท่านั้น (ถูก inline เข้า client bundle) และใช้กับ target `web` ถ้าค่าต่างกันตาม environment ต้อง build แยกต่อ env

ถ้า CI ไม่ใช่ Docker daemon ปกติ ใช้ `docker buildx build ... --push` พร้อม `--cache-from/--cache-to type=registry`

---

## 5. Run / Deploy

```bash
docker run --rm -p 8080:8080 -v bimhub-data:/data --env-file frontend/.env bimhub-web:$VER
docker run --rm -v bimhub-data:/data --env-file frontend/.env bimhub-worker:$VER
docker run --rm --env-file frontend/.env bimhub-migrate:$VER
```

บน K8s/OpenShift:
- `migrate` → Job หรือ initContainer รันก่อน rollout ของ web
- `web`, `worker` → Deployment แยกกัน ทั้งคู่ mount PVC ที่ `/data`
- `worker` ตั้ง `NODE_OPTIONS=--max-old-space-size=4096` ไว้ใน image แล้ว ปรับ memory limit ของ pod ให้เกิน heap

---

## 6. Checklist ก่อน merge

- [ ] เพิ่ม `output: 'standalone'` ใน `next.config` แล้ว
- [ ] standalone trace มี Prisma engine และไฟล์ที่ `familyLocalStorage.ts` อ่านแบบ dynamic
- [ ] worker ที่ bundle แล้ว resolve path alias ได้ และแปลง IFC ได้จริง
- [ ] `npm ci --ignore-scripts` ไม่ข้าม postinstall ที่จำเป็น (นอกจาก `prisma generate` ที่รันเองแล้ว)
- [ ] วาง `.dockerignore` ที่ repo root
- [ ] build ครบ 3 target และเทียบขนาดกับ image เดิม (`docker image ls`, `dive <image>`)
- [ ] web start ได้ด้วย arbitrary UID: `docker run --user 1234:0 -v bimhub-data:/data ...`
- [ ] upload ไฟล์ลง `/data` ได้ (library, family center, avatar) และ `qpdf` ทำงาน
- [ ] `migrate` รันเป็น Job/initContainer ใน pipeline แล้ว
- [ ] manifest มี PVC mount `/data` (เพราะลบ `VOLUME` แล้ว)

---

## 7. ถ้าอยากเริ่มง่ายกว่านี้

ดู [single-image.md](single-image.md) ใช้ image เดียว ไม่ต้องแก้ `next.config` ได้ผลส่วนใหญ่ทันที
