# Dockerfile (single image): สิ่งที่เปลี่ยนและวิธีใช้

ไฟล์: `Dockerfile` (+ `.dockerignore` ที่ repo root)
แนวคิด: **image เดียว ใช้ทั้ง web และ worker เหมือนเดิม** แก้เฉพาะจุดที่ทำให้ image ใหญ่/build ช้า ไม่ต้องแก้ code หรือ `next.config`
ผลคาดการณ์: image เล็กลงประมาณ 40–50% (ยังไม่ได้วัดจริง)

---

## 1. สิ่งที่แก้ (เรียงตามผลที่ได้)

| # | ของเดิม | ปัญหา | ที่แก้ |
|---|---|---|---|
| 1 | `chgrp -R` / `chmod -R` ทั้ง `/usr/src/app` | ทุกไฟล์ถูก copy ซ้ำลง layer ใหม่ (รวม `node_modules`) image ใหญ่เกือบ 2 เท่า | ตั้ง owner/permission ตอน `COPY --chown=1001:0 --chmod=g=u` เหลือ `chgrp/chmod` เฉพาะ `/data` ซึ่งว่างอยู่ |
| 2 | ไม่มี `.dockerignore` | `COPY frontend/` ทับ `node_modules` ที่ `npm ci` ลงไว้ด้วยของเครื่อง dev (ถ้าเป็น macOS/arm64 binary ของ Prisma/sharp จะพังตอน run) และพา `.env*`, `.git`, `.next` เข้า image | เพิ่ม `.dockerignore` |
| 3 | copy `/app` มาทั้งก้อน | ติด `.next/cache` (มักหลายร้อย MB) | `rm -rf .next/cache` ตอนท้าย build |
| 4 | copy `prisma/` ก่อน `npm ci` | แก้ schema ทีไร ต้อง `npm ci` ใหม่ทั้งหมด | copy แค่ `package*.json` → `npm ci --ignore-scripts` → ค่อย copy source → `prisma generate` + cache mount ของ npm/apt |
| 5 | `VOLUME ["/data"]` | Docker สร้าง anonymous volume ค้างทุกครั้งที่ไม่ได้ mount เอง และ RUN หลังบรรทัดนี้ที่แตะ `/data` จะถูกทิ้ง | ลบออก ใช้ PVC mount `/data` ใน manifest |
| 6 | `sh -c "exec ..."` ไม่มี init | SIGTERM/zombie process (qpdf, worker) จัดการไม่ดี | ใช้ `tini` เป็น ENTRYPOINT + CMD แบบ exec form |
| 7 | ไม่มี label | trace กลับไปหา commit ไม่ได้ | เพิ่ม `org.opencontainers.image.revision` |

**ที่ตั้งใจไม่เปลี่ยน:** ยังเก็บ `node_modules` เต็ม (รวม dev deps) ไว้ใน image เพราะ worker รันผ่าน `tsx` และ `prisma migrate deploy` ต้องใช้ Prisma CLI ซึ่งทั้งคู่เป็น dev dependency

---

## 2. Build

รันจาก **repo root** (ที่มีโฟลเดอร์ `frontend/`) ต้องใช้ BuildKit (Docker 23+ เปิดอยู่แล้ว ถ้าเก่ากว่าให้ใส่ `DOCKER_BUILDKIT=1`)

```bash
VER=$(git rev-parse --short HEAD)
docker build \
  --build-arg VERSION=$VER \
  --build-arg NEXT_PUBLIC_SHOW_CLONINGLAB=true \
  --build-arg NEXT_PUBLIC_LIBRARY_ALLOW_DOWNLOADS=false \
  --build-arg NEXT_PUBLIC_API_URL= \
  -t bimhub:$VER .
```

`NEXT_PUBLIC_*` ต้องส่งตอน build เท่านั้น (ถูก inline เข้า client bundle) ตั้งเป็น env ตอน run ไม่มีผล

---

## 3. Run (image เดียว 3 บทบาท)

```bash
# web (default CMD)
docker run --rm -p 8080:8080 -v bimhub-data:/data --env-file frontend/.env bimhub:$VER

# worker
docker run --rm -v bimhub-data:/data --env-file frontend/.env \
  -e NODE_OPTIONS=--max-old-space-size=4096 bimhub:$VER \
  node node_modules/tsx/dist/cli.mjs --tsconfig tsconfig.worker.json scripts/ifc-worker.ts

# migrate
docker run --rm --env-file frontend/.env bimhub:$VER npx prisma migrate deploy
```

**ข้อควรระวัง K8s/OpenShift:** ENTRYPOINT เป็น `tini` ใน Deployment ของ worker ให้ใส่คำสั่งใน **`args:`** ไม่ใช่ `command:` (ถ้าใช้ `command:` จะทับ tini)

---

## 4. Checklist ก่อน merge

- [ ] วาง `.dockerignore` ที่ repo root
- [ ] build ผ่าน และเทียบขนาดกับ image เดิม (`docker image ls`, `dive <image>`)
- [ ] `npm ci --ignore-scripts` ไม่ข้าม postinstall ที่จำเป็น (นอกจาก `prisma generate` ที่รันเองแล้ว) ถ้ามี native module ที่ต้องพึ่ง postinstall ให้เอา `--ignore-scripts` ออก
- [ ] web start ได้ด้วย arbitrary UID: `docker run --user 1234:0 -v bimhub-data:/data ...`
- [ ] upload ไฟล์ลง `/data` ได้ (library, family center, avatar)
- [ ] worker แปลง IFC ได้ และ `qpdf` ทำงาน
- [ ] ลบ `VOLUME` แล้ว: ใน manifest มี PVC mount `/data` แล้ว
- [ ] Deployment ของ worker ใช้ `args:` ไม่ใช่ `command:`

---

## 5. ถ้าอยากเล็กกว่านี้

ดู [split-image.md](split-image.md) แยก web / worker / migrate ได้ image เล็กสุด แต่ต้องแก้ `next.config` และเทสเพิ่ม
