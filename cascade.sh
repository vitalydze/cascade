#!/bin/bash
# Каскадный VPN: устройство --WireGuard--> RU-сервер --VLESS+Reality+XHTTP--> зарубежный сервер --> интернет
# Запускать на российском сервере (Ubuntu 22.04/24.04) от root.
#
# Установка:
#   wget -O /usr/local/bin/cascade https://raw.githubusercontent.com/vitalydze/cascade/main/cascade.sh
#   chmod +x /usr/local/bin/cascade
#   cascade install <IP зарубежного сервера>
#
# Команды:
#   cascade install <IP>   настроить оба сервера (можно запускать повторно, ключи сохраняются)
#   cascade add <имя>      новый клиент: конфиг в /root/cascade/<имя>.conf + QR-код
#   cascade del <имя>      удалить клиента
#   cascade list           клиенты и когда подключались
#   cascade status         состояние служб
#   cascade test           проверить, что трафик идёт через зарубежный сервер
#   cascade log <имя>      лог клиента: рукопожатия WireGuard, трафик, соединения (Ctrl+C — выход)

set -e
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

SNI=www.nvidia.com   # под какой сайт маскируется зарубежный сервер
WG_NET=10.66.66      # подсеть клиентов: сервер .1, клиенты .2, .3, ...
DIR=/etc/cascade     # ключи и настройки (файл env)
CLIENTS=/root/cascade  # конфиги клиентов, отсюда их забирать по SFTP
LOGS=/var/log/cascade  # логи по клиентам (<имя>.log) и TCP-соединений между серверами (tcp.log)

XRAY_INSTALL=https://github.com/XTLS/Xray-install/raw/main/install-release.sh

ru_ip()  { ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+'; }
wan_if() { ip -4 route get 1.1.1.1 | grep -oP 'dev \K\S+'; }

# ---------- Ключи: создаются один раз, лежат в /etc/cascade/env ----------
make_env() {
  mkdir -p $DIR && chmod 700 $DIR
  if [ ! -f $DIR/env ]; then
    KEYS=$(xray x25519)
    cat > $DIR/env <<EOF
UUID=$(xray uuid)
REALITY_PRIVATE=$(echo "$KEYS" | awk -F': ' 'NR==1 {print $2}')
REALITY_PUBLIC=$(echo "$KEYS" | awk -F': ' 'NR==2 {print $2}')
SHORT_ID=$(openssl rand -hex 8)
XHTTP_PATH=/$(openssl rand -hex 6)
WG_PORT=$(shuf -i 20000-60000 -n 1)
WG_KEY=$(wg genkey)
EOF
  fi
  sed -i '/^DE_IP=/d' $DIR/env
  echo "DE_IP=$DE_IP" >> $DIR/env
  source $DIR/env
}

# ---------- Конфиг Xray для зарубежного сервера ----------
de_config() {
  cat <<EOF
{
  "log": { "loglevel": "info", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp",
      "xhttpSettings": { "path": "$XHTTP_PATH" },
      "security": "reality",
      "realitySettings": {
        "target": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$REALITY_PRIVATE",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
  }],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": { "rules": [
    { "ip": ["geoip:private"], "outboundTag": "block" },
    { "protocol": ["bittorrent"], "outboundTag": "block" }
  ]}
}
EOF
}

