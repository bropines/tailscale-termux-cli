# Аудит `bropines/tailscale-termux-cli`

Ревью среза `main` (клон `--depth 50`), только чтение. Ссылки — `файл:строка` из клона; часть проверена ещё и на опубликованных бинарях релиза `v1.100.0-10`.

## Вердикт

Раздавать посторонним в текущем виде — нет. Два блокера: пакет по умолчанию поднимает неаутентифицированный SOCKS5 на фиксированном `127.0.0.1:1055`, доступный любому приложению на телефоне, а заглавная фича проекта (netmon-патч) физически отсутствует в трёх из четырёх публикуемых архитектур. Остальное — крепкая, но полусобранная обвязка: два пути запуска демона живут своей жизнью, документация описывает поведение, которого в коде нет. Ядро идеи и патчи сделаны грамотно, всё чинится локальными правками — переписывать нечего.

---

## Находки, худшее первым

### 1. SOCKS5 без авторизации, включён по умолчанию, фиксированный порт — [критично]

`termux-services/tailscaled/run:8-12` — `exec tailscaled --statedir=… --socket=… --tun=userspace-networking --socks5-server=localhost:1055`. Этот файл едет в .deb (`build_deb.sh:77`), postinst стартует сервис без спроса (`build_deb.sh:425-428`: `sv-enable` + `sv up`; то же в `install.sh:73-77` и `remote-install.sh:105-109`). `sv up` поднимает сервис независимо от `down`-файла из `build_deb.sh:81`, так что защита там номинальная; README.md:15 подтверждает автостарт как фичу.

Loopback на Android не изолирован по приложениям. После `tailscale up` любое приложение с одним лишь `INTERNET` открывает `127.0.0.1:1055` и получает egress в тайлнет с identity узла: приватные хосты, subnet routes, exit node. Ни авторизации, ни allowlist, ни строчки в README; порт известен заранее. Границы, честно: это egress-as-this-node, а не управление демоном — control-сокет лежит в приватном каталоге Termux, `tailscale up/down` и node key чужому приложению недоступны. И сам флаг в userspace-режиме легитимен. Проблема — «включено по умолчанию + фиксированный порт + ни слова в доках». В upstream авторизации нет вообще; в TailSocks ты её добавляешь патчем `appctr/patches/02-socks5-auth.patch` (`TS_SOCKS5_USER`/`TS_SOCKS5_PASS`).

**Фикс.** Убрать `--socks5-server` из сервисного `run`, включать только по `TS_SOCKS5_PORT` в `.env`; в README — абзац о том, что это дверь для всех приложений устройства. Для паритета — перенести сюда патч 02 и поддержать креды в обоих путях запуска.

### 2. Netmon-патч собран только в aarch64 — [критично]

`patches/fix_android_netmon.go:1` — `//go:build android`. `build.sh:94` ставит `goos="linux"` по умолчанию и переопределяет только aarch64 (`:98-101`); arm (`:102-107`), i686 (`:108-112`), x86_64 (`:113-116`) собираются с `GOOS=linux`, где тег `android` не выполняется. Из бинаря выпадает весь файл: `init()` (`:107`), маскировка hostinfo, редирект DNS, `netmon.RegisterInterfaceGetter` (`:132`), ifconfig-фолбэк. Публикуются при этом все четыре (`build.sh:158`, `build.yml:27`, релиз на `:87-92`).

Проверено на релизных бинарях: `grep -ac "Termux] Global DNS"` → aarch64 = 1, arm/i686/x86_64 = 0; ссылок на `wlynxg/anet` — 5/0/0/0. Патча доказуемо нет в трёх артефактах, которые `remote-install.sh:46-70` раздаёт по `uname -m`. На 32-битном ARM или x86 (эмулятор, WSA, Chromebook) по документированному однострочнику ставится стоковый `GOOS=linux` tailscaled — ровно тот, что упирается в netlink-ограничения Android 11+, ради обхода которых проект существует; README.md:26 и тело релиза (`build.yml:96`) обещают патч всем. Дополнительно `readelf`: у `tailscaled-x86_64` `.interp = /lib64/ld-linux-x86-64.so.2` (glibc-загрузчик, которого на Android нет) против `/system/bin/linker64` у aarch64 — этот ассет в Termux, скорее всего, вообще не стартует. Это недосмотр, а не решение: соседний `patches/fix_args_android.go:1` имеет `//go:build android || linux` — тег там расширяли осознанно (коммит 3897341), netmon забыли.

