#!/bin/bash

set -euo pipefail

GREEN="\e[32m"
BOLD="\e[1m"
RESET="\e[0m"

log() {
    echo -e "${GREEN}${BOLD}$1${RESET}"
}

whiptail_prompt() {
    local message="$1"
    local title="$2"
    whiptail --inputbox "$message" 8 78 --title "$title" 3>&1 1>&2 2>&3
}

install_packages() {
    log "Gerekli paketler kontrol ediliyor..."
    if command -v apt >/dev/null 2>&1; then
        apt-get update
        apt-get install -y wget whiptail iproute2 systemd
        wget https://github.com/3proxy/3proxy/releases/download/0.9.5/3proxy-0.9.5.x86_64.deb
        dpkg -i 3proxy-0.9.5.x86_64.deb || apt-get install -f -y
    elif command -v dnf >/dev/null 2>&1; then
        dnf update -y
        dnf install -y wget dialog iproute systemd
        wget https://github.com/3proxy/3proxy/releases/download/0.9.5/3proxy-0.9.5.x86_64.rpm
        rpm -ivh 3proxy-0.9.5.x86_64.rpm
    else
        echo "❌ Desteklenmeyen sistem. APT ya da DNF bulunamadı."
        exit 1
    fi
}

[[ "$(id -u)" -ne 0 ]] && { echo "❌ Script root olarak çalıştırılmalıdır."; exit 1; }

# Kurulum kontrolü
if [ ! -f /ipv6lw ]; then
    install_packages
    touch /ipv6lw
fi

# Kullanıcı Seçimleri
AuthType=$(whiptail --title "Kimlik Doğrulama Türü" --menu "Bir kimlik doğrulama yöntemi seçin:" 15 60 2 \
"PASS" "Kullanıcı adı / şifre ile" \
"IP" "IP Whitelist (şifresiz)" 3>&1 1>&2 2>&3)

ProxyType=$(whiptail --title "Proxy Türü" --menu "Bir proxy türü seçin:" 15 60 2 \
"HTTP" "HTTP/HTTPS Proxy" \
"SOCKS5" "SOCKS5 Proxy" 3>&1 1>&2 2>&3)

LogEnable=$(whiptail --title "Loglama Ayarı" --menu "Log açılsın mı?" 10 60 2 \
"YES" "Evet, proxy erişimleri loglansın" \
"NO" "Hayır, log tutulmasın" 3>&1 1>&2 2>&3)

Interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
IF_MENU=()
for iface in "${Interfaces[@]}"; do
    IF_MENU+=("$iface" " ")
done

Interface=$(whiptail --title "Ağ Arayüzü" --menu "IPv6 atanacak arayüzü seçin:" 20 78 10 "${IF_MENU[@]}" 3>&1 1>&2 2>&3)

IPv6=$(ip -6 addr show dev "$Interface" scope global | grep -oP 'inet6 \K[0-9a-f:]+(?=/)' | head -n1)
[[ -z "$IPv6" ]] && { echo "❌ Bu arayüzde global bir IPv6 adresi bulunamadı."; exit 1; }

IPv6_Base=$(echo "$IPv6" | awk -F: '{printf "%s:%s:%s:%s", $1, $2, $3, $4}')
ProxyCount=$(whiptail_prompt "Kaç adet proxy oluşturulsun?" "Proxy Sayısı")

if [[ "$AuthType" == "PASS" ]]; then
    UserName=$(whiptail_prompt "Kullanıcı adı girin" "Proxy Auth")
    Password=$(whiptail_prompt "Şifre girin" "Proxy Auth")
else
    AllowIP=$(whiptail_prompt "Erişime izin verilecek IP adresini girin" "IP Whitelist")
fi

# IPv6 Listesi Hazırlama
IPv6_Array=()
for ((i = 1; i <= ProxyCount; i++)); do
    IPv6_Array+=("$IPv6_Base::$(printf '%x' $i)")
done

# 3proxy Yapılandırması
log "3proxy yapılandırması oluşturuluyor..."
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
cat <<EOF > "$CONFIG_FILE"
daemon
nserver 1.1.1.1
nserver 8.8.8.8
maxconn 500
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
internal 0.0.0.0
flush
EOF

[[ "$LogEnable" == "YES" ]] && echo "log /var/log/3proxy.log D" >> "$CONFIG_FILE"

if [[ "$AuthType" == "PASS" ]]; then
    echo -e "auth strong\nusers $UserName:CL:$Password\nallow $UserName" >> "$CONFIG_FILE"
else
    echo -e "auth iponly\nallow * $AllowIP" >> "$CONFIG_FILE"
fi

Port=30000
for ip in "${IPv6_Array[@]}"; do
    ((Port++))
    [[ "$ProxyType" == "SOCKS5" ]] && echo "socks -6 -n -a -p$Port -e$ip" >> "$CONFIG_FILE" || echo "proxy -6 -n -a -p$Port -e$ip" >> "$CONFIG_FILE"
done

# --- KALICILIK VE OTOMASYON BÖLÜMÜ ---

log "Kalıcılık ayarları yapılıyor..."

# 1. IP Atama Scripti (Helper)
PERSISTENT_SCRIPT="/usr/local/bin/proxy-ipv6-add.sh"
echo '#!/bin/bash' > "$PERSISTENT_SCRIPT"
for ip in "${IPv6_Array[@]}"; do
    echo "ip -6 addr add $ip/64 dev $Interface 2>/dev/null || true" >> "$PERSISTENT_SCRIPT"
done
chmod +x "$PERSISTENT_SCRIPT"

# 2. Systemd Servisi (Reboot için)
SERVICE_FILE="/etc/systemd/system/proxy-ipv6.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=IPv6 Proxy Address Persistence
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$PERSISTENT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 3. NetworkManager Tetikleyicisi (Uzak Masaüstü / Bağlantı Kopması için)
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
if [ -d "$DISPATCHER_DIR" ]; then
    log "NetworkManager tetikleyicisi ekleniyor..."
    cat <<EOF > "$DISPATCHER_DIR/99-proxy-ipv6"
#!/bin/bash
if [ "\$2" = "up" ]; then
    /usr/bin/systemctl restart proxy-ipv6.service
    /usr/bin/systemctl restart 3proxy
fi
EOF
    chmod +x "$DISPATCHER_DIR/99-proxy-ipv6"
fi

# Servisleri Aktifleştir
systemctl daemon-reload
systemctl enable proxy-ipv6.service
systemctl enable 3proxy
$PERSISTENT_SCRIPT # IP'leri hemen şimdi ata

log "3proxy başlatılıyor..."
systemctl restart 3proxy

log "İşlem Tamam! Reboot atsanız da, Uzak Masaüstü ile bağlansanız da proxyleriniz kalıcıdır."
log "Proxy Listesi:"
Port=30000
for ip in "${IPv6_Array[@]}"; do
    ((Port++))
    echo "Port: $Port -> IPv6: $ip"
done
