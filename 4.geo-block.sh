cat > /usr/local/bin/geo-allow-web.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
COUNTRIES=("th" "kh" "la" "sg" "ae" "vn" "lk" "mm")  # ประเทศที่อนุญาต (TH, KH, LA, SG, AE, VN, LK, MM)
WORKDIR="/etc/ipset-countries" # โฟลเดอร์เก็บไฟล์ .zone (CIDR)
SET_NAME_V4="cntry_allow_v4"
SET_NAME_V6="cntry_allow_v6"
ALLOW_PORTS="80,443,8081"      # จำกัดเว็บ + 8081 (RTMP 1935 ไม่แตะ)
IPDENY_V4="https://www.ipdeny.com/ipblocks/data/countries"
IPDENY_V6="https://www.ipdeny.com/ipv6/ipaddresses/blocks"

echo "[*] Install dependencies"
apt-get update -y
apt-get install -y ipset netfilter-persistent ipset-persistent curl ca-certificates

mkdir -p "$WORKDIR"

echo "[*] Create ipset sets"
ipset destroy $SET_NAME_V4 2>/dev/null || true
ipset destroy $SET_NAME_V6 2>/dev/null || true

ipset create $SET_NAME_V4 hash:net family inet  hashsize 1024 maxelem 100000
ipset create $SET_NAME_V6 hash:net family inet6 hashsize 1024 maxelem 100000

echo "[*] Download country CIDRs and populate ipset"
for c in "${COUNTRIES[@]}"; do
  # IPv4
  curl -fsSL "$IPDENY_V4/${c}.zone" -o "$WORKDIR/${c}.zone" || {
    echo "[-] Failed to fetch $IPDENY_V4/${c}.zone"
    exit 1
  }
  while read -r cidr; do
    [[ -z "$cidr" ]] && continue
    ipset add $SET_NAME_V4 "$cidr" 2>/dev/null || true
  done < "$WORKDIR/${c}.zone"

  # IPv6
  if curl -fsSL "$IPDENY_V6/${c}.zone" -o "$WORKDIR/${c}.ipv6.zone"; then
    while read -r cidr6; do
      [[ -z "$cidr6" ]] && continue
      ipset add $SET_NAME_V6 "$cidr6" 2>/dev/null || true
    done < "$WORKDIR/${c}.ipv6.zone"
  fi
done

echo "[*] Insert iptables rules (only 80/443)"
# ลบกฎเก่า
iptables   -D INPUT -p tcp -m multiport --dports $ALLOW_PORTS -m set --match-set $SET_NAME_V4 src -j ACCEPT 2>/dev/null || true
ip6tables  -D INPUT -p tcp -m multiport --dports $ALLOW_PORTS -m set --match-set $SET_NAME_V6 src -j ACCEPT 2>/dev/null || true
iptables   -D INPUT -p tcp -m multiport --dports $ALLOW_PORTS -j DROP 2>/dev/null || true
ip6tables  -D INPUT -p tcp -m multiport --dports $ALLOW_PORTS -j DROP 2>/dev/null || true

# ใส่กฎใหม่
iptables  -I INPUT 1 -p tcp -m multiport --dports $ALLOW_PORTS -m set --match-set $SET_NAME_V4 src -j ACCEPT
ip6tables -I INPUT 1 -p tcp -m multiport --dports $ALLOW_PORTS -m set --match-set $SET_NAME_V6 src -j ACCEPT
iptables  -I INPUT 2 -p tcp -m multiport --dports $ALLOW_PORTS -j DROP
ip6tables -I INPUT 2 -p tcp -m multiport --dports $ALLOW_PORTS -j DROP

echo "[*] Save ipset and firewall rules (persist across reboot)"
mkdir -p /etc/iptables
# ipset-persistent plugin โหลดไฟล์นี้ก่อน iptables ตอน boot
ipset save > /etc/iptables/ipsets
netfilter-persistent save

# เปิด service ให้ start อัตโนมัติเมื่อ reboot
systemctl enable netfilter-persistent >/dev/null 2>&1 || true