**Фикс.** Либо `//go:build android || linux` + рантайм-гейт для ifconfig-фолбэка, либо собирать все Android-цели с `GOOS=android` (`go tool dist list` даёт android/386, amd64, arm, arm64). Иначе — не публиковать три архитектуры без патча.

### 3. `.env` полностью игнорируется на пути по умолчанию — [важно]

README.md:87 обещает «Variables are automatically loaded on start» и таблицу `TS_SOCKS5_PORT` / `TS_SOCKS5_SERVER` / `TS_HTTP_PROXY` / `TS_PORT` / `TS_VERBOSE` / `TS_EXTRA_ARGS` (README.md:89-96). Читает `.env` ровно один файл — хелпер `tailscaled-start` (`build_deb.sh:198-200`). Сервисный `run`, который и запускается после установки, не делает `source` ничего и имеет жёстко зашитый список флагов.

Хуже: до `.env` не добраться и вручную — `build_deb.sh:193-196` (`pgrep -f "tailscaled.*$STATE_DIR"`) выходит с «already running» ещё до строки 198, а `tailscale-cli` при автостарте предпочитает `sv up tailscaled` (`:301-303`). Пользователь пишет `TS_EXTRA_ARGS="--hostname=…"`, делает `sv restart` — ничего не меняется. Отдельно `TS_VERBOSE` не читает вообще никто: `grep -rn TS_VERBOSE` даёт только README.md:95 и :101. Upstream-имя — `TS_LOG_VERBOSITY`, и оно заработало бы само, потому что `set -a` в `build_deb.sh:199` экспортирует всё из `.env` в окружение демона.

**Фикс.** Вынести сборщик флагов в общий `libexec`-скрипт и подключать из обоих путей (или сделать `run` обёрткой над `tailscaled-start --foreground`). `TS_VERBOSE` — переименовать в `TS_LOG_VERBOSITY` или убрать из README.

### 4. `pkill -f tailscaled` без скоупа в обоих инсталляторах — [важно]

`install.sh:48-49` и `remote-install.sh:80-81`: `pkill -f tailscaled || true`. Под uid Termux это всегда убивает три своих процесса: `tail -f …/tailscaled.log` из `tailscaled-log` (`build_deb.sh:284`), `runsv tailscaled` и `svlogd` из `termux-services/tailscaled/log/run`. Достижимо и из `tailscale-update` (`build_deb.sh:390` пайпит `remote-install.sh` в bash). Убив `runsv` без `sv down`, скрипт добивается того, что `runsvdir` поднимает сервис обратно через секунду — ровно во время `dpkg -i` на следующей строке: паттерн одновременно слишком широкий и не решающий свою задачу.

Второй порядок, но для твоей аудитории реальный: под `su` на рутованном телефоне паттерн попадает и в демон TailSocks — его cmdline содержит `--socket=/data/data/io.github.bropines.tailscaled/files/tailscaled.sock`, где в имени пакета буквально есть «tailscaled». Ты чинил это в обратную сторону в `RootUtils.kt:2496-2508`, с комментарием про «a Termux tailscaled». Репозиторий, впрочем, нигде не зовёт `su`, так что это user-error путь, не дефолт.

**Фикс.** Как в TailSocks: `pkill -f -- "--socket=$HOME/.tailscale/tailscaled.sock"`, а лучше `sv down tailscaled` перед установкой. Остальные kill/pgrep в дереве уже заскоуплены (`build_deb.sh:193, 252, 270, 330`) — несогласованы ровно инсталляторы.

