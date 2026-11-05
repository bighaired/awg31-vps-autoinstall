# AmneziaWG 3.1 VPS Auto Installer

Автоматизированная установка **AmneziaWG 3.1 + amneziawg-web + nginx + Let's Encrypt** на чистую Ubuntu 24.04 LTS.

> **Статус:** синтаксис проверен, полноценный запуск на реальном VPS пока не проверен. Используйте только на новом сервере. Прежде чем запускать скачанный из интернета скрипт от root, просмотрите его содержимое.

## Требования

- Чистая Ubuntu 24.04 LTS, root по SSH, публичный IPv4.
- Доступ извне: SSH `22/TCP`, HTTP `80/TCP`, HTTPS `443/TCP`, VPN `585/UDP` (либо выбранный UDP-порт). Внешний firewall хостера настраивается отдельно.
- Рекомендуется не менее 2 GiB ОЗУ и достаточно свободного места для компиляции Web-панели.
- Доступ сервера к GitHub, Ubuntu mirrors, Snap Store и Let's Encrypt.

## Установка

Подключитесь к VPS по SSH. Замените `YOUR_GITHUB_USERNAME` на имя своего аккаунта GitHub и убедитесь, что в репозитории на ветке `main` находится проверенный `install.sh`:

```bash
curl -fL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/awg31-vps-autoinstall/main/install.sh -o /root/awg31-install.sh
less /root/awg31-install.sh
bash /root/awg31-install.sh
```

Программа запросит IPv4 (можно определить автоматически), UDP-порт, email, логин и пароль панели. После первой фазы сервер перезагрузится; установка продолжится через systemd автоматически.

## Проверка

После перезагрузки:

```bash
systemctl status awg31-autosetup --no-pager
journalctl -u awg31-autosetup -n 100 --no-pager
systemctl is-active awg-quick@awg0 amneziawg-web nginx
awg show
```

Панель должна открываться по адресу `https://PUBLIC_IP/`. Настоящую доступность VPN проверьте клиентским handshake извне, отдельно от VPS. Наличие слушающего UDP-порта ещё не доказывает, что трафик доходит из нужной сети.

## Что делает установщик

1. Проверяет ОС и наличие уже установленного AmneziaWG.
2. Устанавливает зависимости, обновляет ядро и headers.
3. Создаёт системный сервис для продолжения после перезагрузки.
4. Устанавливает AWG, включает режим 3.1, согласует `S1`–`S4`.
5. Разворачивает Web-панель на `127.0.0.1:8080` с Argon2id-хешем пароля.
6. Настраивает nginx на `80/TCP` и `443/TCP` с Let's Encrypt IP-сертификатом.
7. Добавляет hook для reload nginx после обновления сертификата и запускает базовые локальные проверки.

## Важные ограничения

- Установщик не управляет firewall панели хостера и не проверяет фактическую доступность UDP из России.
- Пароль админа сохраняется только в виде хеша; не публикуйте локальные `env.conf`, приватные ключи, клиентские `.conf`, системные логи и файлы из `/etc/amnezia`.
- Повторный запуск после прерванной установки требует диагностики состояния, а не слепого удаления файлов конфигурации.
- Скрипт выполняет скачиваемый код сторонних разработчиков с правами root; фиксируйте проверенную версию upstream перед производственным использованием.

## Источники

- [Wiresock AWG Server Tools](https://github.com/wiresock/awg-server-tools)
- [amneziawg-web INSTALL](https://github.com/wiresock/awg-server-tools/blob/main/amneziawg-web/docs/INSTALL.md)
- [Let's Encrypt](https://letsencrypt.org/)
