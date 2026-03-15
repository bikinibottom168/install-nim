# Install Nimble Streamer + Auto SSL

ระบบติดตั้ง Nimble Streamer พร้อม Wildcard SSL อัตโนมัติผ่าน Certbot + Cloudflare DNS
ดึงรายชื่อโดเมนจาก API และมี Background Service คอยเช็คโดเมนใหม่ทุก 30 นาที พร้อมแจ้งเตือนผ่าน Telegram

---

## สารบัญ

- [ขั้นตอนการติดตั้ง](#ขั้นตอนการติดตั้ง)
- [ไฟล์ทั้งหมด](#ไฟล์ทั้งหมด)
- [1. ติดตั้ง Nimble Streamer](#1-ติดตั้ง-nimble-streamer)
- [2. ติดตั้ง Certbot + Cloudflare Plugin](#2-ติดตั้ง-certbot--cloudflare-plugin)
- [3. ติดตั้ง SSL + เปิด Auto Monitor](#3-ติดตั้ง-ssl--เปิด-auto-monitor)
- [SSL Monitor (Background Service)](#ssl-monitor-background-service)
- [คำสั่ง ssl-monitor-ctl](#คำสั่ง-ssl-monitor-ctl)
- [Telegram แจ้งเตือน](#telegram-แจ้งเตือน)
- [API โดเมน](#api-โดเมน)
- [ไฟล์สำคัญบนเซิร์ฟเวอร์](#ไฟล์สำคัญบนเซิร์ฟเวอร์)
- [Troubleshooting](#troubleshooting)

---

## ขั้นตอนการติดตั้ง

รันตามลำดับ:

```bash
# Step 1: ติดตั้ง Nimble Streamer
sudo bash 1.install.sh

# Step 2: ติดตั้ง Certbot + Cloudflare DNS Plugin
sudo bash 2.certbot-install.sh

# Step 3: ติดตั้ง SSL + เปิด Auto Monitor
sudo bash 3.install-ssl.sh
```

---

## ไฟล์ทั้งหมด

| ไฟล์ | หน้าที่ |
|------|---------|
| `1.install.sh` | ติดตั้ง Nimble Streamer + ลงทะเบียน WMSPanel + ตั้งค่าพื้นฐาน |
| `2.certbot-install.sh` | ติดตั้ง Certbot + Cloudflare DNS Plugin ผ่าน snap |
| `3.install-ssl.sh` | ติดตั้ง Wildcard SSL + เปิด background monitor |
| `ssl-monitor.sh` | Background service - เช็คโดเมนใหม่ทุก 30 นาที |
| `ssl-monitor-ctl.sh` | คำสั่งจัดการ monitor (status, logs, stop, start) |
| `cloudflare.ini` | Cloudflare API credentials |
| `domain.txt` | (ไม่ได้ใช้แล้ว) รายชื่อโดเมนย้ายไปดึงจาก API |
| `wmspanel_config.sh` | ตั้งค่า WMSPanel เพิ่มเติม |
| `geo-block.sh` | ตั้งค่า Geo Blocking |
| `ssl-origin.sh` | ตั้งค่า SSL Origin |

---

## 1. ติดตั้ง Nimble Streamer

```bash
sudo bash 1.install.sh
```

สิ่งที่ทำ:
- เพิ่ม Nimble repository + ติดตั้ง package
- ลงทะเบียนกับ WMSPanel
- ตั้งค่า port 80/443, SSL paths, RTMP buffer
- Clone SSL key จาก GitHub
- ตั้ง timezone Asia/Bangkok + เปิด NTP

---

## 2. ติดตั้ง Certbot + Cloudflare Plugin

```bash
sudo bash 2.certbot-install.sh
```

สิ่งที่ทำ:
- ติดตั้ง snapd, certbot, certbot-dns-cloudflare
- สร้าง `/certbot/cloudflare.ini` พร้อม API credentials

---

## 3. ติดตั้ง SSL + เปิด Auto Monitor

```bash
sudo bash 3.install-ssl.sh
```

สิ่งที่ทำ:

1. Copy `cloudflare.ini` ไปที่ `/certbot/cloudflare.ini`
2. **Cleanup** - ลบ cert เดิม, renew timer/cron, monitor เก่าทั้งหมด
3. ดึงรายชื่อโดเมนจาก **API**
4. ขอ Wildcard SSL (`*.domain`) ทุกโดเมน
5. อัพเดท Nimble config + restart
6. สร้าง deploy hook สำหรับ auto renew
7. ติดตั้ง + เปิด **SSL Monitor** background service
8. ส่งแจ้งเตือน Telegram `AUTO_SSL_START`

---

## SSL Monitor (Background Service)

### การทำงาน

- รันเป็น systemd service ชื่อ `ssl-monitor.service`
- เช็ค API ทุก **30 นาที** ว่ามีโดเมนใหม่หรือไม่
- เปรียบเทียบกับรายชื่อที่ติดตั้งแล้วใน `/etc/ssl-monitor/installed-domains.txt`
- ถ้ามีโดเมนใหม่ → ขอ cert + อัพเดท Nimble + restart + แจ้ง Telegram
- ถ้าไม่มี → เช็คไปเรื่อยๆ

### ป้องกันการทำงานซ้ำซ้อน

- ใช้ lock file (`/var/run/ssl-monitor.lock`) เก็บ PID
- ถ้ามี process เดิมรันอยู่ → ไม่รันซ้ำ
- ถ้า lock file ค้างจาก process ที่ตายแล้ว → ลบ lock แล้วรันต่อ

### Error Handling

- API ล่ม → log warning แล้วรอรอบถัดไป (ไม่หยุดทำงาน)
- certbot fail → log error + แจ้ง Telegram แล้วข้ามไปโดเมนถัดไป
- service crash → systemd restart อัตโนมัติ (หลังรอ 60 วินาที)

---

## คำสั่ง ssl-monitor-ctl

หลังรัน `3.install-ssl.sh` จะสามารถใช้คำสั่ง `ssl-monitor-ctl` ได้:

### เช็คสถานะ

```bash
ssl-monitor-ctl status
```

ตัวอย่าง output:

```
=== SSL Monitor Status ===
✅ Service: RUNNING
   PID: 12345
   Started: Sun 2026-03-15 10:00:00 ICT

=== Installed Domains ===
   Total: 2 domain(s)
   • koshitaro3248.com
   • montionz8935.top
```

### ดู Logs

```bash
# ดู 50 บรรทัดล่าสุด
ssl-monitor-ctl logs

# ดู 100 บรรทัดล่าสุด
ssl-monitor-ctl logs 100

# ดู log แบบ real-time
ssl-monitor-ctl logs-follow
```

### หยุด / เริ่ม / restart

```bash
ssl-monitor-ctl stop
ssl-monitor-ctl start
ssl-monitor-ctl restart
```

### ดูรายชื่อโดเมนที่ติดตั้งแล้ว

```bash
ssl-monitor-ctl domains
```

### ใช้ systemctl โดยตรง

```bash
systemctl status ssl-monitor
journalctl -u ssl-monitor -f
```

---

## Telegram แจ้งเตือน

ระบบส่งแจ้งเตือนอัตโนมัติ:

| ข้อความ | เมื่อไหร่ |
|---------|----------|
| 🟢 `AUTO_SSL_START [hostname]` | Monitor เริ่มทำงาน (รันครั้งแรก หรือ restart) |
| 🟢 `AUTO_SSL_NEW [hostname]` | ติดตั้ง SSL โดเมนใหม่สำเร็จ |
| 🔴 `AUTO_SSL_FAIL [hostname]` | ติดตั้ง SSL ไม่สำเร็จ |

ทุกข้อความแสดง hostname + วันเวลา

---

## API โดเมน

ระบบดึงรายชื่อโดเมนจาก API แทน `domain.txt`:

```
GET https://api-soccer.thai-play.com/api/domain/root-domains?token=353890
```

Response:

```json
{
  "ok": true,
  "total": 2,
  "available": 2,
  "domains": [
    {
      "id": 77,
      "domain": "koshitaro3248.com",
      "excluded": false,
      "created_at": "2026-03-15 15:01:59"
    }
  ]
}
```

- ดึงเฉพาะโดเมนที่ `excluded: false`
- โดเมนใหม่ที่เพิ่มใน API จะถูกติดตั้ง SSL อัตโนมัติภายใน 30 นาที

---

## ไฟล์สำคัญบนเซิร์ฟเวอร์

| Path | หน้าที่ |
|------|---------|
| `/etc/ssl-monitor/installed-domains.txt` | รายชื่อโดเมนที่ติดตั้ง SSL แล้ว |
| `/var/run/ssl-monitor.lock` | Lock file ป้องกันรันซ้ำ |
| `/certbot/cloudflare.ini` | Cloudflare credentials |
| `/etc/nimble/nimble.conf` | Nimble config |
| `/etc/letsencrypt/live/` | Certificate files |
| `/etc/letsencrypt/renewal-hooks/deploy/99-nimble-reload.sh` | Auto renew hook |
| `/usr/local/bin/ssl-monitor.sh` | Monitor script (copy จาก repo) |
| `/usr/local/bin/ssl-monitor-ctl` | Control command (copy จาก repo) |
| `/etc/systemd/system/ssl-monitor.service` | Systemd service unit |

---

## Troubleshooting

### Monitor ไม่ทำงาน

```bash
ssl-monitor-ctl status
ssl-monitor-ctl logs
```

### ต้องการรีเซ็ตทั้งหมดแล้วเริ่มใหม่

```bash
sudo bash 3.install-ssl.sh
```

สคริปต์จะ cleanup ทุกอย่างแล้วเริ่มใหม่ทั้งหมด

### เพิ่มโดเมนใหม่ทันทีไม่ต้องรอ 30 นาที

```bash
ssl-monitor-ctl restart
```

Monitor จะเช็ค API ทันทีหลัง restart

### เช็คว่า cert ถูกต้อง

```bash
certbot certificates
```

### ดู log ของ certbot

```bash
cat /var/log/letsencrypt/letsencrypt.log
```