### 5. `tailscaled-stop` не может остановить сервисный демон — [важно]

Весь хелпер (`build_deb.sh:262-273`) — `pkill -f "tailscaled.*$STATE_DIR"` и `rm -f socks_addr`, никакого `sv down`. Сервис запускает демон через `exec` (`run:8`), то есть убивается прямой ребёнок `runsv` при выставленном want-up — runit поднимает его назад. `pkill` при успехе возвращает 0, поэтому `|| echo` молчит и команда выглядит успешной; плюс `tailscale-cli` сам делает `sv up` (`:301-303`). Смягчает то, что README документирует остановку через `tailscaled-start --service=off` (README.md:74-77) и про `tailscaled-stop` не пишет вовсе — но бинарь лежит в PATH под именем, обещающим обратное.

**Фикс.** `sv down tailscaled`, если сервис есть; заскоупленный pkill — только для nohup-запуска. И либо задокументировать хелпер, либо не ставить его.

### 6. Однострочная установка падает на чистом Termux — [важно]

`remote-install.sh:4` — `set -eu`; пререквизиты (`:10-16`) — только `curl wget grep dpkg zstd`, `termux-services` там нет, хотя пакет объявляет `Depends: termux-services, …` (`build_deb.sh:400`, подтверждено `dpkg-deb -I` на релизном .deb). `dpkg -i` на `:84` при неудовлетворённой зависимости распаковывает пакет, отказывается конфигурировать и выходит с кодом 1 (воспроизведено на синтетическом .deb) — `set -e` убивает скрипт до `apt install -f -y` на `:85-87`, до `sv-enable` и до финального баннера. Хуже: trap на `:74-75` удаляет `$TMP_DIR` вместе со скачанным .deb, повторить `dpkg -i` руками не по чему; остаётся полуустановленный пакет, блокирующий apt. Тот же дефект в `install.sh:4` + `:51` (там .deb выживает в `dist/`). Комментарий автора на `remote-install.sh:83` («then fix deps») показывает, что починка задумана — её ломает именно `set -e`.

**Фикс.** `dpkg -i … || true` и `termux-services` в `REQUIREMENTS`.

### 7. DNS прибит к 8.8.8.8, identity подменяется — и то и другое не документировано — [важно]

`patches/fix_android_netmon.go:118-126`: `net.DefaultResolver` с `Dial`, игнорирующим свои аргументы `network`/`address` и всегда идущим на `8.8.8.8:53` по UDP (включая TCP-ретрай для усечённых ответов). `:107-116` — hook на hostinfo: `hi.App = "tailscale-cli"`, `hi.DeviceModel = "Termux"`, комментарий «Masking as CLI to bypass mobile-specific policies». В README нет ни того, ни другого (единственный DNS-хит — README.md:55, про тест).

Каждый резолв демона уходит в Google мимо сети пользователя, VPN и Private DNS. Админ тайлнета видит в инвентаре фальшивый тип клиента, policy/posture по типу клиента обходятся. Не преувеличиваю: `OS` остаётся `android` (hook его не трогает), а у upstream есть bootstrap-фолбэк (`dnsfallback`), так что при заблокированном 8.8.8.8 будет деградация, а не отказ. Причина понятна — `build.sh:129` ставит `CGO_ENABLED=0`, чистый Go-резолвер, а `/etc/resolv.conf` в Termux нет; но «только Google, ненастраиваемо, без документации» — не единственный вариант: `getprop net.dns1` или knob в `.env` стоят столько же.

**Фикс.** Сделать 8.8.8.8 фолбэком, вынести в `.env`, описать в README и подмену hostinfo с причиной.

### 8. Кэш исходников и бинарей не сверяется с версией — [важно]

