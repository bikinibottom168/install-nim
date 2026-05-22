cat > /usr/local/bin/geo-block-eu.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
# ประเทศที่จะ BLOCK (ยุโรปทั้งหมด + UK + แอฟริกาทั้งหมด)
COUNTRIES=(
  # ===== EUROPE =====
  # EU 27
  at be bg hr cy cz dk ee fi fr de gr hu ie it lv lt lu mt nl pl pt ro sk si es se
  # UK + EFTA
  gb is no ch li
  # Balkans + Eastern Europe
  al ba mk me rs xk md ua by ru
  # Microstates + Crown dependencies + Faroe/Gibraltar
  ad mc sm va im je gg fo gi
  # Turkey (ครึ่งยุโรปครึ่งเอเชีย)
  tr

  # ===== AFRICA =====
  # North Africa
  dz eg ly ma sd tn eh
  # West Africa
  bj bf cv ci gm gh gn gw lr ml mr ne ng sn sl tg
  # Central Africa
  ao cm cf td cg cd gq ga st
  # East Africa
  bi km dj er et ke mg mw mu yt mz re rw sc so ss tz ug
  # Southern Africa
  bw ls na za sz zm zw
  # South Atlantic
  sh
)
WORKDIR="/etc/ipset-countries"
SET_NAME_V4="cntry_block_v4"
SET_NAME_V6="cntry_block_v6"
BLOCK_PORTS="80,443,8081"      # บล็อกเฉพาะพอร์ตเหล่านี้ (RTMP 1935 ไม่แตะ)
IPDENY_V4="https://www.ipdeny.com/ipblocks/data/countries"
IPDENY_V6="https://www.ipdeny.com/ipv6/ipaddresses/blocks"

echo "[*] Install dependencies"
apt-get update -y
apt-get install -y ipset netfilter-persistent ipset-persistent curl ca-certificates

mkdir -p "$WORKDIR"

# ====== Cleanup กฎเก่าจาก allow-list (ถ้าเคยรันเวอร์ชันก่อน) ======
echo "[*] Cleanup old allow-list rules (if any)"
for p in "80,443" "80,443,8081"; do
  iptables   -D INPUT -p tcp -m multiport --dports "$p" -m set --match-set cntry_allow_v4 src -j ACCEPT 2>/dev/null || true
  ip6tables  -D INPUT -p tcp -m multiport --dports "$p" -m set --match-set cntry_allow_v6 src -j ACCEPT 2>/dev/null || true
  iptables   -D INPUT -p tcp -m multiport --dports "$p" -j DROP 2>/dev/null || true
  ip6tables  -D INPUT -p tcp -m multiport --dports "$p" -j DROP 2>/dev/null || true
done
ipset destroy cntry_allow_v4 2>/dev/null || true
ipset destroy cntry_allow_v6 2>/dev/null || true

# ====== ลบ rule ที่อ้าง set เดิม (ของ block-list) ก่อน destroy ======
echo "[*] Reset block-list ipset"
iptables   -D INPUT -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V4" src -j DROP 2>/dev/null || true
ip6tables  -D INPUT -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V6" src -j DROP 2>/dev/null || true
ipset destroy $SET_NAME_V4 2>/dev/null || true
ipset destroy $SET_NAME_V6 2>/dev/null || true

ipset create $SET_NAME_V4 hash:net family inet  hashsize 4096 maxelem 500000
ipset create $SET_NAME_V6 hash:net family inet6 hashsize 4096 maxelem 500000

echo "[*] Download country CIDRs and populate ipset"
skipped_v4=()
skipped_v6=()
for c in "${COUNTRIES[@]}"; do
  if curl -fsL "$IPDENY_V4/${c}.zone" -o "$WORKDIR/${c}.zone" 2>/dev/null; then
    while read -r cidr; do
      [[ -z "$cidr" ]] && continue
      ipset add $SET_NAME_V4 "$cidr" 2>/dev/null || true
    done < "$WORKDIR/${c}.zone"
  else
    skipped_v4+=("$c")
  fi
  if curl -fsL "$IPDENY_V6/${c}.zone" -o "$WORKDIR/${c}.ipv6.zone" 2>/dev/null; then
    while read -r cidr6; do
      [[ -z "$cidr6" ]] && continue
      ipset add $SET_NAME_V6 "$cidr6" 2>/dev/null || true
    done < "$WORKDIR/${c}.ipv6.zone"
  else
    skipped_v6+=("$c")
  fi
