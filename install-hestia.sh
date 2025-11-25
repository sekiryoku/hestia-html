#!/usr/bin/env bash
set -euo pipefail

# Версия скрипта (для диагностики загрузки актуальной версии)
SCRIPT_VERSION="2025-10-27-b"
echo "Hestia installer version: ${SCRIPT_VERSION}"

# ==============================
#  Настройки пользователя (можно переопределить переменными окружения)
# ==============================
HOSTNAME=${HOSTNAME:-"panel.example.com"}
USERNAME=${USERNAME:-"admin123"}
EMAIL=${EMAIL:-"admin@example.com"}
PASSWORD=${PASSWORD:-"346@1MuXpl'e+TR"}
PHP_VERSION=${PHP_VERSION:-"8.4"}

# ==============================
#  Функции
# ==============================

disable_auto_updates() {
  echo "🧯 Отключаю автообновления..."
  # Останавливаем таймеры и сервисы неблокирующе
  systemctl stop --no-block apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  systemctl stop --no-block apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >/dev/null 2>&1 || true

  # Маскируем, чтобы они не перезапускались
  systemctl mask apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  systemctl disable unattended-upgrades.service >/dev/null 2>&1 || true

  # Если зависли процессы — принудительно завершаем
  systemctl kill -s SIGKILL --kill-who=all apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
  pkill -f "apt.systemd.daily" >/dev/null 2>&1 || true

  echo "⏸️  Автообновления остановлены/замаскированы, проверяю занятость APT..."
  echo "✅ Автообновления отключены."
}

enable_auto_updates() {
  echo "🔄 Включаю автообновления обратно..."
  # Размаскируем и включаем обратно
  systemctl unmask apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  systemctl enable unattended-upgrades.service apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  systemctl start --no-block unattended-upgrades.service apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
  systemctl start --no-block apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  echo "✅ Автообновления снова включены."
}

wait_for_apt() {
  echo "⏳ Проверка: не занят ли apt/dpkg..."
  local timeout=600  # максимум 10 минут ожидания
  local interval=10
  local elapsed=0

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        pgrep -x "apt" >/dev/null || \
        pgrep -x "apt-get" >/dev/null || \
        pgrep -f "apt.systemd.daily" >/dev/null || \
        pgrep -x "unattended-upgrade" >/dev/null; do
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "❌ Время ожидания apt истекло (10 минут). Прерываю."
      exit 1
    fi
    echo "⚙️  APT в данный момент используется. Жду освобождения..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "✅ APT свободен — продолжаем установку!"
}

ensure_wget() {
  if ! command -v wget >/dev/null 2>&1; then
    echo "📦 Устанавливаю wget..."
    apt-get update -y
    apt-get install -y wget
  fi
}

ensure_hostname() {
  echo "🔎 Проверяю hostname: $HOSTNAME"
  # Базовая проверка формата FQDN (латиница/цифры/дефисы, несколько сегментов)
  if ! [[ "$HOSTNAME" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo "⚠️  Некорректный hostname. Нужен FQDN (пример: panel.example.com)."
    echo "ℹ️  Можно передать переменную: HOSTNAME=panel.mydomain.com"
    # Фолбэк: используем nip.io, который резолвит на указанный IP
    local ip
    ip=$(hostname -I | awk '{print $1}')
    HOSTNAME="panel.${ip}.nip.io"
    echo "➡️  Автоматически устанавливаю hostname: $HOSTNAME"
  fi

  # Устанавливаем системный hostname
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$HOSTNAME" || true
  else
    echo "$HOSTNAME" > /etc/hostname || true
  fi

  # Обеспечиваем локальное резолвинг через /etc/hosts, если DNS ещё не настроен
  local ip short
  ip=$(hostname -I | awk '{print $1}')
  short=${HOSTNAME%%.*}
  if ! grep -qE "\s$HOSTNAME(\s|$)" /etc/hosts; then
    echo "$ip $HOSTNAME $short" >> /etc/hosts
  fi

  # Проверяем доступность резолвинга
  if getent hosts "$HOSTNAME" >/dev/null 2>&1; then
    echo "✅ Hostname резолвится."
  else
    echo "⚠️  DNS/hosts для $HOSTNAME не найден. Добавил запись в /etc/hosts, продолжаю установку."
  fi
}

# На любой выход стараемся вернуть автообновления
trap 'enable_auto_updates' EXIT

# ==============================
#  Основной процесс установки
# ==============================

disable_auto_updates
wait_for_apt
ensure_wget
ensure_hostname

echo "⬇️  Скачиваю установщик HestiaCP..."
wget -q https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh -O hst-install.sh

if [ ! -f "hst-install.sh" ]; then
  echo "❌ Ошибка: не удалось загрузить установочный скрипт!"
  exit 1
fi

echo "🚀 Запускаю установку HestiaCP..."
bash hst-install.sh \
  --interactive no \
  --hostname "$HOSTNAME" \
  --username "$USERNAME" \
  --email "$EMAIL" \
  --password "$PASSWORD" \
  --apache no \
  --named no \
  --clamav no \
  --spamassassin no \
  --mysql no \
  --multiphp "$PHP_VERSION" \
  --quota no \
  --webterminal no \
  --iptables no \
  --fail2ban no \
  --force

# Если добрались сюда — установка прошла успешно (set -e)
IP=$(hostname -I | awk '{print $1}')
echo
echo "============================================================"
echo "✅ Установка HestiaCP завершена!"
echo "Панель: https://$IP:8083"
echo "Username: $USERNAME"
echo "Password: $PASSWORD"
echo "============================================================"

echo "🏁 Скрипт завершён!"