`build.sh:55-63` пропускает скачивание, если каталог есть («Source already exists»), не сверяя его с `$DOWNLOAD_VERSION`. `build_deb.sh:55-58` и `:450-452` пересобирают, только если бинарей *нет*. Версия .deb штампуется независимо: `build_deb.sh:11` берёт `git describe` в *этом* репозитории, не в дереве tailscale. Локальный сборщик, обновившийся `git pull` и запустивший `./install.sh`, получает пакет с новой версией и старым `tailscaled` внутри; dpkg записывает новую версию, а `tailscale-update` (`build_deb.sh:381-385`) сверяет именно эту запись с тегом релиза и пишет «You are already on the latest version» — пользователь уверен, что пропатчен, а под ним демон с известными upstream-CVE. `.gitignore` содержит `bin/` и `tailscale_src/`, поэтому `git pull` это состояние не чистит. Релизы не задеты: CI чекаутит в чистый runner (`build.yml:29`).

**Фикс.** Стемп `tailscale_src/.ts_version` и `bin/$arch/.ts_version`; при несовпадении с запрошенной версией — принудительная перекачка/пересборка.

### 9. Ночной автообновлятор не может опубликовать релиз — [важно]

`check-updates.yml:47-52` зовёт `build.yml` как reusable workflow. `build.yml:88` гейтит публикацию на `startsWith(github.ref,'refs/tags/') || event_name == 'workflow_call' || event_name == 'workflow_dispatch'`, а reusable workflow наследует контекст вызывающего — на cron это `schedule` / `refs/heads/main`, все три дизъюнкта ложны. Подтверждено по API на последнем ночном ране (34073832941, event=schedule): все четыре сборки успешны, «Create Release» — **skipped**, «Upload Combined Artifacts» — success. Последний реальный релиз — 2026-08-02; все релизы по времени совпадают с ручными `workflow_dispatch`/tag-push, ни один — с `0 0 * * *`. Вдобавок `check-updates.yml:33` сравнивает upstream-тег tailscale с твоим тегом вида `v1.100.0-10` — они не совпадут никогда, поэтому `new_version` всегда `true` и четыре архитектуры кросс-компилируются и выбрасываются каждую ночь. «Зато апстрим не уедет юзерам автоматом» здесь не оправдание: `workflow_call` в условии перечислен явно — это попытка включить путь, а не защита.

**Фикс.** Гейтить на `inputs.ts_version != ''` (контекст `inputs` на этом пути заполнен и уже используется на `build.yml:51` и `:91`); публикацию ассетов закрыть Actions-environment с обязательным ревьюером; сравнивать нормализованные версии, а не свой суффикс.

### 10. Исходники tailscale не пиннятся, не проверяются и исполняются на билд-машине — [важно]

`build.sh:19` определяет версию на лету через `git ls-remote` (самый свежий тег), `build.sh:56` качает тарболл `wget | tar -xz` без единой проверки (`grep -rniE "sha256|gpg|cosign|verify"` по дереву даёт один ложный хит-комментарий). А `build_deb.sh:101-104` **запускает** код из этого тарболла на машине сборщика (хостовая `go build ./cmd/tailscale`, затем `… completion bash`) — на пути `./install.sh` это телефон пользователя. Контраст в том же файле: `build.sh:83` — `go get github.com/wlynxg/anet@v0.0.5`, единственная зависимость, которая и запиннена, и проверяется через go.sum/sumdb. Для CI-релизов версию задаёт `build.yml:50-51` из входа, но это всё равно изменяемый тег без записанного хеша. Соседние экосистемы (Termux build.sh, PKGBUILD, formulae) для ровно этого скачивания пишут sha256.

**Фикс.** Файл `VERSION` + ожидаемый sha256 с проверкой после скачивания (или клон по коммит-хешу). Completions — сгенерировать заранее и положить в репозиторий, чтобы скачанный код не исполнялся на билд-машине.

### 11. Пакетный `log/run` теряет `mkdir`, который есть в репозитории — [средне]