# ====== VERIFY + AUTO-FIX ======
verify_rules() {
  local fails=0
  local v4_count v6_count

  v4_count=$(ipset list "$SET_NAME_V4" 2>/dev/null | grep -cE '^[0-9a-fA-F:.]+/[0-9]+' || true)
  v6_count=$(ipset list "$SET_NAME_V6" 2>/dev/null | grep -cE '^[0-9a-fA-F:.]+/[0-9]+' || true)

  if [[ "$v4_count" -lt 1 ]]; then echo "  [-] ipset v4 empty"; fails=$((fails+1)); else echo "  [+] ipset v4: $v4_count CIDRs"; fi
  if [[ "$v6_count" -lt 1 ]]; then echo "  [-] ipset v6 empty (อาจไม่มีใน ipdeny — ข้ามได้)"; else echo "  [+] ipset v6: $v6_count CIDRs"; fi

  if iptables -C INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -m set --match-set "$SET_NAME_V4" src -j ACCEPT 2>/dev/null; then
    echo "  [+] iptables v4 ACCEPT rule present"
  else
    echo "  [-] iptables v4 ACCEPT rule missing"; fails=$((fails+1))
  fi
  if iptables -C INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -j DROP 2>/dev/null; then
    echo "  [+] iptables v4 DROP rule present"
  else
    echo "  [-] iptables v4 DROP rule missing"; fails=$((fails+1))
  fi
  if ip6tables -C INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -m set --match-set "$SET_NAME_V6" src -j ACCEPT 2>/dev/null; then
    echo "  [+] ip6tables ACCEPT rule present"
  else
    echo "  [-] ip6tables ACCEPT rule missing"; fails=$((fails+1))
  fi
  if ip6tables -C INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -j DROP 2>/dev/null; then
    echo "  [+] ip6tables DROP rule present"
  else
    echo "  [-] ip6tables DROP rule missing"; fails=$((fails+1))
  fi

  if [[ -s /etc/iptables/ipsets ]]; then echo "  [+] /etc/iptables/ipsets saved"; else echo "  [-] /etc/iptables/ipsets missing"; fails=$((fails+1)); fi
  if [[ -s /etc/iptables/rules.v4 ]]; then echo "  [+] /etc/iptables/rules.v4 saved"; else echo "  [-] /etc/iptables/rules.v4 missing"; fails=$((fails+1)); fi

  return $fails
}

auto_fix() {
  echo "[!] Auto-fix: re-applying rules..."
  iptables   -D INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -m set --match-set "$SET_NAME_V4" src -j ACCEPT 2>/dev/null || true
  ip6tables  -D INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -m set --match-set "$SET_NAME_V6" src -j ACCEPT 2>/dev/null || true
  iptables   -D INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -j DROP 2>/dev/null || true
  ip6tables  -D INPUT -p tcp -m multiport --dports "$ALLOW_PORTS" -j DROP 2>/dev/null || true
  iptables  -I INPUT 1 -p tcp -m multiport --dports "$ALLOW_PORTS" -m set --match-set "$SET_NAME_V4" src -j ACCEPT
  ip6tables -I INPUT 1 -p tcp -m multiport --dports "$ALLOW_PORTS" -m set --match-set "$SET_NAME_V6" src -j ACCEPT
  iptables  -I INPUT 2 -p tcp -m multiport --dports "$ALLOW_PORTS" -j DROP
  ip6tables -I INPUT 2 -p tcp -m multiport --dports "$ALLOW_PORTS" -j DROP
  mkdir -p /etc/iptables
  ipset save > /etc/iptables/ipsets
  netfilter-persistent save
}

echo "[*] Verify rules"
set +e
verify_rules
fails=$?
set -e

if [[ $fails -gt 0 ]]; then
  auto_fix
  echo "[*] Re-verify after auto-fix"
  set +e
  verify_rules
  fails=$?
  set -e
fi

if [[ $fails -gt 0 ]]; then
  echo "[X] VERIFY FAILED ($fails issue(s)) — ตรวจสอบ network / package ด้วยตนเอง"
  exit 1
fi

echo "[+] Done.
Allowed countries (ports $ALLOW_PORTS): ${COUNTRIES[*]}
RTMP 1935, SSH 22 และพอร์ตอื่นไม่ถูกแตะต้อง
Reboot-safe: netfilter-persistent + ipset-persistent enabled"
EOF

# ให้สิทธิ์รันได้
chmod +x /usr/local/bin/geo-allow-web.sh

# รันครั้งแรก
/usr/local/bin/geo-allow-web.sh

# ตั้ง cron ทุกวันตี 3
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/geo-allow-web.sh >> /var/log/geo-allow.log 2>&1") | crontab -
