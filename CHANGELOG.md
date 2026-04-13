<p align="center">
  <b>RU</b> Русский | <b>EN</b> <a href="CHANGELOG.en.md">English</a>
</p>

# Changelog

Все заметные изменения в проекте документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

---

## [Unreleased]

---

## [5.8.0] — 2026-04-07

Крупное обновление безопасности и надёжности после нескольких последовательных аудитов кода. Причина minor bump вместо patch — накопился значительный объём breaking-semantics изменений в обработке конфигов, parameter source of truth, и обработке ошибок.

### Безопасность

- **ТСПУ-фингерпринт по дефолтным H1-H4 (Discussion #38):** Диапазоны H1-H4 в `generate_awg_params` были захардкожены одинаковыми для всех установок (`100000-800000`, `1000000-8000000`, ...). Российский DPI зафингерпринтил эту статическую сигнатуру — установки переставали работать через мобильных операторов РФ. H1-H4 теперь рандомизируются при каждой установке: 8 случайных uint32 значений сортируются и группируются в 4 непересекающиеся пары. Каждая установка получает уникальные диапазоны без статической сигнатуры. Спасибо @Klavishnik (отчёт) и @elvaleto (диагностика).

- **Split-brain prevention в `load_awg_params`:** Если live `awg0.conf` существует, он теперь ЕДИНСТВЕННЫЙ источник истины для AWG протокольных параметров. Частично повреждённый live-конфиг (пропавшее поле H4 например) даёт explicit error с return 1 вместо тихого fallback на устаревшие значения из init-файла. Это закрывает класс split-brain багов, когда сервер живёт по одному конфигу, а `regen` выпускает клиентам другой набор J*/S*/H*.

- **Atomic export в `load_awg_params_from_server_conf`:** Парсер больше не экспортирует `AWG_*` по мере нахождения полей. Теперь либо все 11 обязательных полей успешно прочитаны и экспортированы, либо environment не модифицируется вообще. Защищает от mixed state при повреждённом `awg0.conf`.

- **`restore_backup` форсирует `chmod 600` на восстановленных серверных ключах** вместо наследования mode из архива через `cp -a`. Защищает от восстановления ключей с неправильными правами если backup был создан с поломанной umask.

- **`--uninstall` больше не отключает UFW глобально** (HIGH severity, audit). Раньше `ufw --force disable` убивал весь firewall на VPS где UFW использовался для SSH/web hardening ДО установки нашего скрипта. Теперь installer записывает маркер `.ufw_enabled_by_installer` только если ДО установки UFW был inactive, и uninstall отключает UFW только при наличии маркера. Backwards compat: старые установки без маркера получают safer-by-default — UFW продолжит работать.

- **Process-wide lock в установщике** (audit). Два concurrent запуска `install_amneziawg.sh --yes` могли читать одинаковый `setup_state`, конкурентно дёргать `apt-get` и ломать package state. Теперь `flock -n` на `$AWG_DIR/.install.lock` берётся в начале main() на весь lifetime процесса — второй экземпляр получает `die "Другой installer уже запущен"`.

- **Валидация `--endpoint`** (audit). Раньше значение принималось verbatim и записывалось в init и client.conf без sanity check. Newline/кавычки в endpoint могли injectить лишние директивы в конфиги. Новая функция `validate_endpoint()` запрещает newline/CR/кавычки/backslash и требует формат FQDN / IPv4 / `[IPv6]`.

### Исправлено

- **`regen` не обновлял AWG-параметры в клиентских конфигах (#38):** `load_awg_params` читал AWG-параметры только из закешированного `/root/awg/awgsetup_cfg.init`, а не из актуального `/etc/amnezia/amneziawg/awg0.conf`. Если пользователь правил `awg0.conf` руками (например, для смены параметров обфускации), `regen` генерировал клиентские конфиги со старыми значениями. Теперь `load_awg_params` приоритетно читает live серверный конфиг, init-файл используется только как bootstrap fallback при первой установке. Добавлена новая функция `load_awg_params_from_server_conf`.

- **`manage add/remove` игнорировали exit code `apply_config`** (audit). При failure apply_config команды логировали "Конфигурация применена" и возвращали success — юзер видел "OK", хотя peer был applied только в конфиг, но не к live интерфейсу. Теперь caller проверяет return code, логирует actionable error с указанием на `systemctl status`, и устанавливает `_cmd_rc=1`.

- **`check_expired_clients` оставлял peer на live интерфейсе при ошибке apply** (audit). Если apply_config падал после удаления expired peer из state файлов — peer исчезал из expiry/, но оставался активным на интерфейсе до ручного перезапуска. Permanent stuck state. Теперь функция проверяет return code и возвращает 1 с actionable сообщением.

- **`--uninstall` удалял `/etc/fail2ban/jail.local` по эвристике** (audit). Раньше весь файл удалялся если содержал `banaction = ufw` — слишком широкий фильтр, мог снести чужой jail.local с custom jails. Блок удаления полностью убран, оставлено только `rm -f /etc/fail2ban/jail.d/amneziawg.conf` (наш собственный artefact).

- **`check_server` не проверял exit code `awg show`** (audit). Мог отрапортовать "Состояние OK" даже когда `awg` упал. Теперь `awg show awg0` вызывается с сохранением вывода и проверкой exit code.

- **`backup_configs`/`restore_backup` leak'или временные директории при SIGINT** (audit). `mktemp -d` использовался напрямую, а trap cleanup `_awg_cleanup` удалял только файлы. Добавлен helper `manage_mktempdir` с регистрацией в массиве и chained cleanup.

- **`add_peer_to_server` теперь берёт inner flock** для защиты при прямых вызовах не через `generate_client` (defense-in-depth, self-audit). Контракт "caller должен держать lock" был fragile.

- **`check_expired_clients` валидирует имя клиента** перед использованием в путях (defense-in-depth, self-audit). Раньше `name=$(basename "$efile")` использовался без валидации.

- **Имена backup файлов больше не содержат двоеточий**: `%F_%T` → `%F_%H-%M-%S`. Двоеточия несовместимы с FAT/NTFS при копировании backup на другой носитель.

- **`apply_config` имеет explicit `return 0` на success path** — убирает неопределённость exit code от `exec {fd}>&-`.

### Оптимизации

- **`generate_awg_h_ranges` делает один read из `/dev/urandom`** вместо 8 subprocess вызовов `rand_range`. `od -An -N32 -tu4 /dev/urandom` читает 32 байта = 8 uint32 значений за одну операцию. Fallback на `rand_range` если `/dev/urandom` недоступен.

### Тесты

- **80 bats-тестов** (+34 от baseline 5.7.12 / 46 тестов):
  - `test_h_ranges.bats` — 9 проверок генерации H1-H4
  - `test_load_awg_params.bats` — 14 проверок парсера awg0.conf, priority над init-файлом, split-brain prevention, atomic export, bootstrap path
  - `test_validate_endpoint.bats` — 14 проверок validate_endpoint (valid FQDN/IPv4/IPv6, reject newline/CR/quotes/space/backslash/empty)
- Все 46 существующих тестов (apply_config, IP allocation, parse_duration, peer management, safe_load_config, validate) продолжают PASS без регрессий.

### Добавлено

- **Telegram Bot (`bot`):** Полнофункциональный интерактивный бот для управления сервером через Telegram. Поддержка добавления/удаления клиентов, статистики, системного мониторинга. Автоматическая установка `jq`, настройка systemd сервиса, защита `flock`. Решена проблема лимита в 64 байта для `callback_data`.
- **Cloudflare WARP (`warp`):** Интеграция с Cloudflare WARP. Поддержка режимов "только WARP" и "через WARP" (двойной VPN). Автоматическая настройка маршрутизации и правил фаервола.
- **Лимиты скорости (`limit`):** Возможность установки ограничений скорости (downlink/uplink) для каждого клиента через `tc` (Traffic Control). Поддержка команд `limit`, `apply-limits`, `clear-limits`.
- **Системная статистика (`server`):** Команда для получения подробного отчёта о состоянии сервера (CPU, RAM, Disk, VPN uptime, активные сессии). Используется в Telegram-боте и CLI.

### Документация

- **ADVANCED.md/en FAQ**: добавлен workflow "Ротация параметров обфускации при детектировании DPI" — как править `awg0.conf` + restart + regen, с указанием что с 5.8.0 regen читает live config.
- **Telegram Bot Guide**: Добавлены инструкции по настройке и использованию бота.
- **WARP & Limits Guide**: Описание новых команд управления трафиком.

---

## [5.7.12] — 2026-04-06

### Исправлено

- **Fail2Ban на Debian (Discussion #39):** На Debian 12/13 rsyslog не установлен — fail2ban падал без доступа к `/var/log/auth.log`. Добавлен `backend = systemd` и установка `python3-systemd` для Debian. Ubuntu продолжает использовать `backend = auto`.

---

## [5.7.11] — 2026-03-31

### Исправлено

- **regen портит Address на Debian/mawk (#31):** `\s` в awk (PCRE-расширение) не поддерживается mawk. Заменено на `[ \t]`. Также `grep -oP` для приватного ключа заменён на POSIX-совместимый `sed`.
- **regen теряет значения после modify (#31):** При перегенерации конфига пользовательские настройки (DNS, PersistentKeepalive, AllowedIPs), изменённые через `modify`, теперь сохраняются.
- **modify оставляет .bak файлы (#31):** Бэкап-файл удаляется после успешного изменения.
- **check не видит порт на Debian (#31):** `grep -qP` заменён на POSIX-совместимый `grep` во всех местах проверки порта.

---

## [5.7.10] — 2026-03-31

### Добавлено

- **Batch remove клиентов (#30):** `manage remove client1 client2 client3` — удаление нескольких клиентов одной командой с одним apply_config в конце.
- **AWG_SKIP_APPLY=1 (#30):** Переменная среды для пропуска apply_config. Позволяет накопить изменения и применить одной командой — для автоматизации и API-интеграций. Корректное сообщение "Применение отложено" вместо "Конфигурация применена".
- **flock в apply_config (#30):** Межпроцессная блокировка (`${AWG_DIR}/.awg_apply.lock`) предотвращает параллельные restart/syncconf вызовы.
- **Unit тесты (bats-core):** 43 теста для awg_common.sh — parse_duration, safe_load_config, IP allocation, peer management, apply_config modes, validate. CI workflow `.github/workflows/test.yml`.

---

## [5.7.9] — 2026-03-25

### Добавлено

- **Режим применения конфигурации (#30):** Новая опция `--apply-mode=restart` для `manage_amneziawg.sh`. Позволяет переключиться на полный перезапуск сервиса вместо `awg syncconf` — обходит upstream deadlock в модуле amneziawg ([amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)). Режим сохраняется в `awgsetup_cfg.init` (`AWG_APPLY_MODE=restart`).

---

## [5.7.8] — 2026-03-24

### Добавлено

- **Batch add клиентов (#29):** `manage add client1 client2 client3 ...` — создание нескольких клиентов одной командой. `awg syncconf` вызывается один раз в конце вместо N раз. Предотвращает kernel panic при массовом создании клиентов (upstream баг модуля [amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)).

---

## [5.7.7] — 2026-03-24

### Исправлено

- **Потеря клиентов при переустановке:** `render_server_config` перезаписывал `awg0.conf` с нуля. Существующие `[Peer]` блоки теперь автоматически восстанавливаются из бэкапа при повторном прогоне шага 6.
- **Race condition при добавлении клиентов (TOCTOU):** `get_next_client_ip` и `add_peer_to_server` теперь выполняются в одной критической секции (`flock` в `generate_client`). Два параллельных `add` больше не могут выбрать один и тот же IP.
- **Ложный успех `restore`:** `restore_backup` при ошибках копирования (server/clients/keys) теперь возвращает non-zero exit code вместо тихого «Восстановление завершено».
- **Парсер конфига и двойные кавычки:** `safe_load_config` теперь корректно обрабатывает значения в двойных кавычках (`"value"`) в дополнение к одинарным.

---

## [5.7.6] — 2026-03-24

### Исправлено

- **UFW блокирует VPN-трафик (Discussion #28):** Добавлено правило `ufw route allow in on awg0 out on <nic>` при настройке фаервола. Ранее default policy `deny (routed)` блокировала проброс пакетов awg0→eth0, несмотря на PostUp iptables правила. Правило автоматически удаляется при деинсталляции.
- **PostUp FORWARD ordering:** `iptables -A FORWARD` заменён на `iptables -I FORWARD` для приоритетной вставки правила в начало цепочки. Гарантирует корректную маршрутизацию при работе без UFW (`--no-tweaks`).

---

## [5.7.5] — 2026-03-20

### Исправлено

- **Trailing newlines в awg0.conf (#27):** После удаления пиров в серверном конфиге накапливались множественные пустые строки. Добавлена нормализация через `cat -s` при каждом remove.
- **Timeout для awg syncconf (#27):** `awg-quick strip` и `awg syncconf` теперь вызываются с `timeout 10`. При зависании (upstream deadlock [amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)) скрипт делает fallback на полный перезапуск сервиса вместо бесконечного ожидания.

---

## [5.7.4] — 2026-03-20

### Исправлено

- **MTU 1280 по умолчанию (Closes #26):** Серверный и клиентские конфиги теперь содержат `MTU = 1280`. Решает проблему подключения смартфонов через сотовые сети и iPhone.
- **Jmax cap:** Максимальный размер junk-пакетов ограничен `Jmin+500` (было `Jmin+999`). Предотвращает фрагментацию при MTU 1280.
- **validate_subnet:** Последний октет подсети должен быть 1 (адрес сервера). Ранее допускались произвольные значения, что приводило к конфликту с `get_next_client_ip`.
- **awg show dump parsing:** Пропуск interface line через `tail -n +2` вместо ненадёжной проверки пустого поля psk.
- **manage help без AWG:** `help` и пустая команда выводят справку до `check_dependencies`, позволяя использовать `--help` без установленного AWG.
- **help text:** Справка инсталлятора перечисляет все 4 поддерживаемые ОС (Ubuntu 24.04/25.10, Debian 12/13).
- **manage --expires help:** Добавлен формат `4w` в справку `--expires` (уже поддерживался парсером, но отсутствовал в тексте help).

### Улучшено

- **Кэш IP:** `get_server_public_ip()` кэширует результат — повторные вызовы (add/regen) не обращаются к внешним сервисам.
- **O(N) IP lookup:** `get_next_client_ip()` использует ассоциативный массив для поиска свободного IP вместо вложенных циклов O(N²).

### Документация

- Исправлена таблица совместимости клиентов: `amneziawg-windows-client >= 2.0.0` поддерживает AWG 2.0 (ранее ошибочно указано как AWG 1.x only).
- Исправлен APT-формат для Ubuntu 24.04: DEB822 `.sources` (было `.list`).
- Исправлен пример `restore` в FAQ миграции: корректный путь `/root/awg/backups/`.
- Исправлена ссылка на деинсталляцию в EN README FAQ: `install_amneziawg_en.sh`.
- Добавлен Ubuntu 25.10 в FAQ ответ «Какой хостинг подходит?».
- Обновлены примеры конфигов: добавлен `MTU = 1280`.
- Обновлён диапазон Jmax в таблице параметров: `+500` вместо `+999`.
- Переписана секция MTU: автоматический для v5.7.4+, ручной workaround для старых версий.
- Убран пункт «MTU не задан» из «Известных ограничений».
- Обновлён FAQ «Как изменить MTU?» для автоматического MTU.

---

## [5.7.3] — 2026-03-18

### Исправлено

- **Uninstall SSH lockout:** UFW отключается ДО unban fail2ban — предотвращает блокировку SSH при обрыве соединения во время деинсталляции.
- **CIDR валидация (strict):** Невалидный CIDR в `--route-custom` вызывает `die()` в CLI-режиме. В интерактивном — повторный запрос ввода. Ранее установка продолжалась с некорректными AllowedIPs.
- **validate_subnet .0/.255:** Подсети с последним октетом 0 (network address) или 255 (broadcast) отклоняются — ранее принимались.
- **ALLOWED_IPS resume:** При возобновлении установки из конфига валидируются пользовательские CIDR (mode=3) — ранее загружались без проверки.
- **modify sed mismatch:** Синхронизирован паттерн sed с grep в `modify_client()` — обрабатывает .conf с любым форматированием пробелов вокруг `=`. Добавлена постпроверка замены.
- **--no-color ANSI leak:** Устранена утечка ESC-кодов `\033[0m` в вывод `list --no-color`.
- **Uninstall wildcard cleanup:** Удалены бессмысленные wildcard-паттерны из uninstall — файлы `*amneziawg*` в `/etc/cron.d/` и `/usr/local/bin/` никогда не создавались.

### Документация

- Добавлен AmneziaWG for Windows 2.0.0 как поддерживаемый клиент.
- Удалено ошибочное примечание о необходимости curl на Debian.

---

## [5.7.2] — 2026-03-16

### Безопасность

- **safe_load_config():** Замена `source` на whitelist-парсер конфигурации в `awg_common.sh` — только разрешённые ключи (AWG_*, OS_*, DISABLE_IPV6 и др.) загружаются из файла. Устраняет потенциальную инъекцию кода через `awgsetup_cfg.init`.
- **Supply chain pinning:** URL скачивания скриптов привязаны к тегу версии (`AWG_BRANCH=v${SCRIPT_VERSION}`) вместо `main`. Переменная `AWG_BRANCH` доступна для переопределения при разработке.
- **HTTPS для IP-детекции:** `get_server_public_ip()` использует HTTPS вместо HTTP для определения внешнего IP.

### Исправлено

- **modify allowlist:** Убраны Address и MTU из допустимых параметров `modify` — эти параметры управляются инсталлятором и не должны изменяться вручную.
- **flock для add/remove peer:** Операции добавления и удаления пиров защищены `flock -x` для предотвращения race condition при параллельных вызовах.
- **cron expiry env:** Cron-задача expiry явно задаёт PATH и использует `--conf-dir` для корректной работы в минимальном cron-окружении.
- **log_warn для malformed expiry:** Некорректные файлы истечения обрабатываются через `log_warn` вместо тихого пропуска.
- **Мёртвый код:** Удалены неиспользуемые функции и переменные из `awg_common.sh`.

### Улучшено

- **list_clients O(N):** Оптимизация `list_clients` — однопроходный алгоритм вместо O(N*M).
- **backup/restore:** Бэкапы теперь включают данные истечения клиентов (`expiry/`) и cron-задачу.
- **Версия:** 5.7.1 → 5.7.2 во всех скриптах.

---

## [5.7.1] — 2026-03-13

### Исправлено

- **vpn:// URI AllowedIPs:** `generate_vpn_uri()` использовала захардкоженный `0.0.0.0/0` вместо реальных AllowedIPs из клиентского конфига — split-tunnel конфигурации теперь корректно передаются в URI.
- **Fail2Ban jail.d:** Установка теперь пишет в `/etc/fail2ban/jail.d/amneziawg.conf` вместо перезаписи `jail.local` — пользовательские настройки Fail2Ban сохраняются.
- **Fail2Ban uninstall:** Деинсталляция удаляет только свои артефакты вместо `rm -rf /etc/fail2ban/`.
- **validate_client_name:** Валидация имени клиента добавлена в команды `remove` и `modify` — ранее работала только для `add` и `regen`.
- **exit code:** Скрипт управления теперь возвращает корректный код ошибки вместо безусловного `exit 0`.
- **expiry cron path:** Cron-задача expiry использует `$AWG_DIR` вместо захардкоженного `/root/awg/`.

### Удалено

- **rand_range():** Удалена неиспользуемая функция из `awg_common.sh` (инсталлятор определяет свою копию).

---

## [5.7.0] — 2026-03-13

### Добавлено

- **syncconf:** Команды `add` и `remove` автоматически применяют изменения через `awg syncconf` — zero-downtime, без разрыва активных соединений (#19).
- **apply_config():** Новая функция в `awg_common.sh` — применяет конфиг через `awg syncconf` с fallback на полный перезапуск.
- **--no-tweaks:** Флаг для инсталлятора — пропускает hardening (UFW, Fail2Ban, sysctl tweaks, cleanup) для опытных пользователей с уже настроенными серверами (#21).
- **setup_minimal_sysctl():** Минимальная настройка sysctl при `--no-tweaks` — только `ip_forward` и IPv6.

### Исправлено

- **trap конфликт:** Устранена перезапись обработчика EXIT при подключении `awg_common.sh` через `source`. Теперь каждый скрипт владеет своим trap и цепляет cleanup библиотеки явно.

### Изменено

- **Expiry cleanup:** Авто-удаление истёкших клиентов теперь использует `syncconf` вместо полного перезапуска.
- **Manage help:** Убрано предупреждение о ручном перезапуске после `add`/`remove` (больше не требуется).
- **Версия:** 5.6.0 → 5.7.0 во всех скриптах.

---

## [5.6.0] — 2026-03-13

### Добавлено

- **stats:** Команда `stats` — статистика трафика по клиентам (format_bytes через awk).
- **stats --json:** Машиночитаемый JSON-вывод для интеграции и мониторинга.
- **--expires:** Флаг `--expires=ВРЕМЯ` для `add` — клиенты с ограниченным сроком действия (1h, 12h, 1d, 7d, 30d, 4w).
- **Система истечения:** Авто-удаление клиентов через cron (`/etc/cron.d/awg-expiry`, проверка каждые 5 мин).
- **vpn:// URI:** Генерация `.vpnuri` файлов для импорта в Amnezia Client (zlib-сжатие через Perl).
- **Debian 12 (bookworm):** Полная поддержка — PPA через маппинг codename на focal.
- **Debian 13 (trixie):** Полная поддержка — PPA через маппинг codename на noble, DEB822 формат.
- **linux-headers fallback:** Авто-fallback на `linux-headers-$(dpkg --print-architecture)` для Debian.

### Исправлено

- **JSON sanitization:** Безопасная сериализация в JSON-выводе.
- **Numeric quoting:** Числовые параметры AWG в кавычках для корректной обработки.
- **O(n) stats:** Single-pass сбор статистики вместо множественных вызовов.
- **backup filename:** `%F_%T` → `%F_%H%M%S` (убраны двоеточия из имени файла).
- **cron auto-remove:** Очистка cron при удалении последнего expiry-клиента.
- **backups perms:** `chmod 700` после `mkdir` для директории бэкапов.
- **apt sources location:** Бэкап apt sources в `$AWG_DIR` вместо `sources.list.d`.
- Множественные мелкие исправления по code review (19 фиксов).

### Изменено

- **Debian-aware installer:** Определение OS_ID, адаптивное поведение (cleanup, PPA, headers).
- **Версия:** 5.5.1 → 5.6.0 во всех скриптах.

---

## [5.5.1] — 2026-03-05

### Исправлено

- **read -r:** Добавлен флаг `-r` ко всем `read -p` (15 мест) — предотвращает интерпретацию `\` как escape-символа при пользовательском вводе.
- **curl timeout:** Добавлены `--max-time 60 --retry 2` к скачиванию скриптов при установке — предотвращает бесконечное зависание при проблемах с сетью.
- **subnet validation:** Валидация подсети теперь проверяет каждый октет ≤ 255 — ранее пропускала адреса вроде `999.999.999.999/24`.
- **chmod checks:** Добавлена проверка ошибок `chmod 600` при установке прав на файлы ключей.
- **pipe subshell:** Исправлена потеря переменных в цикле регенерации конфигов из-за pipe subshell — заменён на here-string.
- **port grep:** Улучшена точность поиска порта в `ss -lunp` — замена `grep ":PORT "` на `grep -P ":PORT\s"` для исключения ложных совпадений.
- **sed → bash:** Замена `sed 's/%/%%/g'` на `${msg//%/%%}` — убраны 2 лишних subprocess'а на каждый вызов лога.
- **cleanup trap:** Добавлен `trap EXIT` для автоматической очистки временных файлов инсталлятора.

---

## [5.5] — 2026-03-02

### Исправлено

- **uninstall:** Деинсталляция выполнялась без подтверждения при недоступном `/dev/tty` (pipe, cron, non-TTY SSH) из-за дефолтного `confirm="yes"`.
- **uninstall:** Модуль ядра `amneziawg` оставался загруженным после деинсталляции — добавлен `modprobe -r`.
- **uninstall:** Рабочая директория `/root/awg/` пересоздавалась логированием после удаления — перенесена очистка в конец.
- **uninstall:** Пустая `/etc/fail2ban/` и бэкапы PPA `.bak-*` оставались после деинсталляции.
- **--no-color:** Escape-код сброса `\033[0m` не подавлялся при `--no-color` — исправлена инициализация `color_end`.
- **step99:** Дублирующееся сообщение «Очистка apt…» — убран лишний вызов `log` перед `cleanup_apt()`.
- **step99:** Lock-файл `setup_state.lock` не удалялся после завершения установки.
- **manage:** Непоследовательная орфография «удален»/«удалён» — унифицировано.

---

## [5.4] — 2026-03-02

### Исправлено

- **step5:** Ошибка скачивания `manage_amneziawg.sh` теперь фатальна (`die`), как и для `awg_common.sh`.
- **update_state():** `die()` внутри flock-subshell не завершал основной процесс — перенесён наружу.
- **step6:** Бэкап серверного конфига теперь создаётся *до* `render_server_config`, а не после перезаписи.
- **cloud-init:** Консервативная детекция — маркеры cloud-init проверяются первыми, чтобы не удалить его на cloud-хостах.
- **restore_backup():** Добавлена защита от зависания в неинтерактивном режиме (требуется путь к файлу).
- **Подсеть:** Валидация теперь разрешает только маску `/24` (соответствует фактической логике аллокации IP).
- **Версия:** Устранены артефакты `v5.1` в логах и диагностике; введена константа `SCRIPT_VERSION`.

---

## [5.3] — 2026-03-02

### Добавлено

- **Английские скрипты:** Полные английские версии всех трёх скриптов (`install_amneziawg_en.sh`, `manage_amneziawg_en.sh`, `awg_common_en.sh`) с переведёнными сообщениями, справкой и комментариями.
- **CI:** ShellCheck и `bash -n` проверки для английских скриптов.
- **PR template:** Чеклист-пункт синхронизации EN/RU версий.
- **CONTRIBUTING.md:** Требование синхронизации EN/RU при изменении скриптов.

---

## [5.2] — 2026-03-02

### Исправлено

- **check_server():** Исправлен инвертированный exit code (return 1 при успехе → return 0).
- **Диагностика restart/restore:** Вывод `systemctl status` теперь корректно попадает в лог.
- **restore_backup():** Путь восстановления серверного конфига теперь берётся из `$SERVER_CONF_FILE`.

### Улучшено

- **awg_mktemp():** Активирована автоочистка временных файлов через trap EXIT.
- **modify:** Добавлен allowlist допустимых параметров (DNS, Endpoint, AllowedIPs, Address, PersistentKeepalive, MTU). *(Address и MTU убраны в v5.7.2)*
- **Документация:** Убрано некорректное упоминание поддержки подсети /16.
- Удалён мёртвый trap-код из install_amneziawg.sh.

---

## [5.1] — 2026-03-01

### Исправлено

- **CRITICAL:** Command injection через спецсимволы `#`, `&`, `/`, `\` в `modify_client()` — добавлена функция `escape_sed()` для экранирования.
- **CRITICAL:** Race condition в `update_state()` — добавлена блокировка через `flock -x`.
- **MEDIUM:** `curl` в `get_server_public_ip()` мог получить HTML вместо IP — добавлен флаг `-f` (fail on error) и очистка whitespace.
- **MEDIUM:** Fallback `$RANDOM` в `rand_range()` давал макс. 32767 вместо uint32 — заменён на `(RANDOM<<15|RANDOM)` для 30-битного диапазона.
- **MEDIUM:** Pipe subshell в `check_server()` — заменён на process substitution `< <(...)`.
- **MEDIUM:** Awk-скрипт `remove_peer_from_server()` не обрабатывал нестандартные секции — добавлена обработка любых `[...]` блоков.

### Добавлено

- **CI:** GitHub Actions workflow — ShellCheck + `bash -n` на push/PR к main.
- **GitHub:** Issue templates (bug report, feature request) в формате YAML-форм.
- **GitHub:** PR template с чеклистом (bash -n, shellcheck, VPS test, changelog).
- **SECURITY.md:** Политика безопасности, ответственное раскрытие уязвимостей.
- **CONTRIBUTING.md:** Гайд для контрибьюторов с требованиями к коду и тестированию.
- **.editorconfig:** Единые настройки форматирования (UTF-8, LF, отступы).
- **Trap cleanup:** Автоматическая очистка временных файлов через `trap EXIT` + `awg_mktemp()`.
- **Bash version check:** Проверка `Bash >= 4.0` в начале install и manage скриптов.
- **Документация:** Примеры конфигов, Mermaid-диаграмма архитектуры, расширенный FAQ, troubleshooting.

### Изменено

- **Версия:** 5.0 → 5.1 во всех скриптах и документации.
- **README.md:** Таблица команд расширена до 10 (+ modify, backup, restore), FAQ до 8 вопросов.
- **ADVANCED.md:** Добавлены примеры конфигов, команд manage, описание диагностики, инструкция обновления.

---

## [5.0] — 2026-03-01

### ⚠️ Breaking Changes

- **Протокол AWG 2.0** несовместим с AWG 1.x. Все клиенты должны обновить конфигурацию.
- Требуется клиент **Amnezia VPN >= 4.8.12.7** с поддержкой AWG 2.0.
- Предыдущая версия доступна в ветке [`legacy/v4`](https://github.com/bootkiTdll/amneziawg-installer-fork/tree/legacy/v4).

### Добавлено

- **AWG 2.0:** Полная поддержка протокола — параметры H1-H4 (диапазоны), S1-S4, CPS (I1).
- **Нативная генерация:** Все ключи и конфиги генерируются средствами Bash + `awg` без внешних зависимостей.
- **awg_common.sh:** Общая библиотека функций для install и manage скриптов.
- **Очистка сервера:** Автоматическое удаление ненужных пакетов (snapd, modemmanager, networkd-dispatcher, unattended-upgrades и др.).
- **Hardware-aware оптимизация:** Автоматическая настройка swap, сетевых буферов и sysctl на основе характеристик сервера (RAM, CPU, NIC).
- **Оптимизация NIC:** Отключение GRO/GSO/TSO offloads для стабильной работы VPN-туннеля.
- **Расширенный sysctl hardening:** Адаптивные сетевые буферы, conntrack, дополнительная защита.
- **Регенерация отдельных клиентов:** Команда `regen <имя>` для перегенерации конфигов одного клиента.
- **Валидация AWG 2.0:** Проверка наличия всех параметров протокола в серверном конфиге.
- **AWG 2.0 диагностика:** Команда `check` показывает статус параметров AWG 2.0.

### Удалено

- **Python/venv/awgcfg.py:** Полностью убрана зависимость от Python и внешнего генератора конфигов.
- **Workaround для бага awgcfg.py:** Больше не требуется перемещение `awgsetup_cfg.init` при генерации.
- **Параметры j1-j3, itime:** Устаревшие параметры AWG 1.x больше не поддерживаются.

### Изменено

- **Архитектура:** 2 файла → 3 файла (install + manage + awg_common.sh).
- **Шаг 1 установки:** Добавлена системная очистка и оптимизация.
- **Шаг 2 установки:** Устанавливается `qrencode` вместо Python.
- **Шаг 5 установки:** Скачиваются `awg_common.sh` + `manage` (без Python/venv).
- **Шаг 6 установки:** Полностью нативная генерация конфигов.
- **Генерация ключей:** Нативная через `awg genkey` / `awg pubkey`.
- **QR-коды:** Генерация через `qrencode` напрямую (без Python).
- **Документация:** README.md и ADVANCED.md обновлены для AWG 2.0.

---

## [4.0] — 2025-07-15

### Добавлено

- Поддержка AWG 1.x (Jc, Jmin, Jmax, S1, S2, H1-H4 фиксированные).
- Установка через DKMS.
- Генерация конфигов через Python + awgcfg.py.
- Управление клиентами: add, remove, list, regen, modify, backup, restore.
- UFW firewall, Fail2Ban, sysctl hardening.
- Поддержка возобновления установки после перезагрузки.
- Диагностический отчет (`--diagnostic`).
- Полная деинсталляция (`--uninstall`).

[Unreleased]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.8.0...HEAD
[5.8.0]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.12...v5.8.0
[5.7.12]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.11...v5.7.12
[5.7.11]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.10...v5.7.11
[5.7.10]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.9...v5.7.10
[5.7.9]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.8...v5.7.9
[5.7.8]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.7...v5.7.8
[5.7.7]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.6...v5.7.7
[5.7.6]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.5...v5.7.6
[5.7.5]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.4...v5.7.5
[5.7.4]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.3...v5.7.4
[5.7.3]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.2...v5.7.3
[5.7.2]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.1...v5.7.2
[5.7.1]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.7.0...v5.7.1
[5.7.0]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.6.0...v5.7.0
[5.6.0]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.5.1...v5.6.0
[5.5.1]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.5...v5.5.1
[5.5]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.4...v5.5
[5.4]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.3...v5.4
[5.3]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.2...v5.3
[5.2]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.1...v5.2
[5.1]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v5.0...v5.1
[5.0]: https://github.com/bootkiTdll/amneziawg-installer-fork/compare/v4.0...v5.0
[4.0]: https://github.com/bootkiTdll/amneziawg-installer-fork/releases/tag/v4.0
