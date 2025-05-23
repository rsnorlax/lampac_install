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
echo "Если введёте пароль неверно — дадим три попытки."

# Запрос пароля sudo с ограничением на 3 попытки
MAX_ATTEMPTS=3
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if sudo -v; then
        break
    else
        echo "Неверный пароль, попытка $attempt из $MAX_ATTEMPTS."
        if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
            echo "Превышено количество попыток. Прерывание установки."
            exit 1
        fi
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
if [ ! -d "$DEST" ]; then
    echo "Создаём директорию $DEST"
    sudo mkdir -p "$DEST"
    sudo chown "$USER:$USER" "$DEST"
else
    echo "Директория $DEST уже существует"
    sudo chown "$USER:$USER" "$DEST"
fi

cd "$DEST"

# Скачивание и распаковка Lampac
if ! curl -L -k -o publish.zip https://github.com/immisterio/Lampac/releases/latest/download/publish.zip; then
   echo "Не удалось скачать publish.zip. Выход."
   exit 1
fi

unzip -o publish.zip
rm -f publish.zip

if [ ! -f "$DEST/Lampac.dll" ]; then
    echo "Не найден Lampac.dll после распаковки. Проверьте содержимое publish.zip."
    exit 1
fi

# Автообновление
curl -k -s https://api.github.com/repos/immisterio/Lampac/releases/latest | grep tag_name | sed s/[^0-9]//g > vers.txt
curl -k -s https://raw.githubusercontent.com/immisterio/lampac/main/update.sh > update.sh
chmod +x update.sh

# Cron на обновление с проверкой crontab
CRON_JOB="0 3 * * 6 /bin/bash $DEST/update.sh >> $DEST/update.log 2>&1"

if crontab -l >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -vF "/bin/bash $DEST/update.sh"; echo "$CRON_JOB") | crontab -
else
    echo "$CRON_JOB" | crontab -
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

# sudoers разрешение для управления lampac
SUDOERS_LINE="$USER ALL=NOPASSWD: /bin/systemctl stop lampac, /bin/systemctl start lampac, /bin/systemctl restart lampac"

if ! sudo grep -qF "$SUDOERS_LINE" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    echo "$SUDOERS_LINE" | sudo tee /etc/sudoers.d/lampac > /dev/null
    sudo chmod 440 /etc/sudoers.d/lampac
    echo "Добавлено правило sudoers для $USER"
fi

# Активация systemd (после добавления sudoers)
sudo systemctl daemon-reload
sudo systemctl enable lampac
sudo systemctl restart lampac

# Конфигурация
if [ ! -f "$DEST/init.conf" ]; then
  random_port=$(shuf -i 9000-12999 -n 1)
  echo "{ \"listenport\": $random_port }" > init.conf
fi

# Права на конфиг
sudo chown "$USER:$USER" "$DEST/init.conf"

# Создание дополнительных папок, если отсутствуют
mkdir -p "$DEST/plugins"
mkdir -p "$DEST/module"

# Копирование дополнительных файлов, если они есть рядом со скриптом
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ -f "$SCRIPT_DIR/init.conf" && "$SCRIPT_DIR/init.conf" != "$DEST/init.conf" ]]; then
    cp -f "$SCRIPT_DIR/init.conf" "$DEST/"
fi

if [[ -f "$SCRIPT_DIR/lampainit.my.js" && "$SCRIPT_DIR/lampainit.my.js" != "$DEST/plugins/lampainit.my.js" ]]; then
    cp -f "$SCRIPT_DIR/lampainit.my.js" "$DEST/plugins/"
fi

if [[ -f "$SCRIPT_DIR/lampainit-invc.my.js" && "$SCRIPT_DIR/lampainit-invc.my.js" != "$DEST/plugins/lampainit-invc.my.js" ]]; then
    cp -f "$SCRIPT_DIR/lampainit-invc.my.js" "$DEST/plugins/"
fi

if [[ -f "$SCRIPT_DIR/manifest.json" && "$SCRIPT_DIR/manifest.json" != "$DEST/module/manifest.json" ]]; then
    cp -f "$SCRIPT_DIR/manifest.json" "$DEST/module/"
fi

# Обновление версии
echo -n "1" | tee vers-minor.txt > /dev/null
/bin/bash update.sh

# iptables reset script
cat <<EOF > iptables-drop.sh
#!/bin/sh
echo "Stopping firewall and allowing everyone..."
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
EOF
chmod +x iptables-drop.sh

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