# ---------- Конфиг Xray для RU-сервера ----------
# Трафик клиентов WireGuard попадает на порт 12345 (см. rules_up).
# Российские сайты идут напрямую отсюда, остальное — на зарубежный сервер.
# Порт 10808 (только локально) — для команды cascade test.
ru_config() {
  cat <<EOF
{
  "log": { "loglevel": "info", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [
    {
      "tag": "wg",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    },
    { "tag": "test", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [
    {
      "tag": "abroad",
      "protocol": "vless",
      "settings": { "vnext": [{ "address": "$DE_IP", "port": 443, "users": [{ "id": "$UUID", "encryption": "none" }] }] },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "$XHTTP_PATH", "extra": { "xmux": { "maxConcurrency": "16-32" } } },
        "security": "reality",
        "realitySettings": {
          "serverName": "$SNI",
          "fingerprint": "chrome",
          "publicKey": "$REALITY_PUBLIC",
          "shortId": "$SHORT_ID"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": { "rules": [
    { "inboundTag": ["test"], "outboundTag": "abroad" },
    { "ip": ["geoip:private"], "outboundTag": "block" },
    { "domain": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"], "outboundTag": "direct" },
    { "ip": ["geoip:ru"], "outboundTag": "direct" }
  ]}
}
EOF
}

# ---------- wg0.conf собирается из ключа сервера и файлов клиентов ----------
wg_config() {
  cat <<EOF
[Interface]
Address = $WG_NET.1/24
ListenPort = $WG_PORT
PrivateKey = $WG_KEY
PostUp = /usr/local/bin/cascade rules-up
PostDown = /usr/local/bin/cascade rules-down
EOF
  for f in $CLIENTS/*.conf; do
    [ -f "$f" ] || continue
    echo
    echo "[Peer]"
    echo "# $(basename $f .conf)"
    echo "PublicKey = $(grep PrivateKey $f | cut -d' ' -f3 | wg pubkey)"
    echo "AllowedIPs = $(grep Address $f | cut -d' ' -f3)"
  done
}

apply_wg() {
  wg_config > /etc/wireguard/wg0.conf
  chmod 600 /etc/wireguard/wg0.conf
  wg syncconf wg0 <(wg-quick strip wg0)
  systemctl try-restart cascade-watch   # чтобы лог узнал новых клиентов
}

# ---------- Подробные логи: одинаково на обоих серверах (второму передаётся через ssh) ----------
# Xray пишет каждое соединение в /var/log/xray/access.log, подробности и ошибки — в error.log.
# Здесь: ротация логов, статистика sysstat раз в минуту и журнал TCP-соединений со вторым сервером.
logs_setup() {
  PEER=$1   # IP второго сервера
  mkdir -p /var/log/cascade
  # ротация раз в сутки, храним 14 дней
  cat > /etc/logrotate.d/cascade <<'EOF'
/var/log/xray/*.log /var/log/cascade/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF
  # sysstat: снимок раз в минуту, плюс TCP/UDP-счётчики (смотреть: sar -n DEV,ETCP), храним 14 дней
  sed -i 's/^SADC_OPTIONS=.*/SADC_OPTIONS="-S DISK,SNMP"/; s/^HISTORY=.*/HISTORY=14/' /etc/sysstat/sysstat
  mkdir -p /etc/systemd/system/sysstat-collect.timer.d
  printf '[Timer]\nOnCalendar=\nOnCalendar=*:*:00\n' > /etc/systemd/system/sysstat-collect.timer.d/cascade.conf
  # открытие (SYN) и обрыв (RST) каждого TCP-соединения со вторым сервером;
  # повтор SYN без ответа — значит, пакеты до второго сервера не доходят
  cat > /etc/systemd/system/cascade-tcp.service <<EOF
[Unit]
Description=cascade: TCP-соединения с $PEER
After=network-online.target

[Service]
ExecStart=/bin/sh -c 'tcpdump -i any -nn -l -tttt "host $PEER and tcp port 443 and tcp[tcpflags] & (tcp-syn|tcp-rst) != 0" 2>/dev/null | cat >> /var/log/cascade/tcp.log'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl restart sysstat-collect.timer
  systemctl enable -q cascade-tcp
  systemctl restart cascade-tcp
}

# ---------- Лог по клиентам: /var/log/cascade/<имя>.log (служба cascade-watch, только RU) ----------
# Пишет: события WireGuard из ядра (рукопожатия, ошибки), трафик клиента за каждую минуту
# и каждое его соединение через Xray. Клиенты без событий в файл не пишутся.
watch_setup() {
  cat > /etc/systemd/system/cascade-watch.service <<EOF
[Unit]
Description=cascade: логи по клиентам
After=wg-quick@wg0.service xray.service

[Service]
ExecStart=/usr/local/bin/cascade watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q cascade-watch
  systemctl restart cascade-watch
}

cmd_watch() {
  mkdir -p $LOGS
  echo 'module wireguard +p' > /proc/dynamic_debug/control   # ядро начинает писать события WireGuard
  declare -A NAME   # публичный ключ или адрес 10.66.66.N -> имя клиента
  for f in $CLIENTS/*.conf; do
    [ -f "$f" ] || continue
    NAME[$(grep PrivateKey $f | cut -d' ' -f3 | wg pubkey)]=$(basename $f .conf)
    NAME[$(grep Address $f | cut -d' ' -f3 | cut -d/ -f1)]=$(basename $f .conf)
  done
  log() { printf '%(%F %T)T %s\n' -1 "$2" >> $LOGS/${1:-unknown}.log; }

  # 1) трафик каждого клиента за минуту: сколько пришло от него и сколько ушло ему
  (declare -A RX TX
   while sleep 60; do
     while read -r pub _ ep _ hs rx tx _; do
       old_rx=${RX[$pub]:-}; old_tx=${TX[$pub]:-}
       RX[$pub]=$rx; TX[$pub]=$tx
       [ -n "$old_rx" ] && [ "$rx" -ge "$old_rx" ] && [ "$tx" -ge "$old_tx" ] || continue  # первый замер или сброс счётчиков
       [ $((rx + tx)) -gt $((old_rx + old_tx)) ] || continue                              # трафика не было
       [ "$hs" = 0 ] && ago=нет || ago="$(( $(date +%s) - hs )) с назад"
       log "${NAME[$pub]:-}" "трафик за минуту: от клиента $(numfmt --to=iec $((rx - old_rx))), клиенту $(numfmt --to=iec $((tx - old_tx))); рукопожатие: $ago; адрес: $ep"
     done < <(wg show wg0 dump | tail -n +2)
   done) &

  # 2) события WireGuard из ядра. Не пишем keepalive (каждые 25 с, их видно по трафику)
  #    и IPv6-пакеты, которые сервер отбрасывает (unallowed src IP): их сотни в минуту
  (declare -A PEER   # номер peer в ядре -> имя клиента
   journalctl -k -f -n 0 -o cat | grep --line-buffered 'wg0: ' | grep --line-buffered -vE 'keepalive|unallowed src IP' |
   while read -r line; do
     msg=${line#*wg0: }
     id=; ep=; name=
     [[ $msg =~ peer\ ([0-9]+) ]] && id=${BASH_REMATCH[1]}
     [[ $msg =~ \(([^\)]+)\)$ || $msg =~ from\ ([^ ]+)$ ]] && ep=${BASH_REMATCH[1]}
     [ -n "$id" ] && name=${PEER[$id]:-}
     if [ -z "$name" ] && [ -n "$ep" ]; then   # номер ещё не знаем — ищем клиента по адресу, потом по IP
       pub=$(wg show wg0 endpoints | awk -v ep="$ep" -v ip="${ep%:*}:" '$2 == ep {print $1; exit} index($2, ip) == 1 {p = $1} END {print p}' | head -1)
       [ -n "$pub" ] && name=${NAME[$pub]:-}
       [ -n "$id" ] && [ -n "$name" ] && PEER[$id]=$name
     fi
     log "$name" "WireGuard: $msg"
   done) &

  # 3) соединения через Xray из error.log: у каждого соединения свой номер [id].
  #    По строке "received request for 10.66.66.N" узнаём клиента, дальше пишем сайт и маршрут,
  #    а все необычные строки (ошибки, обрывы) — как есть.
  (declare -A SESS   # номер соединения -> имя клиента
   tail -F -n 0 /var/log/xray/error.log 2>/dev/null | while read -r d t lvl id msg; do
     id=${id//[\[\]]/}
     [ -n "$id" ] || continue
     t="${d//\//-} ${t%.*}"
     case $msg in
       "proxy/dokodemo: received request for "*)
         ip=${msg##* }; ip=${ip%:*}
         [ ${#SESS[@]} -lt 50000 ] || SESS=()   # чтобы не копить память
         [ -n "${NAME[$ip]:-}" ] && SESS[$id]=${NAME[$ip]} ;;
       *)
         n=${SESS[$id]:-}
         [ -n "$n" ] || continue
         case $msg in
           *"default route for "*)  echo "$t xray: ${msg##* } -> abroad" ;;
           *"taking detour ["*)     r=${msg#*detour [}; x=${msg##*for [}; echo "$t xray: ${x%]} -> ${r%%]*}" ;;
           *"sniffed domain"*|*"is dialing to"*|*"tunneling request"*|*"dialing TCP"*|*"connection opened"*) continue ;;
           *)                       echo "$t xray $lvl [$id]: $msg" ;;
         esac >> $LOGS/$n.log ;;
     esac
   done) &

  wait -n; exit 1   # если какая-то часть остановилась — systemd перезапустит службу
}

cmd_log() {
  [ -f "$LOGS/$1.log" ] || { echo "Использование: cascade log <имя>. Есть логи: $(cd $LOGS 2>/dev/null && ls *.log | sed 's/\.log$//' | tr '\n' ' ')"; exit 1; }
  tail -n 100 -f "$LOGS/$1.log"
}

# ---------- Правила: трафик из wg0 -> Xray (порт 12345). Вызываются из wg0.conf ----------
rules_up() {
  rules_down
  ip rule add fwmark 1 lookup 100
  ip route add local default dev lo table 100
  iptables -t mangle -N CASCADE
  iptables -t mangle -A CASCADE -d $WG_NET.0/24 -j RETURN
  iptables -t mangle -A CASCADE -d 127.0.0.0/8 -j RETURN
  iptables -t mangle -A CASCADE -d 224.0.0.0/3 -j RETURN
  iptables -t mangle -A CASCADE -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port 12345 --tproxy-mark 1
  iptables -t mangle -A CASCADE -p udp -j TPROXY --on-ip 127.0.0.1 --on-port 12345 --tproxy-mark 1
  iptables -t mangle -A PREROUTING -i wg0 -j CASCADE
  # ping не проксируется, выпускаем его напрямую отсюда
  iptables -I FORWARD -i wg0 -p icmp -j ACCEPT
  iptables -I FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -t nat -A POSTROUTING -s $WG_NET.0/24 -o $(wan_if) -j MASQUERADE
}

rules_down() {
  ip rule del fwmark 1 lookup 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i wg0 -j CASCADE 2>/dev/null || true
  iptables -t mangle -F CASCADE 2>/dev/null || true
  iptables -t mangle -X CASCADE 2>/dev/null || true
  iptables -D FORWARD -i wg0 -p icmp -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s $WG_NET.0/24 -o $(wan_if) -j MASQUERADE 2>/dev/null || true
}

# ---------- Команды ----------
cmd_install() {
  DE_IP=$1
  [ -n "$DE_IP" ] || { echo "Использование: cascade install <IP зарубежного сервера>"; exit 1; }

  echo "== 1/5 Пакеты и Xray на этом сервере"
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq curl openssl wireguard-tools qrencode iptables ufw tcpdump sysstat >/dev/null
  bash -c "$(curl -fsSL $XRAY_INSTALL)" @ install >/dev/null
  make_env

  echo "== 2/5 SSH-доступ к $DE_IP"
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
  if ! ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new root@$DE_IP true; then
    echo "Введи root-пароль зарубежного сервера:"
    ssh-copy-id -o StrictHostKeyChecking=accept-new root@$DE_IP
  fi

  echo "== 3/5 Зарубежный сервер: Xray, firewall, BBR"
  ssh root@$DE_IP 'bash -s' <<'EOF'
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get -o DPkg::Lock::Timeout=300 update -qq
apt-get -o DPkg::Lock::Timeout=300 install -y -qq curl ufw tcpdump sysstat >/dev/null
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/90-bbr.conf
sysctl -q --system
ufw allow 22/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
EOF
  de_config | ssh root@$DE_IP 'cat > /usr/local/etc/xray/config.json && xray run -test -c /usr/local/etc/xray/config.json >/dev/null && systemctl enable -q xray && systemctl restart xray'
  ssh root@$DE_IP "$(declare -f logs_setup); logs_setup $(ru_ip)"

  echo "== 4/5 Этот сервер: Xray, WireGuard, firewall"
  ru_config > /usr/local/etc/xray/config.json
  xray run -test -c /usr/local/etc/xray/config.json >/dev/null
  systemctl enable -q xray
  systemctl restart xray

  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-cascade.conf
  sysctl -q --system

  ufw allow 22/tcp >/dev/null
  ufw allow $WG_PORT/udp >/dev/null
  # UFW режет пакеты из wg0 с "чужим" адресом назначения ещё до правил allow — разрешаем wg0 раньше
  grep -q 'cascade' /etc/ufw/before.rules || sed -i '/^-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT/a # cascade: трафик клиентов WireGuard\n-A ufw-before-input -i wg0 -j ACCEPT' /etc/ufw/before.rules
  ufw --force enable >/dev/null
  ufw reload >/dev/null

  mkdir -p $CLIENTS && chmod 700 $CLIENTS
  wg_config > /etc/wireguard/wg0.conf
  chmod 600 /etc/wireguard/wg0.conf
  systemctl enable -q wg-quick@wg0
  systemctl restart wg-quick@wg0
  logs_setup $DE_IP
  watch_setup

  echo "== 5/5 Проверка"
  sleep 3
  cmd_test
  echo
  echo "Готово. Добавить устройство: cascade add iphone"
}

cmd_add() {
  NAME=$1
  [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Использование: cascade add <имя> (латиница, цифры, - и _)"; exit 1; }
  F=$CLIENTS/$NAME.conf
  [ ! -f $F ] || { echo "Клиент $NAME уже есть: $F"; exit 1; }

  # первый свободный адрес: .2, .3, ...
  N=2
  while grep -qs "Address = $WG_NET.$N/" $CLIENTS/*.conf; do N=$((N + 1)); done

  cat > $F <<EOF
[Interface]
PrivateKey = $(wg genkey)
Address = $WG_NET.$N/32
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280

[Peer]
PublicKey = $(echo $WG_KEY | wg pubkey)
Endpoint = $(ru_ip):$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 600 $F
  apply_wg
  qrencode -t ansiutf8 < $F
  echo "Клиент $NAME: $F"
}

cmd_del() {
  F=$CLIENTS/$1.conf
  [ -f "$F" ] || { echo "Нет клиента $1"; exit 1; }
  rm $F
  apply_wg
  echo "Клиент $1 удалён"
}

cmd_list() {
  for f in $CLIENTS/*.conf; do
    [ -f "$f" ] || continue
    PUB=$(grep PrivateKey $f | cut -d' ' -f3 | wg pubkey)
    T=$(wg show wg0 latest-handshakes | grep -F "$PUB" | cut -f2)
    if [ -z "$T" ] || [ "$T" = 0 ]; then SEEN="нет подключения"; else SEEN="$(( $(date +%s) - T )) сек назад"; fi
    printf "%-12s %-14s %s\n" "$(basename $f .conf)" "$(grep Address $f | cut -d' ' -f3)" "$SEEN"
  done
}

cmd_status() {
  echo "xray:       $(systemctl is-active xray)"
  echo "wireguard:  $(systemctl is-active wg-quick@wg0)"
  echo "зарубежный: $DE_IP"
  echo
  cmd_list
}

cmd_test() {
  IP=$(curl -s -m 15 --socks5-h 127.0.0.1:10808 https://api.ipify.org || true)
  if [ "$IP" = "$DE_IP" ]; then
    echo "OK: выход через $IP"
  else
    echo "ОШИБКА: через Xray ответ '$IP', ожидался $DE_IP"
    exit 1
  fi

  # 50 параллельных запросов: так ведёт себя телефон или браузер
  OK=$( (for i in $(seq 50); do
          curl -s -m 20 --socks5-h 127.0.0.1:10808 -o /dev/null -w '%{http_code}\n' https://api.ipify.org &
        done; wait) | grep -c 200 || true)
  echo "Параллельные запросы: $OK из 50"

  curl -s -m 30 --socks5-h 127.0.0.1:10808 -o /dev/null -w '%{speed_download}\n' \
    'https://speed.cloudflare.com/__down?bytes=10000000' | awk '{printf "Скорость: %.0f Мбит/с\n", $1 * 8 / 1000000}'
}

# ---------- Запуск ----------
[ "$(id -u)" = 0 ] || { echo "Запускать от root"; exit 1; }
[ "$1" = install ] || [ -f $DIR/env ] || { echo "Сначала: cascade install <IP зарубежного сервера>"; exit 1; }
[ -f $DIR/env ] && source $DIR/env

case "$1" in
  install)    cmd_install "$2" ;;
  add)        cmd_add "$2" ;;
  del)        cmd_del "$2" ;;
  list)       cmd_list ;;
  status)     cmd_status ;;
  test)       cmd_test ;;
  log)        cmd_log "$2" ;;
  watch)      cmd_watch ;;
  rules-up)   rules_up ;;
  rules-down) rules_down ;;
  *)          sed -n '2,17p' "$0" ;;
esac
