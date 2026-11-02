#!/usr/bin/env bash
# Ежечасный сбор статистики Nginx и отправка отчёта по электронной почте.
# Скрипт рассчитан на Ubuntu и стандартный формат access.log/error.log Nginx.

set -Eeuo pipefail
umask 077

# Задаём пути к журналам, файлу состояния и SMTP-клиенту.
readonly ACCESS_DIR="/var/log/nginx"
readonly STATE_FILE="/var/lib/nginx-monitoring/last_success_epoch"
readonly LOCK_FILE="/run/nginx-monitoring/monitor.lock"
readonly MAIL_CONFIG="/etc/msmtprc"
readonly TOP_COUNT=10
readonly MAX_ERROR_LINES=200

# Создаём временные файлы и удаляем их при любом штатном завершении или сигнале.
TMP_DIR=""
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
on_error () {
  local rc=$?
  printf '[%s] Error: Monitoring terminated with exit code %s.\n' \
    "$(date --iso-8601=seconds)" "$rc" >&2
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap on_error ERR

# Не допускаем параллельный запуск: второй процесс завершится, если блокировка занята.
install -d -o root -g root -m 750 "$(dirname "$STATE_FILE")" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another instance of the monitoring script is already running; skipping this run." >&2
  exit 0
fi

# Проверяем наличие конфигурации SMTP и журналов до начала сбора данных.
if [[ ! -r "$MAIL_CONFIG" ]]; then
  echo "Unable to read $MAIL_CONFIG; run vagrant provision." >&2
  exit 1
fi
if [[ ! -d "$ACCESS_DIR" ]]; then
  echo "Nginx log directory $ACCESS_DIR not found." >&2
  exit 1
fi

# Определяем начало интервала: время успешной предыдущей отправки или последний час.
NOW_EPOCH=$(date +%s)
if [[ -s "$STATE_FILE" ]] && read -r LAST_EPOCH < "$STATE_FILE" && [[ "$LAST_EPOCH" =~ ^[0-9]+$ ]]; then
  FROM_EPOCH=$LAST_EPOCH
else
  FROM_EPOCH=$((NOW_EPOCH - 3600))
fi
if (( FROM_EPOCH > NOW_EPOCH )); then
  # Защищаемся от переноса системных часов назад.
  FROM_EPOCH=$((NOW_EPOCH - 3600))
fi
FROM_TEXT=$(date -d "@$FROM_EPOCH" '+%Y-%m-%d %H:%M:%S %Z')
TO_TEXT=$(date -d "@$NOW_EPOCH" '+%Y-%m-%d %H:%M:%S %Z')

TMP_DIR=$(mktemp -d /tmp/nginx-monitor.XXXXXX)
RAW_ACCESS="$TMP_DIR/access.tsv"
MATCHED_ACCESS="$TMP_DIR/matched.tsv"
RAW_ERRORS="$TMP_DIR/errors.txt"
MATCHED_ERRORS="$TMP_DIR/matched-errors.txt"
REPORT="$TMP_DIR/report.txt"
: > "$RAW_ACCESS"
: > "$MATCHED_ACCESS"
: > "$RAW_ERRORS"
: > "$MATCHED_ERRORS"

# Находим текущие и ротированные журналы; find позволяет автоматически учитывать новые файлы.
mapfile -t ACCESS_FILES < <(find "$ACCESS_DIR" -maxdepth 1 -type f \
  \( -name 'access.log' -o -name 'access.log.[0-9]*' -o -name 'access.log.*.gz' \) -print | sort)
mapfile -t ERROR_FILES < <(find "$ACCESS_DIR" -maxdepth 1 -type f \
  \( -name 'error.log' -o -name 'error.log.[0-9]*' -o -name 'error.log.*.gz' \) -print | sort)

# Читаем обычные и сжатые журналы. Сбой чтения отдельного ротированного файла не скрываем.
read_log() {
  local file="$1"
  if [[ "$file" == *.gz ]]; then
    gzip -cd -- "$file"
  else
    cat -- "$file"
  fi
}

# Извлекаем IP, время, URL и HTTP-код из стандартного combined access log.
for file in "${ACCESS_FILES[@]}"; do
  while IFS=$'\t' read -r ip stamp timezone url status; do
    [[ -n "${stamp:-}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$ip" "$stamp" "$timezone" "$url" "$status" >> "$RAW_ACCESS"
  done < <(
    read_log "$file" |
      gawk 'match($0, /^([^ ]+) [^ ]+ [^ ]+ \[([^]]+)\] "[^ ]* ([^ ]+) [^"]*" ([0-9]{3}|-) /, a) {
        split(a[2], t, / /);
        # Дата и смещение часового пояса сохраняются отдельными полями.
        print a[1] "\t" t[1] "\t" t[2] "\t" a[3] "\t" a[4]
      }'
  )
done

# Оставляем записи, попавшие в интервал (последний успешный запуск, текущий запуск).
while IFS=$'\t' read -r ip stamp timezone url status; do
  [[ -n "${stamp:-}" ]] || continue
  # Преобразуем дату Nginx в понятный GNU date формат.
  nginx_date="${stamp:0:2} ${stamp:3:3} ${stamp:7:4} ${stamp:12:8} ${timezone}"
  if line_epoch=$(date -d "$nginx_date" +%s 2>/dev/null); then
    if (( line_epoch > FROM_EPOCH && line_epoch <= NOW_EPOCH )); then
      printf '%s\t%s\t%s\n' "$ip" "$url" "$status" >> "$MATCHED_ACCESS"
    fi
  fi
done < "$RAW_ACCESS"

# Собираем строки error.log за тот же интервал; формат времени Nginx: [2026/10/27 13:00:00].
for file in "${ERROR_FILES[@]}"; do
  while IFS= read -r line; do
    [[ "$line" =~ ^\[([0-9]{4}/[0-9]{2}/[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2})\] ]] || continue
    error_time="${BASH_REMATCH[1]}"
    if error_epoch=$(date -d "$error_time" +%s 2>/dev/null); then
      if (( error_epoch > FROM_EPOCH && error_epoch <= NOW_EPOCH )); then
        printf '%s\n' "$line" >> "$MATCHED_ERRORS"
      fi
    fi
  done < <(read_log "$file")
done

# Формируем письмо с диапазоном времени, сводками и диагностическими ошибками.
{
  printf 'Nginx Monitoring Report\n'
  printf 'Time range: %s — %s\n' "$FROM_TEXT" "$TO_TEXT"
  printf 'Half-open interval: events strictly after the start time and up to and including the end time.\n\n'

  printf '1. Top IP addresses by request count (top %s)\n' "$TOP_COUNT"
  if [[ -s "$MATCHED_ACCESS" ]]; then
    cut -f1 "$MATCHED_ACCESS" | sort | uniq -c | sort -nr | head -n "$TOP_COUNT" |
      gawk '{ printf "  %-5s %s\n", $1, $2 }'
  else
    printf '  No requests found during the specified interval.\n'
  fi
  printf '\n2. Top URLs by request count (top %s)\n' "$TOP_COUNT"
  if [[ -s "$MATCHED_ACCESS" ]]; then
    cut -f2 "$MATCHED_ACCESS" | sort | uniq -c | sort -nr | head -n "$TOP_COUNT" |
      gawk '{ count=$1; $1=""; sub(/^ /,""); printf "  %-5s %s\n", count, $0 }'
  else
    printf '  No requests found during the specified interval.\n'
  fi

  printf '\n3. Nginx web server errors (error.log)\n'
  if [[ -s "$MATCHED_ERRORS" ]]; then
    # Limit the email size while retaining the most recent error entries.
    tail -n "$MAX_ERROR_LINES" "$MATCHED_ERRORS"
    total_errors=$(wc -l < "$MATCHED_ERRORS")
    if (( total_errors > MAX_ERROR_LINES )); then
      printf '\n  Warning: showing the last %s of %s lines.\n' "$MAX_ERROR_LINES" "$total_errors"
    fi
  else
    printf '  No error.log entries found during the specified interval.\n'
  fi

  printf '\n4. Response counts by HTTP status code\n'
  if [[ -s "$MATCHED_ACCESS" ]]; then
    cut -f3 "$MATCHED_ACCESS" | sort | uniq -c | sort -k2,2 |
      gawk '{ printf "  HTTP %-3s %s\n", $2, $1 }'
  else
    printf '  No data available.\n'
  fi

  printf '\nNote: Application errors recorded exclusively in a separate application log are not automatically included in this report.\n'
  printf 'If the application uses a separate log file, it must be explicitly added to the processing pipeline.\n'
} > "$REPORT"

# Создаём письмо с корректными заголовками и передаём его msmtp.
# Адреса и параметры SMTP задаются при provisioning в /etc/msmtprc и /etc/mail.rc.
MAIL_FROM=$(awk '$1=="from" {print $2; exit}' "$MAIL_CONFIG")
MAIL_TO=$(awk -F= '/^[[:space:]]*MAIL_TO=/ {gsub(/[ "\047]/,"",$2); print $2; exit}' /etc/nginx-monitoring/mail.conf 2>/dev/null || true)
# Файл /etc/nginx-monitoring/mail.conf создаётся provisioning ниже; если адрес не найден, используем адрес отправителя только как запасной вариант для диагностики конфигурации.
if [[ -z "$MAIL_TO" ]]; then
  echo "MAIL_TO not found in /etc/nginx-monitoring/mail.conf; run vagrant provision." >&2
  exit 1
fi

{
  printf 'From: %s\n' "$MAIL_FROM"
  printf 'To: %s\n' "$MAIL_TO"
  printf 'Subject: [Nginx] Report %s — %s\n' "$FROM_TEXT" "$TO_TEXT"
  printf 'MIME-Version: 1.0\n'
  printf 'Content-Type: text/plain; charset=UTF-8\n'
  printf 'Content-Transfer-Encoding: 8bit\n'
  printf '\n'
  cat "$REPORT"
} | msmtp --account=default -t

# Обновляем контрольную точку только после успешной передачи письма SMTP-клиенту.
# При сбое отправки следующий запуск повторно включит этот временной диапазон.
printf '%s\n' "$NOW_EPOCH" > "$STATE_FILE.tmp"
chmod 600 "$STATE_FILE.tmp"
mv -f "$STATE_FILE.tmp" "$STATE_FILE"

echo "Report sent for the period: $FROM_TEXT — $TO_TEXT"
