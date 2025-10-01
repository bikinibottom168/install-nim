cat > /usr/local/bin/geo-allow-web.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
COUNTRIES=("th" "kh" "la")     # ประเทศที่อนุญาต
WORKDIR="/etc/ipset-countries" # โฟลเดอร์เก็บไฟล์ .zone (CIDR)
SET_NAME_V4="cntry_allow_v4"
SET_NAME_V6="cntry_allow_v6"
ALLOW_PORTS="80,443"           # จำกัดเฉพาะเว็บ
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

echo "[*] Save ipset and firewall rules"
ipset save > /etc/ipset.d/$SET_NAME_V4.conf || true
netfilter-persistent save

echo "[+] Done.
Allowed countries (web ports $ALLOW_PORTS): ${COUNTRIES[*]}
SSH (22) และพอร์ตอื่นไม่ถูกแตะต้อง"
EOF

# ให้สิทธิ์รันได้
chmod +x /usr/local/bin/geo-allow-web.sh

# รันครั้งแรก
/usr/local/bin/geo-allow-web.sh

# ตั้ง cron ทุกวันตี 3
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/geo-allow-web.sh >> /var/log/geo-allow.log 2>&1") | crontab -
