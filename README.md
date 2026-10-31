# simple-nginx-xray-warpout

Установщик VPN на Xray для Ubuntu 22.04: **VLESS + REALITY (TCP, Vision)**, маскировка под собственный сайт (self-steal), сайт-заглушка на nginx, опциональный выход через **Cloudflare WARP**. Вход — по IPv4 и IPv6, клиенту выдаётся ссылка с IPv6-литералом.

## Как это устроено

```
клиент :443 ──▶ Xray REALITY (VLESS/TCP/Vision)
                  ├─ ключ верный  ──▶ direct | WARP (WireGuard)
                  └─ ключ неверный ─▶ 127.0.0.1:8443 (nginx, TLS) ─▶ заглушка
клиент :80  ──▶ nginx ──▶ ACME + 301 на https
```

| Порт | Кто | Зачем |
|---|---|---|
| 443/tcp | Xray | REALITY, единственный вход VPN |
| 80/tcp | nginx | ACME, редирект, заглушка по HTTP |
| 127.0.0.1:8443 | nginx | HTTPS-заглушка для не-REALITY трафика |
| 2408/udp (исходящий) | Xray | endpoint Cloudflare WARP, если включён |

**Почему 443 не у nginx.** VLESS едет внутри TLS-сессии Reality; nginx не может её расшифровать и «увидеть протокол». Решение принимает Xray: валидный клиент уходит в туннель, всё остальное Xray сам проксирует на `target` — локальный nginx с валидным сертификатом. Для сканера и браузера это обычный сайт.

## Требования

- Ubuntu 22.04, root, systemd;
- домен (лучше поддомен), A/AAAA которого указывают на этот сервер;
- домен в режиме **DNS only** (серая туча), иначе Reality не работает;
- свободные 80/tcp и 443/tcp;
- публичный IPv6 на сервере (для адреса в ссылке);
- исходящий IPv4 (для установки пакетов и WARP).

## Быстрый старт

Интерактивно — скрипт сам спросит домен, email, транспорт, WARP и блокировку RU (вопросы идут через `/dev/tty`, поэтому работают и при запуске через пайп):

```bash
wget -qO- https://raw.githubusercontent.com/paratrupper/simple-nginx-xray-warpout/refs/heads/main/install.sh | sudo bash
```

Или с флагами, без вопросов:

```bash
sudo bash install.sh --domain vpn.example.com --email you@example.com
```

Без WARP:

```bash
sudo bash install.sh --domain vpn.example.com --email you@example.com --warp off
```

Скрипт идемпотентен: повторный запуск обновляет конфиги, сохраняя UUID, ключи Reality и сертификат. `--regen-keys` выпускает новые ключи, `--force` переустанавливает поверх.

## Что делает установщик

1. Ставит nginx, certbot, jq, ufw, Xray-core.
2. Включает BBR/fq и базовые sysctl.
3. Настраивает ufw: SSH-порт, 80, 443, IPv6.
4. Создаёт сайт-заглушку и vhost :80 с ACME-челленджем.
5. Выпускает сертификат Let's Encrypt (HTTP-01). Если не получилось — self-signed и предупреждение.
6. Поднимает vhost `127.0.0.1:8443` с TLS 1.2/1.3.
7. Ставит Xray, генерирует UUID, x25519-ключи, shortId.
8. Регистрирует WARP (wgcf) и добавляет WireGuard-outbound, если `--warp all`.
9. Пишет конфиг Xray: REALITY → nginx, маршрутизация, блокировки.
10. Запускает, проверяет порты и отдачу заглушки через 443, печатает ссылки.

## DNS и сертификат

Сертификат привязан к имени, а не к IP. Если у домена есть A на IPv4 сервера, HTTP-01 пройдёт по IPv4, и этот же сертификат будет отдаваться клиентам, пришедшим по IPv6. Отдельный «сертификат под IPv6» не нужен.

Пока AAAA не разошёлся:

- ссылка использует IPv6-литерал, SNI — домен; VPN работает;
- `--links` покажет вариант с доменом, как только AAAA начнёт резолвиться;
- для сканеров домен доступен по A, и заглушка с валидным сертификатом видна — маскировка работает;
- но связка «SNI домена без AAAA + подключение на IPv6-литерал» выглядит нетипично для пассивного наблюдателя. Это временный компромисс; после распространения AAAA лучше ходить по домену.

Продление сертификата идёт по HTTP-01, поэтому A (и позже AAAA) должны и дальше указывать на сервер. Если домен за Cloudflare в режиме прокси (оранжевая туча), HTTP-01 не пройдёт — нужен `--cert-method dns --cf-token` или серая туча.

## Флаги

| Флаг | Значение |
|---|---|
| `--domain NAME` | домен для SNI / serverNames / сертификата |
| `--email ADDR` | email Let's Encrypt (по умолчанию `admin@<domain>`) |
| `--endpoint HOST` | адрес в ссылке; по умолчанию первый глобальный IPv6 |
| `--warp all\|off` | весь трафик через WARP (по умолчанию `all`) |
| `--block-ru` / `--no-block-ru` | блокировать `.ru`, `.рф`, `.su`, `geoip:ru` (по умолчанию включено) |
| `--cert-method http\|dns\|none` | способ получения сертификата |
| `--cf-token TOKEN` | токен Cloudflare для DNS-01 |
| `--ssh-port PORT` | SSH-порт, который останется открыт (по умолчанию 22) |
| `--qr` | QR-код ссылки в терминале |
| `--mux` | отключить Vision и разрешить Mux.Cool на клиенте |
| `--transport tcp\|grpc\|xhttp` | `tcp` — Vision (по умолчанию), `grpc`/`xhttp` — мультиплексирование |
| `--service-name NAME` | имя gRPC-сервиса (генерируется автоматически) |
| `--xhttp-path PATH` | путь XHTTP (генерируется автоматически) |
| `--regen-keys` | новые UUID, ключи Reality, shortId |
| `--force` | переустановка поверх |
| `--non-interactive` | без вопросов (нужны `--domain`, `--email`) |

## Клиентская ссылка

```text
vless://UUID@[IPv6]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=DOMAIN&fp=firefox&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp#DOMAIN
```

Импортируется в v2rayN, Hiddify, sing-box, NekoBox и т.п. Когда AAAA разойдётся, `--links` дополнительно покажет вариант с доменом вместо литерала.

## Пользователи

```bash
sudo bash install.sh --add-user phone
```

Команда добавляет UUID в конфиг, перезапускает Xray и печатает ссылку. `--links` показывает ссылки всех текущих пользователей (по сохранённому состоянию). Имя пользователя (email) должно быть уникальным: повторное добавление теперь даёт понятную ошибку, а не «config test failed».

## Управление

После установки появляется `/usr/local/bin/xray-manage` — для мелких операций без переустановки:

```bash
xray-manage status
xray-manage links
xray-manage user list
xray-manage user add phone
xray-manage user del phone
xray-manage warp on
xray-manage warp off
xray-manage restart
```

`warp on` использует сохранённый wgcf-профиль и возвращает в конфиг WireGuard-outbound с балансером; `warp off` убирает его и переводит всё на direct. `user del` принимает имя или UUID.

## Диагностика

```bash
sudo bash install.sh --status
sudo journalctl -u xray -n 50 --no-pager
sudo nginx -t
sudo xray run -test -c /usr/local/etc/xray/config.json
```

Проверки с клиента:

```bash
curl -6 https://vpn.example.com                 # заглушка
curl https://www.cloudflare.com/cdn-cgi/trace   # warp=on, если WARP работает
curl ifconfig.me                                # выходной IP
```

## Много одновременных соединений

VLESS/TCP не мультиплексирует: каждый проксируемый поток (TCP-соединение сайта или UDP-сессия) идёт отдельным TCP-соединением до сервера. Браузер с десятком вкладок легко даёт сотни соединений, и провайдерский DPI может на это реагировать.

