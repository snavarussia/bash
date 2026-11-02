# -*- mode: ruby -*-
# frozen_string_literal: true
# Файл описывает виртуальную машину Ubuntu и автоматически настраивает мониторинг Nginx.

Vagrant.configure("2") do |config|
  # Используем Ubuntu 22.04 LTS.
  config.vm.box = "ubuntu/jammy64"

  # Задаём имя виртуальной машины и её сетевое имя.
  config.vm.define "bash" do |vm|
    vm.vm.hostname = "bash"

    # Пробрасываем HTTP-порт гостевой системы на порт 8080 хоста.
    vm.vm.network "forwarded_port",
      guest: 80,
      host: 8080,
      # Разрешаем Vagrant скорректировать порт хоста, если он недоступен, например, потому что занят другим приложением.
      auto_correct: true

    # Выделяем виртуальной машине 2 GiB памяти и 1 виртуальный процессор.
    vm.vm.provider "virtualbox" do |vb|
      vb.name = "bash"
      vb.memory = 2048
      vb.cpus = 1
    end
  end

  # Общая папка позволяет передавать скрипт и настройки в виртуальную машину.
  config.vm.synced_folder ".", "/vagrant"

  # Provisioning выполняется автоматически при первом запуске и при vagrant provision.
  config.vm.provision "shell", privileged: true, inline: <<-'SHELL'
    # Завершаем настройку при первой ошибке и считаем ошибки конвейеров критичными.
    set -euo pipefail

    # Устанавливаем веб-сервер, средства анализа журналов и SMTP-клиент.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
      nginx curl gawk sed findutils util-linux bsd-mailx \
      msmtp msmtp-mta ca-certificates gzip apparmor-utils

    # Проверяем наличие файла настроек почты.
    if [ ! -f /vagrant/config/mail.conf ]; then
      echo "Error: config/mail.conf not found. Copy config/mail.conf.example to config/mail.conf and configure the SMTP settings."
      exit 1
    fi

    # Загружаем параметры SMTP из файла настроек почты.
    # Файл должен содержать только присваивания переменных в формате shell.
    # shellcheck disable=SC1091
    . /vagrant/config/mail.conf

    # Проверяем обязательные параметры.
    : "${SMTP_HOST:?Set SMTP_HOST in config/mail.conf}"
    : "${SMTP_PORT:?Set SMTP_PORT in config/mail.conf}"
    : "${SMTP_USER:?Set SMTP_USER in config/mail.conf}"
    : "${SMTP_PASSWORD:?Set SMTP_PASSWORD in config/mail.conf}"
    : "${MAIL_FROM:?Set MAIL_FROM in config/mail.conf}"
    : "${MAIL_TO:?Set MAIL_TO in config/mail.conf}"

    # Создаём системные каталоги скрипта, состояния и временных данных.
    install -d -o root -g root -m 755 /opt/nginx-monitoring
    install -d -o root -g root -m 750 /var/lib/nginx-monitoring
    install -d -o root -g root -m 750 /run/nginx-monitoring

    # Формируем конфигурацию msmtp с закрытыми правами доступа.
    # Пароль не выводится в журнал provisioning.
    umask 077
    cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_starttls   off
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account default
host ${SMTP_HOST}
port ${SMTP_PORT}
user ${SMTP_USER}
password ${SMTP_PASSWORD}
from ${MAIL_FROM}
EOF
    chown root:root /etc/msmtprc
    chmod 600 /etc/msmtprc

    # Создаём файл журнала msmtp.
    touch /var/log/msmtp.log
    chown root:root /var/log/msmtp.log
    chmod 600 /var/log/msmtp.log

    # Разрешаем msmtp записывать журнал через AppArmor.
    printf '%s\n' '/var/log/msmtp.log rwk,' > /etc/apparmor.d/local/usr.bin.msmtp

    chown root:root /etc/apparmor.d/local/usr.bin.msmtp
    chmod 644 /etc/apparmor.d/local/usr.bin.msmtp

    aa-enforce /etc/apparmor.d/usr.bin.msmtp
    apparmor_parser -r /etc/apparmor.d/usr.bin.msmtp

    # Сохраняем адрес получателя отдельно, чтобы скрипт мог формировать заголовок письма.
    install -d -o root -g root -m 750 /etc/nginx-monitoring
    printf 'MAIL_TO=%s\n' "$MAIL_TO" > /etc/nginx-monitoring/mail.conf
    chown root:root /etc/nginx-monitoring/mail.conf
    chmod 600 /etc/nginx-monitoring/mail.conf

    # Устанавливаем скрипт мониторинга и назначаем владельцем root.
    install -o root -g root -m 750 /vagrant/scripts/nginx-monitor.sh /opt/nginx-monitoring/nginx-monitor.sh

    # Создаём cron-задание: запуск в начале каждого часа.
    cat > /etc/cron.d/nginx-monitoring <<'CRON'
# Ежечасный отчёт о запросах и ошибках Nginx.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
5 * * * * root /opt/nginx-monitoring/nginx-monitor.sh
CRON
    chmod 644 /etc/cron.d/nginx-monitoring

    # Включаем Nginx и cron и проверяем синтаксис конфигурации веб-сервера.
    systemctl enable nginx
    systemctl restart nginx
    systemctl enable cron
    systemctl restart cron
    nginx -t

    # Сообщаем об успешном завершении автоматической настройки.
    echo "Configuration completed. Monitoring runs hourly at 5 minutes past the hour."
  SHELL
end