done
[[ ${#skipped_v4[@]} -gt 0 ]] && echo "  [-] No v4 zone: ${skipped_v4[*]}"
[[ ${#skipped_v6[@]} -gt 0 ]] && echo "  [-] No v6 zone: ${skipped_v6[*]}"

echo "[*] Insert iptables DROP rules (ports $BLOCK_PORTS)"
iptables  -I INPUT 1 -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V4" src -j DROP
ip6tables -I INPUT 1 -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V6" src -j DROP

echo "[*] Save ipset and firewall rules (persist across reboot)"
mkdir -p /etc/iptables
ipset save > /etc/iptables/ipsets
netfilter-persistent save
systemctl enable netfilter-persistent >/dev/null 2>&1 || true

# ====== VERIFY + AUTO-FIX ======
verify_rules() {
  local fails=0
  local v4_count v6_count

  v4_count=$(ipset list "$SET_NAME_V4" 2>/dev/null | grep -cE '^[0-9a-fA-F:.]+/[0-9]+' || true)
  v6_count=$(ipset list "$SET_NAME_V6" 2>/dev/null | grep -cE '^[0-9a-fA-F:.]+/[0-9]+' || true)

  if [[ "$v4_count" -lt 1 ]]; then echo "  [-] ipset v4 empty"; fails=$((fails+1)); else echo "  [+] ipset v4: $v4_count CIDRs"; fi
  if [[ "$v6_count" -lt 1 ]]; then echo "  [-] ipset v6 empty (อาจไม่มีใน ipdeny — ข้ามได้)"; else echo "  [+] ipset v6: $v6_count CIDRs"; fi

  if iptables -C INPUT -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V4" src -j DROP 2>/dev/null; then
    echo "  [+] iptables v4 DROP rule present"
  else
    echo "  [-] iptables v4 DROP rule missing"; fails=$((fails+1))
  fi
  if ip6tables -C INPUT -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V6" src -j DROP 2>/dev/null; then
    echo "  [+] ip6tables DROP rule present"
  else
    echo "  [-] ip6tables DROP rule missing"; fails=$((fails+1))
  fi

  if [[ -s /etc/iptables/ipsets ]]; then echo "  [+] /etc/iptables/ipsets saved"; else echo "  [-] /etc/iptables/ipsets missing"; fails=$((fails+1)); fi
  if [[ -s /etc/iptables/rules.v4 ]]; then echo "  [+] /etc/iptables/rules.v4 saved"; else echo "  [-] /etc/iptables/rules.v4 missing"; fails=$((fails+1)); fi

  return $fails
}

auto_fix() {
  echo "[!] Auto-fix: re-applying DROP rules..."
  iptables   -D INPUT -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V4" src -j DROP 2>/dev/null || true
  ip6tables  -D INPUT -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V6" src -j DROP 2>/dev/null || true
  iptables  -I INPUT 1 -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V4" src -j DROP
  ip6tables -I INPUT 1 -p tcp -m multiport --dports "$BLOCK_PORTS" -m set --match-set "$SET_NAME_V6" src -j DROP
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
Blocked: ${#COUNTRIES[@]} European countries on ports $BLOCK_PORTS
Open globally: RTMP 1935, SSH 22, และพอร์ตอื่นทั้งหมด
Reboot-safe: netfilter-persistent + ipset-persistent enabled"
EOF

# ให้สิทธิ์รันได้
chmod +x /usr/local/bin/geo-block-eu.sh

# ลบ script เก่า (allow-list) ถ้ามี
rm -f /usr/local/bin/geo-allow-web.sh

# ล้าง cron เก่า + ใส่ใหม่ (กัน duplicate)
( crontab -l 2>/dev/null | grep -v 'geo-allow-web.sh' | grep -v 'geo-block-eu.sh'; \
  echo "30 3 * * * /usr/local/bin/geo-block-eu.sh >> /var/log/geo-block.log 2>&1" ) | crontab -

# รันครั้งแรก
/usr/local/bin/geo-block-eu.sh
