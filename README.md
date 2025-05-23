# 🛠 Lampac Installer

Скрипт для автоматической установки и настройки [Lampac](https://github.com/immisterio/Lampac) от имени обычного пользователя на Linux-сервере с поддержкой обновлений, systemd, пользовательских конфигураций и автообновления.

## 📦 Возможности

- Проверка прав доступа и sudo
- Установка необходимых зависимостей
- Загрузка последней версии Lampac с GitHub
- Установка .NET Runtime
- Генерация случайного порта (если не задан)
- Настройка systemd-сервиса
- Копирование дополнительных файлов, если они лежат рядом:
  - `init.conf` → `/home/lampac/`
  - `lampainit.my.js`, `lampainit-invc.my.js` → `/home/lampac/plugins/`
  - `manifest.json` → `/home/lampac/module/`
- Создание cron-задачи для автообновления
- Скрипт сброса iptables
- Настройка прав sudo без пароля для управления сервисом

## 🚀 Установка

Выполните команду, чтобы скачать и запустить скрипт установки напрямую из репозитория:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rsnorlax/lampac_install/main/install_lampac.sh)"
