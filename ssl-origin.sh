#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
DOMAIN="kokurabay.com"
SRC_DIR="/etc/letsencrypt/live/${DOMAIN}"
WORK_DIR="/opt/ssl-server"  # โฟลเดอร์ที่ clone repo
GITHUB_USER="bikinibottom168"
GITHUB_TOKEN="PUT_YOUR_GITHUB_PAT_HERE"   # ← วาง PAT ตรงนี้
REPO_NAME="ssl-server"
REPO_BRANCH="main"
GIT_USER_NAME="ssl-uploader"
GIT_USER_EMAIL="ssl-uploader@${DOMAIN}"

# สร้าง URL พร้อม user:token (คำเตือน: ใครอ่านสคริปต์นี้จะเห็น token ได้ ดังนั้นจำกัดสิทธิ์ไฟล์สคริปต์)
AUTH_REMOTE="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"

# ======== PREP ========
umask 077
# ตรวจว่าโฟลเดอร์ cert มีอยู่ไหม
if [[ ! -d "${SRC_DIR}" ]]; then
  echo "[ERROR] Missing ${SRC_DIR}"
  exit 1
fi

# โคลนครั้งแรกถ้ายังไม่มี .git
if [[ ! -d "${WORK_DIR}/.git" ]]; then
  rm -rf "${WORK_DIR}" || true
  mkdir -p "${WORK_DIR}"
  git clone "${AUTH_REMOTE}" "${WORK_DIR}"
fi

cd "${WORK_DIR}"
git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"

# อัปเดต repo ให้เป็นล่าสุด
git fetch origin
# ถ้ายังไม่มีสาขา main ในโลคัล ให้ checkout ให้เรียบร้อย
if ! git rev-parse --verify "${REPO_BRANCH}" >/dev/null 2>&1; then
  git checkout -b "${REPO_BRANCH}" "origin/${REPO_BRANCH}" || git checkout -b "${REPO_BRANCH}"
else
  git checkout "${REPO_BRANCH}"
  git pull --rebase origin "${REPO_BRANCH}" || true
fi

# ========= COPY ONLY kokurabay.com =========
mkdir -p "${WORK_DIR}/${DOMAIN}"

# คัดลอกเฉพาะไฟล์หลักที่ใช้จริง (จะ add เฉพาะไฟล์ในโฟลเดอร์โดเมนนี้เท่านั้น)
for f in fullchain.pem privkey.pem chain.pem cert.pem; do
  if [[ -f "${SRC_DIR}/${f}" ]]; then
    # ใช้ install เพื่อเซ็ต permission 600 ทันที
    install -m 600 "${SRC_DIR}/${f}" "${WORK_DIR}/${DOMAIN}/${f}"
  else
    # ถ้าไม่มีไฟล์นี้ ก็ข้ามไป (ไม่ลบไฟล์เก่าใน repo)
    echo "[WARN] ${SRC_DIR}/${f} not found, skip"
  fi
done

# ========= STAGE & COMMIT ONLY THIS FOLDER =========
git add "${DOMAIN}/fullchain.pem" "${DOMAIN}/privkey.pem" "${DOMAIN}/chain.pem" "${DOMAIN}/cert.pem" 2>/dev/null || true

# ถ้ามีการเปลี่ยนแปลงถึงคอมมิต/พุช
if ! git diff --cached --quiet; then
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  git commit -m "Update ${DOMAIN} certs at ${now}"
  # กัน non-fast-forward
  git pull --rebase origin "${REPO_BRANCH}" || true
  git push "${AUTH_REMOTE}" HEAD:"${REPO_BRANCH}"
  echo "[OK] pushed to ${REPO_BRANCH}"
else
  echo "[=] nothing to push (no changes)"
fi