Xray умеет Mux.Cool — несколько потоков в одном TCP. Но он несовместим с Vision, поэтому режим переключает сервер на обычный VLESS+REALITY без `flow`:

```bash
bash install.sh --mux            # при установке
bash install.sh --enable-mux     # на уже установленном
bash install.sh --disable-mux    # вернуть Vision
```

После переключения нужны новые ссылки (в них не будет `flow=...`). В клиенте включите Mux: `concurrency` 8–16, `xudpConcurrency` 16–32, `xudpProxyUDP443 = reject`.

Ограничения: Mux.Cool понимают только Xray-клиенты (v2rayN, v2rayNG, NekoBox с Xray). sing-box/Hiddify используют smux и с Xray Mux.Cool не совместимы — они продолжат работать без мультиплексирования. Без Vision теряется splice и часть маскировки TLS-in-TLS; если проблема не в количестве соединений, лучше оставить Vision.

### sing-box: gRPC вместо XHTTP

Stock sing-box не поддерживает XHTTP: в 1.13/1.14 доступны HTTP, WebSocket, QUIC, gRPC и HTTPUpgrade; XHTTP есть только в форках вроде sing-box-extended. Зато Xray REALITY поддерживает RAW, XHTTP и gRPC, а gRPC есть в обоих ядрах.

gRPC работает поверх HTTP/2: все проксируемые потоки идут через одно TCP-соединение, как раз то, что нужно против «шторма» соединений.

```bash
bash install.sh --transport grpc
```

Скрипт сгенерирует случайный `serviceName`, переключит сервер, сохранит состояние и напечатает ссылку вида `type=grpc&serviceName=...` (без `flow`) плюс готовый sing-box outbound. Обратно:

```bash
bash install.sh --transport tcp
```

Ограничения: gRPC медленнее RAW/Vision на больших загрузках, а Vision с ним недоступен. Xray 26.10 уже помечает gRPC как deprecated и советует XHTTP stream-up, но для stock sing-box альтернативы нет.

### XHTTP

`--transport xhttp` — HTTP-мультиплексирование поверх Reality: все потоки идут через одно TCP-соединение, path и host генерируются автоматически.

```bash
bash install.sh --transport xhttp
```

Важно: stock sing-box XHTTP не поддерживает (только HTTP, WS, QUIC, gRPC, HTTPUpgrade). Режим рассчитан на Xray-клиенты (v2rayN, v2rayNG, NekoBox с Xray core) или sing-box-extended. Для обычного sing-box используйте gRPC.

Ссылка получает `type=xhttp&path=...&host=...&mode=stream-up`, без `flow`. Обратно — `--transport tcp`.

## Ограничения и риски

- Reality/TCP в 2026 периодически блокируется на уровне ТСПУ. Self-steal снижает риск, но не устраняет его.
- WARP в РФ часто недоступен. Если регистрация не удалась, скрипт продолжит установку с `direct` и предупредит; healthcheck в Xray откатывается на direct автоматически.
- Если сертификат не выпустился, сайт работает с self-signed: VPN функционирует, но браузер покажет предупреждение. После того как DNS разойдётся, запустите установщик ещё раз — он повторит выпуск сертификата.
- Один сервер, без панели и статистики. Добавление пользователей — через `--add-user`.
- Скрипт не открывает 443/udp: транспорт TCP.

## Удаление

```bash
sudo bash install.sh --uninstall
```

Удаляет Xray, свой vhost nginx, сайт-заглушку и состояние. Сертификаты в `/etc/letsencrypt` не трогает.

## Файлы

| Путь | Что |
|---|---|
| `/usr/local/etc/xray/config.json` | конфиг Xray |
| `/etc/xray-installer/state.json` | состояние (домен, ключи, endpoint) |
| `/etc/nginx/sites-available/<domain>.conf` | vhost nginx |
| `/var/www/<domain>/` | сайт-заглушка |
| `/var/log/xray-installer.log` | лог установки |
| `/var/backups/xray-installer/` | бэкапы изменённых файлов |
