#!/usr/bin/env bash

set -e

# Получаем текущего пользователя
USER=$(whoami)
DEST="/home/lampac"

echo "Installing Lampac for user: $USER in $DEST"

# Проверка: не запускать от root напрямую
if [ "$USER" = "root" ]; then
    echo "Не запускайте этот скрипт от root. Запустите от обычного пользователя с sudo-доступом."
    exit 1
fi

# Проверка необходимых утилит
REQUIRED_CMDS=("curl" "unzip" "sudo" "crontab")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Ошибка: необходимая утилита '$cmd' не найдена. Установите её и повторите запуск."
        exit 1
    fi
done

# Проверка, что пользователь входит в группу sudo
if ! groups "$USER" | grep -qw sudo; then
    echo "Пользователь $USER не входит в группу sudo."
    echo "Добавьте его командой:"
    echo "  sudo usermod -aG sudo $USER"
    exit 1
fi

# Дружелюбное сообщение перед вводом пароля sudo
echo "Для выполнения установки потребуется ввод пароля sudo."
echo "Если введёте пароль неверно — попросят ввести ещё раз."

# Запрос пароля sudo в цикле до успешного ввода
while true; do
    if sudo -v; then
        break
    else
        echo "Неверный пароль, попробуйте ещё раз."
    fi
done

# Установка зависимостей без остановки при ошибке
set +e
sudo apt-get update
sudo apt-get install -y unzip curl libnss3-dev libgdk-pixbuf2.0-dev libgtk-3-dev libxss-dev libasound2 xvfb coreutils
INSTALL_RESULT=$?
set -e

if [ $INSTALL_RESULT -ne 0 ]; then
    echo "Внимание: при установке пакетов произошла ошибка, но скрипт продолжит выполнение."
fi

# Установка .NET
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

if ! curl -L -k -o "$TMPDIR/dotnet-install.sh" https://dot.net/v1/dotnet-install.sh; then
   echo "Не удалось загрузить dotnet-install.sh. Выход."
   exit 1
fi

chmod +x "$TMPDIR/dotnet-install.sh"
sudo "$TMPDIR/dotnet-install.sh" --channel 6.0 --runtime aspnetcore --install-dir /usr/share/dotnet
sudo ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet

# Создание директории /home/lampac и назначение владельца
sudo mkdir -p "$DEST"
sudo chown -R "$USER:$USER" "$DEST"
cd "$DEST"

# Скачивание и распаковка Lampac
if ! curl -L -k -o publish.zip https://github.com/immisterio/Lampac/releases/latest/download/publish.zip; then
   echo "Не удалось скачать publish.zip. Выход."
   exit 1
fi

unzip -o publish.zip
rm -f publish.zip

# Автообновление
curl -k -s https://api.github.com/repos/immisterio/Lampac/releases/latest | grep tag_name | sed s/[^0-9]//g > vers.txt
curl -k -s https://raw.githubusercontent.com/immisterio/lampac/main/update.sh > update.sh
chmod +x update.sh

# Cron на обновление с проверкой crontab
CRON_JOB="0 3 * * 6 /bin/bash $DEST/update.sh >> $DEST/update.log 2>&1"

if crontab -l >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -vF "/bin/bash $DEST/update.sh"; echo "$CRON_JOB") | crontab -
else
    echo "Внимание: не удалось получить список заданий crontab, пропускается установка задания на обновление."
fi

# Systemd сервис
sudo tee /etc/systemd/system/lampac.service > /dev/null <<EOF
[Unit]
Description=Lampac
Wants=network.target
After=network.target

[Service]
User=$USER
WorkingDirectory=$DEST
ExecStart=/usr/bin/dotnet $DEST/Lampac.dll
Restart=always
LimitNOFILE=32000

[Install]
WantedBy=multi-user.target
EOF

# Конфигурация
if [ ! -f "$DEST/init.conf" ]; then
  random_port=$(shuf -i 9000-12999 -n 1)
  echo "\"listenport\": $random_port" | tee init.conf > /dev/null
fi

# Права на конфиг
sudo chown "$USER:$USER" "$DEST/init.conf"

# Создание дополнительных папок, если отсутствуют
mkdir -p "$DEST/plugins"
mkdir -p "$DEST/module"

# Копирование дополнительных файлов, если они есть рядом со скриптом
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

[[ -f "$SCRIPT_DIR/init.conf" ]] && cp -f "$SCRIPT_DIR/init.conf" "$DEST/"
[[ -f "$SCRIPT_DIR/lampainit.my.js" ]] && cp -f "$SCRIPT_DIR/lampainit.my.js" "$DEST/plugins/"
[[ -f "$SCRIPT_DIR/lampainit-invc.my.js" ]] && cp -f "$SCRIPT_DIR/lampainit-invc.my.js" "$DEST/plugins/"
[[ -f "$SCRIPT_DIR/manifest.json" ]] && cp -f "$SCRIPT_DIR/manifest.json" "$DEST/module/"

# Активация systemd
sudo systemctl daemon-reload
sudo systemctl enable lampac
sudo systemctl restart lampac

# Обновление версии
echo -n "1" | tee vers-minor.txt > /dev/null
/bin/bash update.sh

# iptables reset script
cat <<EOF > iptables-drop.sh
#!/bin/sh
echo "Stopping firewall and allowing everyone..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
EOF
chmod +x iptables-drop.sh

# sudoers разрешение для управления lampac
SUDOERS_LINE="$USER ALL=NOPASSWD: /bin/systemctl stop lampac, /bin/systemctl start lampac, /bin/systemctl restart lampac"

if ! sudo grep -qF "$SUDOERS_LINE" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    echo "$SUDOERS_LINE" | sudo tee /etc/sudoers.d/lampac > /dev/null
    sudo chmod 440 /etc/sudoers.d/lampac
    echo "Добавлено правило sudoers для $USER"
fi

echo ""
echo "################################################################"
echo "Установка завершена для пользователя $USER"
echo ""
echo "URL: http://IP:$(grep listenport "$DEST/init.conf" | grep -o '[0-9]\+')"
echo ""
echo "Измените конфигурацию при необходимости: $DEST/init.conf"
echo "Перезапуск сервиса: sudo systemctl restart lampac"
echo "Сброс iptables: sudo bash $DEST/iptables-drop.sh"
echo ""