`termux-services/tailscaled/log/run:2-4` создаёт каталог, но в пакет не едет: `build_deb.sh:77` копирует только основной `run`, а `:84-88` перезаписывает лог-скрипт heredoc'ом без `mkdir`. `$PREFIX/var/log/tailscaled` не создаёт ни payload (`:67-69, 96`), ни postinst (`:410-431`). svlogd не создаёт логкаталог сам и фатально завершается, если ни один не открылся — `runsv` крутит `log/run` в цикле, серверные логи не пишутся; побочно `runsv` держит read-end пайпа, и при заполнении 64K буфера `tailscaled` может залипнуть на записи. Поведение runit в этом окружении проверить не удалось — помечаю как рассуждение, но собственный `mkdir -p` автора в репозиторной версии подтверждает косвенно. Отдельно и не как следствие: `tailscaled-log` (`:284`) читает `$HOME/.tailscale/tailscaled.log`, который пишет только nohup-путь (`:249`), — после сервисного старта документированная README.md:80 команда тейлит несуществующий файл.

**Фикс.** Вернуть `mkdir -p` в heredoc (или копировать репозиторный `log/run`), а `tailscaled-log` научить читать svlogd-каталог.

### 12. «Auto-start on boot» не реализован — [средне]

README.md:30 и :70 обещают автостарт при загрузке; `tailscaled-start --service=on` — это `sv-enable` + `sv up` (`build_deb.sh:157-166`). `grep -rn boot` по дереву даёт только эти две строки README: ни Termux:Boot-скрипта, ни `~/.termux/boot/`. В termux-services супервизор поднимается из `$PREFIX/etc/profile.d/start-services.sh`, то есть при открытии логин-шелла; после перезагрузки процессов Termux нет — узел офлайн, пока пользователь не откроет приложение. `sv-enable` даёт персистентность между сессиями Termux, так что перебор именно в слове «boot».

**Фикс.** «auto-start when a Termux session opens» + абзац про Termux:Boot и `termux-wake-lock`.

### 13. Параллельные сборки глотают все ошибки — [средне]

`build.sh:157-167` и `build_deb.sh:455-464`: фоновые задачи, голый `wait`, затем безусловные «Build complete!» / «All requested packages built successfully». `wait` без PID всегда 0, `set -e` (`build.sh:5`, `build_deb.sh:3`) на фоновые задачи не срабатывает — воспроизведено; `pipefail` не выставлен ни в одном из четырёх скриптов. Смягчает то, что путь `all` нигде не документирован, а CI собирает по одной архитектуре в матрице (`build.yml:24-27, 54`) и гейтит релиз на `needs: build`. Это дефект maintainer-пути.

**Фикс.** `pids+=($!)` и `for p in "${pids[@]}"; do wait "$p" || fail=1; done`, плюс `set -o pipefail`.

### 14. `tailscale-test` молча пропускает половину того, что тестирует — [средне]

README.md:55 обещает «functional test (SOCKS5 & DNS)», но обе проверки (`build_deb.sh:346`, `:351`) завёрнуты в `if [ -f "$SOCKS_ADDR_FILE" ]` (`:343`) без `else`. Файл пишет только `tailscaled-start` (`:237`), сервисный `run` — нет. На дефолтной установке тест печатает `[+] Authenticated. IP: …`, разделитель и выходит с 0, ни разу не тронув SOCKS; реально слушающий 1055 не упоминается. Хуже: `tailscaled-stop` файл удаляет (`:271`), а `pkill` в инсталляторах — нет, поэтому после ручного старта со случайным портом и переустановки тест долбится в протухший порт и печатает «FAILED» о рабочем прокси.

**Фикс.** Определять адрес из cmdline живого демона (или из `run`), при неизвестном — печатать явное «SOCKS5 test skipped».

### 15. Мелочи, каждая на одну-две строки правки

