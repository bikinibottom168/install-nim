# คู่มือใช้งาน SSL Auto Install

## ภาพรวม

ระบบติดตั้ง Wildcard SSL อัตโนมัติผ่าน Certbot + Cloudflare DNS สำหรับ Nimble Streamer
โดยดึงรายชื่อโดเมนจาก API และมี Background Service คอยเช็คโดเมนใหม่ทุก 30 นาที

---

## ไฟล์ในระบบ

| ไฟล์ | หน้าที่ |
|------|---------|
| `3.install-ssl.sh` | สคริปต์หลัก - ติดตั้ง SSL ครั้งแรก + เปิด background monitor |
| `ssl-monitor.sh` | Background service - เช็คโดเมนใหม่ทุก 30 นาที |
| `ssl-monitor-ctl.sh` | คำสั่งจัดการ monitor (status, logs, stop, start) |
| `cloudflare.ini` | Cloudflare API credentials |

---

## ขั้นตอนการใช้งาน

### 1. เตรียม cloudflare.ini

สร้างไฟล์ `cloudflare.ini` ในโฟลเดอร์เดียวกับ script:

```ini
dns_cloudflare_api_token = YOUR_CLOUDFLARE_API_TOKEN
```

### 2. รันติดตั้ง SSL ครั้งแรก

```bash
sudo bash 3.install-ssl.sh
```

**สิ่งที่สคริปต์ทำ:**

1. Copy `cloudflare.ini` ไปที่ `/certbot/cloudflare.ini`
2. ลบ certbot renew timer/cron ทั้งหมด
3. ลบ SSL certificate เดิมทั้งหมด
4. หยุด ssl-monitor เก่า (ถ้ามี)
5. ดึงรายชื่อโดเมนจาก API
6. ขอ Wildcard SSL (`*.domain`) ทุกโดเมน
7. อัพเดท Nimble config + restart
8. สร้าง deploy hook สำหรับ auto renew
9. ติดตั้ง + เปิด SSL Monitor background service
10. ส่งแจ้งเตือน Telegram `AUTO_SSL_START`

---

## SSL Monitor (Background Service)

### การทำงาน

- รันเป็น systemd service ชื่อ `ssl-monitor.service`
- เช็ค API ทุก **30 นาที** ว่ามีโดเมนใหม่หรือไม่
- เปรียบเทียบกับรายชื่อที่ติดตั้งแล้วใน `/etc/ssl-monitor/installed-domains.txt`
- ถ้ามีโดเมนใหม่ → ขอ cert + อัพเดท Nimble + restart + แจ้ง Telegram
- ถ้าไม่มีโดเมนใหม่ → เช็คไปเรื่อยๆ

### ป้องกันการทำงานซ้ำซ้อน

- ใช้ lock file (`/var/run/ssl-monitor.lock`) เก็บ PID
- ถ้ามี process เดิมรันอยู่ → ไม่รันซ้ำ
- ถ้า lock file ค้างจาก process ที่ตายไปแล้ว → ลบ lock แล้วรันต่อ

### Error Handling

- API ล่ม → log warning แล้วรอรอบถัดไป (ไม่หยุดทำงาน)
- certbot fail → log error + แจ้ง Telegram แล้วข้ามไปโดเมนถัดไป
- service crash → systemd จะ restart ให้อัตโนมัติ (หลังรอ 60 วินาที)

---

## คำสั่ง ssl-monitor-ctl

หลังจากรัน `3.install-ssl.sh` แล้ว จะสามารถใช้คำสั่ง `ssl-monitor-ctl` ได้:

### เช็คสถานะ

```bash
ssl-monitor-ctl status
```

แสดง: สถานะ service, PID, เวลาที่เริ่มทำงาน, รายชื่อโดเมนที่ติดตั้งแล้ว

### ดู Logs

```bash
# ดู 50 บรรทัดล่าสุด (default)
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

### หรือใช้ systemctl โดยตรง

```bash
systemctl status ssl-monitor
systemctl stop ssl-monitor
systemctl start ssl-monitor
journalctl -u ssl-monitor -f
```

---

## Telegram แจ้งเตือน

ระบบจะส่งแจ้งเตือนไปที่ Telegram อัตโนมัติ:

| ข้อความ | เมื่อไหร่ |
|---------|----------|
| `AUTO_SSL_START [hostname]` | เมื่อ monitor เริ่มทำงาน (รันครั้งแรก หรือ restart) |
| `AUTO_SSL_NEW [hostname]` | เมื่อติดตั้ง SSL โดเมนใหม่สำเร็จ |
| `AUTO_SSL_FAIL [hostname]` | เมื่อติดตั้ง SSL ไม่สำเร็จ |

ทุกข้อความจะแสดง hostname ของเครื่องและวันเวลาที่เกิดเหตุการณ์

---

## API โดเมน

**Endpoint:** `https://api-soccer.thai-play.com/api/domain/root-domains?token=353890`

**Response:**

```json
{
  "ok": true,
  "total": 2,
  "available": 2,
  "excluded": 0,
  "domains": [
    {
      "id": 77,
      "domain": "example.com",
      "excluded": false,
      "created_at": "2026-03-15 15:01:59"
    }
  ]
}
```

- ระบบจะดึงเฉพาะโดเมนที่ `excluded: false`
- โดเมนใหม่ที่เพิ่มเข้ามาใน API จะถูกติดตั้ง SSL อัตโนมัติภายใน 30 นาที

---

## ไฟล์สำคัญบนเซิร์ฟเวอร์

| Path | หน้าที่ |
|------|---------|
| `/etc/ssl-monitor/installed-domains.txt` | รายชื่อโดเมนที่ติดตั้ง SSL แล้ว |
| `/var/run/ssl-monitor.lock` | Lock file ป้องกันรันซ้ำ |
| `/certbot/cloudflare.ini` | Cloudflare credentials |
| `/etc/nimble/nimble.conf` | Nimble config (ssl_certificate) |
| `/etc/letsencrypt/live/` | Certificate files |
| `/etc/letsencrypt/renewal-hooks/deploy/99-nimble-reload.sh` | Auto renew hook |
| `/usr/local/bin/ssl-monitor.sh` | ไฟล์ monitor ที่ service เรียกใช้ |
| `/usr/local/bin/ssl-monitor-ctl` | คำสั่ง control |
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

สคริปต์จะ cleanup ทุกอย่าง (cert เดิม, cron, timer, monitor เก่า) แล้วเริ่มใหม่ทั้งหมด

### เพิ่มโดเมนใหม่ทันทีไม่ต้องรอ 30 นาที

```bash
ssl-monitor-ctl restart
```

Monitor จะเช็ค API ทันทีหลัง restart
