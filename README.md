# keenetic-vpn-mihomo

Самоуправляемый VPN-клиент на базе [mihomo](https://github.com/MetaCubeX/mihomo)
(clash.meta) для роутера **Keenetic NC-2312** (aarch64, Entware). Заменяет
проприетарный `spd`/`spider`, привязанный к провайдеру: принимает обычные
happ-style **VLESS-подписки**, сервер и подписку можно менять в любой момент.

## Что умеет

- **Per-device VPN**: в VPN ходят только устройства из политики доступа
  Keenetic **EJX** — управление устройствами через штатную админку, как раньше.
- **Подписки**: `vpn sub "<url>"` — вставил URL, mihomo сам тянет и обновляет
  список серверов.
- **Выбор сервера**: вручную (`vpn select`), автоматически по health-check
  (`vpn auto`) или мышкой в веб-интерфейсе.
- **Автофоллбек**: если mihomo упал — устройства автоматически идут напрямую
  (интернет не пропадает), monit тем временем перезапускает процесс.
- **Автозапуск**: init-скрипт при загрузке + monit-супервизия + NDM-хук при
  переподключении WAN.
- **Веб-интерфейс**: metacubexd на `http://192.168.1.1:9090/ui` — статус,
  замеры задержек, переключение серверов, живой трафик.

## Как это работает

1. Keenetic сам метит соединения устройств из политики EJX connmark'ом
   `0xffffaaa` — эту штатную механику мы не трогаем.
2. mihomo поднимает TUN `mihomo0`. Скрипт `mihomo-route` добавляет
   `ip rule fwmark 0xffffaaa lookup 1000 priority 99` (раньше правила
   Keenetic 100), а в таблице 1000 — `default dev mihomo0`.
3. Помеченный трафик попадает в TUN → mihomo заворачивает его в VLESS и
   отправляет через WAN. Остальные устройства ходят напрямую.
4. **Фоллбек**: умер mihomo → исчез TUN → таблица 1000 пуста → правило 99 не
   срабатывает и трафик проваливается в обычную маршрутизацию Keenetic.
   Чинить руками ничего не нужно.

## Структура репозитория

Дерево `router/` зеркалит `/opt` на роутере — файл лежит в репо там же, куда
он попадёт при деплое:

| В репо (`router/…`) | На роутере (`/opt/…`) | Что это |
|---|---|---|
| `etc/mihomo/config.yaml` | `etc/mihomo/config.yaml` | конфиг mihomo: подписка, группы, TUN, DNS |
| `bin/vpn` | `bin/vpn` | CLI управления (start/status/sub/select/…) |
| `bin/mihomo-route` | `bin/mihomo-route` | policy-роутинг add/del/status |
| `etc/init.d/S06mihomo` | `etc/init.d/S06mihomo` | init/автозапуск |
| `etc/monit.d/mihomo.conf` | `etc/monit.d/mihomo.conf` | monit-супервизия |
| `etc/ndm/wan.d/10-mihomo.sh` | `etc/ndm/wan.d/10-mihomo.sh` | восстановление роутинга при WAN up |

Бинарник mihomo (`/opt/sbin/mihomo`) и файлы веб-UI (`/opt/share/mihomo/ui`)
в репо не хранятся — install-скрипт скачивает их на роутер с GitHub-релизов.

`scripts/` — деплой с рабочей машины по SSH (по умолчанию
`root@192.168.1.1:222`, переопределяется `ROUTER=… PORT=…`):

- `01-install.sh` — **неразрушающая** установка: скачивает бинарник и UI,
  раскладывает `router/` в `/opt`, валидирует конфиг (`mihomo -t`). Ничего не
  запускает и не переключает. Повторный запуск не затирает живой
  `config.yaml` с вашей подпиской (новая версия ляжет рядом как
  `config.yaml.new`).
- `02-cutover.sh` — переключение: обратимо отключает spider (сохраняя его
  файлы), запускает mihomo, отдаёт его под monit.
- `99-rollback.sh` — откат: останавливает mihomo, возвращает spider.

## Установка

```sh
sh scripts/01-install.sh
sh scripts/02-cutover.sh
ssh root@192.168.1.1 -p 222 'vpn sub "https://your-subscription-url"'
ssh root@192.168.1.1 -p 222 'vpn select "🇳🇱 Server-1"'   # или: vpn auto
```

> monit-супервизия требует строки `include /opt/etc/monit.d/*.conf` в
> `/opt/etc/monitrc` (на этом роутере её изначально не было).

## Повседневное использование

```sh
vpn status                 # процесс, TUN, роутинг, текущий сервер, подписка, UI
vpn sub "https://..."      # сменить подписку
vpn servers                # список серверов
vpn select "<name>"        # переключить сервер вручную
vpn auto                   # первый живой сервер по health-check
vpn restart
vpn log [N]
```

Устройства добавляются/убираются из VPN в админке Keenetic — политика
доступа **EJX**.

## Требования / окружение

- Keenetic NC-2312 (MT7981B, aarch64, kernel 4.9-ndm-5) + Entware в `/opt`
- SSH-доступ: `root@192.168.1.1:222` (dropbear, только из LAN)
- mihomo v1.19.27 linux-arm64 (версия задаётся в `scripts/01-install.sh`)
- Политика доступа Keenetic «EJX» (connmark `0xffffaaa`) — создаётся в админке