| Где | Что и почему |
|---|---|
| `build_deb.sh:193` | `pgrep -f "tailscaled.*$STATE_DIR"` матчит собственную cmdline хелпера: `tailscaled-start --statedir=$HOME/.tailscale` (или любой флаг с этим путём) печатает «already running» и выходит 0, ничего не запустив. Воспроизведено. Настоящий перенос в `/sdcard/ts` не ломается. |
| `build_deb.sh:233` | `${USER_ARGS[i+1]}` без проверки границ под `set -u`: `tailscaled-start --socks5-server` (опечатка) падает с `USER_ARGS[i+1]: unbound variable` вместо usage. Падает чисто, до `nohup`. |
| `remote-install.sh:37`, `build_deb.sh:369` | под `set -e` присваивание из `… \| grep -Po` уносит скрипт, поэтому написанные тобой `echo "Error: No releases found."` — мёртвый код. При rate-limit GitHub API (60/час на IP, реально на carrier-NAT) пользователь видит «Fetching latest release info…» и тишину. Лечится `\|\| true` и `curl -fsS`. |
| `install.sh:40` | `ls dist/… \| head -n 1` берёт лексикографически *меньшее*, то есть более старый пакет (`…0.2` < `…0.3`); в shallow-клоне без тегов `git describe --always` вообще даёт хеш. `install.sh:80` всё равно скажет «Complete!». |
| `README.md:29` | «Invoking `tailscale` … automatically starts the daemon» — автостарт есть только в обёртке `tailscale-cli` (`build_deb.sh:298-313`); в бинаре `tailscale` патч `fix_args_android.go:22-42` лишь подставляет `--socket`. Quick start (README.md:18) советует именно `tailscale up`. |
| `build_deb.sh:243-246` | `read -ra EXTRA_ARR <<< "$TS_EXTRA_ARGS"` не соблюдает кавычки внутри значения: `--hostname=my phone` станет двумя аргументами при любой записи. |
| `install.sh:30` | `*) TARGET_ARCH="aarch64" ;;` молча, хотя ветка через `uname` для того же случая честно падает (`:19-22`), а `build.sh:47`/`build_deb.sh:26` хотя бы печатают warning. Итог — долгая сборка и невнятная ошибка dpkg по архитектуре. |
| `check-updates.yml:41` | `${{ steps.upstream.outputs.tag }}` подставляется прямо в тело shell; значение приходит из стороннего репозитория, у job есть `contents: write` (`:8-9`). Живого эксплойта нет (trust boundary — tailscale/tailscale), но безопасный паттерн уже есть рядом: `build.yml:50-51` через `env:`. |
| `build.sh:72-75` | `if … then : fi` с комментарием про защиту от повторов: тело пустое, оба `sed` идут безусловно. Обе замены идемпотентны, вреда нет — но комментарий врёт следующему, кто добавит сюда неидемпотентную правку. |
| `build.sh:11-14`, `:19-23` | проверяется только `go`, а нужны ещё `git`, `wget`, `tar`. Без `pipefail` пайплайн на `:19` всегда 0, поэтому без git собирается фолбэк v1.96.5 (upstream сейчас v1.102.3) — после строки, начинающейся словом «Error». CI не задет (`build.yml:50-54` экспортирует `TS_VERSION`). |
| весь пакет | `LICENSE:1-2` заявляет копирайт «Tailscale Termux CLI Contributors / All rights reserved» на то, что в артефактах почти целиком код Tailscale под BSD-3, клауза 2 которого требует воспроизводить нотис в бинарных дистрибутивах. В релизном .deb нет `usr/share/doc/*/copyright`, у патчей нет SPDX-заголовков, `build.yml:83` не кладёт LICENSE в релиз. |
| оба пути запуска | `grep -rn "NO_LOGS\|TS_LOGS_DIR\|logtail"` — пусто, т.е. загрузка логов в Tailscale не выключена. Это дефолт upstream и он защитим, но в TailSocks ты его выключаешь (`appctr/daemon.go:58-61`). |
| `README.md:12`, `build_deb.sh:390` | `curl \| bash` без checksum; пакет пиннится тегом (`remote-install.sh:37,70`), а `tailscale-update` всегда тянет инсталлятор из `main` — установивший проверенную версию позже уедет на непроверенный код. `dpkg -i` идёт под uid Termux, не под root, радиус — песочница Termux (где лежит node key). SHA256SUMS в релизе стоят дёшево. |

---

## Что здесь сделано хорошо

Не для галочки — если что-то менять, это стоит сохранить.

* **Netmon-патч правильный по существу.** `fix_android_netmon.go:132+` не просто дёргает `ifconfig`: список интерфейсов из `anet.Interfaces()` (ioctl, работает на Android 11+), IPv6 — сначала `/proc/net/if_inet6`, и только потом ifconfig-фолбэк и UDPv6-проба. Аккуратная лесенка деградации, а не один хак.
* **Правильная точка вмешательства.** Патчи — отдельные `.go`-файлы, копируемые в `cmd/tailscaled` (`build.sh:67-69`), а не diff'ы по upstream-дереву; обновление апстрима почти никогда не ломает сборку. Та же причина, по которой в TailSocks у тебя 16 патч-файлов и `recreate_patches.sh`.
* **Сборка ужата осознанно:** `build.sh:88` выключает десяток ненужных на телефоне подсистем (`ts_omit_taildrop`, `ts_omit_kube`, `ts_omit_aws`, `ts_omit_ssh`…), `:137` — `-s -w`.
* **Обёртка `tailscale-cli` решает реальную боль:** подстановка `--socket` (и в бинаре через `fix_args_android.go:32-41`, и в обёртке) убирает главный вопрос новичка — «failed to connect to local tailscaled».
* **Скоупинг kill сделан почти везде правильно** — `build_deb.sh:193, 252, 270, 330` используют паттерн со `$STATE_DIR`. Несогласованы ровно два места (находка 4): привычка правильная, просто не доведена.
* **CI-каркас взрослый:** четыре архитектуры, `needs: build` перед релизом, `fail-fast: false`, версия через `inputs`. Сломаны две конкретные строки (находки 9 и 2), а не архитектура.
* **README реально полезен** — Troubleshooting, управление сервисом, таблица `.env` есть далеко не у всех подобных проектов. Проблема не в объёме доков, а в том, что часть описывает второй путь запуска (находка 3).

---

## TailSocks vs termux-cli: кому у кого занять

| Вопрос | TailSocks | termux-cli | Кому занять |
|---|---|---|---|
| Аутентификация SOCKS5 | патч `appctr/patches/02-socks5-auth.patch` + `daemon.go:105-106` | нет | **termux-cli ← TailSocks.** Патч переносится один в один; upstream такого флага не имеет. |
| Убийство демона | `RootUtils.kt:2496-2508`: `pkill -f -- "--socket=$socketPath"`, TERM → sleep → KILL | `pkill -f tailscaled` в инсталляторах | **termux-cli ← TailSocks.** Ты уже писал в комментарии, что широкий матч убивал «a Termux tailscaled»; сейчас Termux-скрипт делает это в обратную сторону. |
| Телеметрия | `daemon.go:58-61`: `TS_LOGS_DIR` + `TS_NO_LOGS_NO_SUPPORT=true` | дефолт upstream | **termux-cli ← TailSocks**, хотя бы knob в `.env` + строка в README. |
| DNS | `11-noop-dns-fallback`, `14-dns-forwarder-netstack`, `15-dnscache-static-hosts` — управляемая цепочка | жёсткий `net.DefaultResolver` → 8.8.8.8 (находка 7) | **termux-cli ← TailSocks** по подходу: DNS — фолбэк и настройка, а не подмена глобального резолвера в `init()`. |
| Конфигурация | один источник истины | два несинхронных пути запуска (находка 3) | **termux-cli ← TailSocks**: один сборщик аргументов, а не два. |
| Диагностика на чужом устройстве | root/VpnService-путь, много состояния, CLI в бэклоге | `tailscale-test`, `tailscaled-log`, `--service=status` — всё в PATH после одной команды | **TailSocks ← termux-cli.** Здесь виден минимальный набор команд, закрывающий 90% вопросов, — полезный ориентир для нерешённого CLI-бинаря в бэклоге. |
