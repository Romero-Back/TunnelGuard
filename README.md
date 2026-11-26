# TunnelGuard на macOS

TunnelGuard — локальный kill switch для обычного Claude Desktop на macOS. Он запускает Claude с отдельными сетевыми правилами, которые пропускают его соединения только через V2Pro.

## Обычный Claude Desktop на Mac

Кнопка «Запустить Claude» открывает установленный `/Applications/Claude.app` с обычным профилем пользователя. Для этого режима используются встроенный фильтр macOS PF и V2Pro. Виртуалка, прокси для трафика Claude и дополнительная песочница не требуются.

### Установка из GitHub Releases

1. Скачай ZIP для Apple Silicon, распакуй его и перенеси `TunnelGuard.app` в «Программы». Нужны установленные Claude Desktop и V2Pro. [Скачать TunnelGuard](https://github.com/Romero-Back/TunnelGuard/releases/latest).
2. Открой TunnelGuard и нажми «Настроить защиту». Подтверди установку локального фильтра в системном окне macOS. Действие требуется один раз. Оно добавляет отдельные правила для группы Claude и задачу их обновления при смене интерфейса V2Pro.
3. В настройках VPN добавь публичные IPv4 выхода своих серверов. «Авто» принимает любой адрес из списка. Для проверки одного адреса выбери его в меню. Подключи полнотуннельный профиль V2Pro и нажми «Запустить Claude».

У GitHub-сборки локальная подпись. Если macOS попросит разрешить первый запуск, вариант «Всё равно открыть» появляется в разделе «Конфиденциальность и безопасность» после попытки открыть приложение. [Инструкция Apple](https://support.apple.com/en-us/102445).

Если Claude уже открыт отдельно, закрой его перед защищённым запуском. «Проверить сеть» проверяет сетевой фильтр и текущий IPv4 выхода. «Остановить» завершает защищённый экземпляр Claude. Адреса, тема и акцентный цвет хранятся в настройках TunnelGuard на Mac.

Фильтр применяется к выделенной macOS-группе, в которой запускаются Claude и его дочерние процессы. Он разрешает исходящие IPv4 TCP и UDP только на интерфейсе V2Pro и блокирует IPv6. Системные службы macOS работают от своего имени. Границы защиты описаны в [SECURITY.md](SECURITY.md). [Ограничения PF в macOS](https://developer.apple.com/documentation/technotes/tn3165-packet-filter-is-not-api).

### Первый запуск из исходников

Нужны Xcode Command Line Tools. Собери и открой приложение, затем выполни те же действия в окне TunnelGuard.

```sh
app=$(sh Packaging/macOS/build-app.sh -c release)
open "$app"
```

GitHub Actions собирает ZIP и публикует SHA-256 для каждого тега вида `v0.4.0`. Тег должен совпадать с версией в `Packaging/macOS/TunnelGuard-Info.plist`.

## Ранее испытанный запуск Claude Desktop в VM

Бесплатный вариант запускает официальный Claude Desktop для Linux ARM64 в выделенной Debian VM через Lima 2.3 или новее. Подготовка использует пакеты Debian и подписанный репозиторий Anthropic. Гость работает отдельно от исходной macOS-сборки Claude и использует свой профиль. [Установка Claude Desktop для Linux](https://support.claude.com/en/articles/10065433-install-claude-desktop), [Lima](https://lima-vm.io/).

### Запуск из терминала

Для подготовки VM из терминала выполни один раз:

```sh
python3 -B Scripts/tunnelguard-desktop.py --prepare
```

Для проверки и запуска укажи ожидаемый публичный IP полнотуннельного VPN вместо `PUBLIC_VPN_IP`.

```sh
python3 -B Scripts/tunnelguard-desktop.py --probe --expected-egress PUBLIC_VPN_IP
python3 -B Scripts/tunnelguard-desktop.py --expected-egress PUBLIC_VPN_IP
```

Запуск выводит локальный адрес `vnc://127.0.0.1:…` и временный пароль для «Общего экрана» macOS. Оставь команду работающей во время использования Claude. Firefox для входа запускается внутри гостя и использует тот же прокси. Для завершения закрой Claude или прерви команду через `Ctrl+C`. При потере прокси ядро гостя сохраняет блокировку прямой сети.

Локальный диск и ключ Lima хранятся в `.build/desktop-lima`. На Apple Silicon VM настроена на 3 ГиБ RAM и разреженный диск до 14 ГиБ. Удаление каталога VM уничтожит её собственный профиль Claude. Запуск и сетевые ограничения проверены без реальной учётной записи. Cowork с вложенной виртуализацией и возможности, которых нет в Linux-версии, остаются вне текущего режима.

## Бесплатный запуск через V2Pro

Запускатор использует Python 3 и встроенный в macOS `sandbox-exec`. Он работает от обычного пользователя. Подключи V2Pro и начни с тестового запроса.

```sh
python3 Scripts/tunnelguard-run.py --check-v2pro
python3 -B Tests/check_free_launcher.py
```

Для запущенной команды и её дочерних процессов песочница разрешает исходящий TCP только на локальный порт прокси. Прокси принимает HTTPS CONNECT на порт 443, проверяет маршрут до каждого адреса и привязывает сокет к найденному интерфейсу V2Pro. При пропаже маршрута он отклоняет новые соединения и закрывает активные. Домены разрешаются через Cloudflare DNS over HTTPS по тому же туннелю. Cloudflare получает имена, запрошенные прокси. Прямой TCP, UDP и доступ к сокету системного DNS проверены отдельно. [Cloudflare DNS over HTTPS](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/).

Для запуска Claude Code укажи ожидаемый внешний IP из настроек своего полнотуннельного VPN-профиля или от его администратора. Подставь его вместо текста `PUBLIC_VPN_IP`. Флаг можно повторить для нескольких известных адресов, включая IPv6. Перед подключением приложений Cloudflare и ipify должны сообщить один и тот же разрешённый адрес для соответствующего семейства. Без подтверждения прокси отклоняет запрос. [Поддержка прокси в Claude Code](https://code.claude.com/docs/en/network-config#proxy-configuration), [ipify](https://www.ipify.org/), [Cloudflare trace](https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/).

```sh
python3 Scripts/tunnelguard-run.py --expected-egress PUBLIC_VPN_IP -- claude
```

В тесте установленный Claude Code обменялся HTTPS-запросом и ответом с тестовым сервером через прокси без реальной учётной записи. Этот способ охватывает команду и её обычных потомков. Нативная macOS-сборка Claude Desktop упирается в ошибку запуска песочницы Electron, поэтому для Desktop используется отдельный гостевой режим. Поддержка фонового процесса Claude Code, split tunneling и уже запущенных приложений пока отсутствует. Подробности — в [модели безопасности](SECURITY.md) и [результатах тестов](TESTING.md).

На текущем профиле V2Pro оба сервиса сообщили IPv4 даже при проверке через IPv6-сокеты. Поэтому в строгой проверке текущий профиль подтвердился для IPv4, а доступ к IPv6-назначениям заблокирован.

При подключённом V2Pro можно симулировать потерю туннеля в самом запускаторе. Для проверки на утечки при реальном обрыве нужен захват трафика на физическом интерфейсе.

## Сборка и локальная проверка профиля

```sh
swift build
python3 Tests/check_profile.py "$(swift build --show-bin-path)/tunnelguard-check-profile"
swift run tunnelguard-check-profile /path/to/sing-box.json
```

Проверка профиля работает локально и ничего не меняет в сети. Она проверяет форму описания маршрута, отсутствие дополнительных выходов и DNS через VLESS. Для первого испытания адрес VPN-сервера и DNS-сервера задаётся IP-адресом, чтобы проверку не усложняло разрешение их имён до установки туннеля. Имя для TLS можно задать в `tls.server_name`. Некоторые рабочие профили sing-box выходят за пределы этой тестовой схемы. Фактические маршруты и корректность полного конфига нужно проверять отдельно.

## Ранее собранный эксперимент с Network Extension

`TunnelGuardFilterProbe` содержит минимальный `NEFilterDataProvider`. Его тестовая политика запрещает новые соединения от бинарника с идентификатором подписи `app.tunnelguard.lab.networkprobe`. Политика рассчитана на выделенный тестовый бинарник. Соединения с нераспознанным источником пропускаются. Защиты Claude, обработки обрыва TUN и установки расширения в этой сборке пока нет.

### Лабораторная сборка

```sh
lab_dir=$(sh Packaging/macOS/build-lab.sh)
```

Скрипт собирает `TunnelGuardLab.app` с расширением `app.tunnelguard.lab.filter.systemextension` и отдельный `tunnelguard-network-probe` в каталоге, путь к которому печатает в stdout. Приложение показывает подготовленную конфигурацию фильтрации сокетов. Сборка не обращается к системным настройкам сети. Скопированная проба получает локальную ad hoc подпись с идентификатором, который проверяет фильтр.

Проба принимает транспорт, IP-адрес или имя хоста, порт и необязательный таймаут в секундах (по умолчанию 5). TCP проверяет установление соединения, для UDP нужен эхо-сервер, который вернёт отправленную датаграмму. Используй порт своего тестового сервера.

```sh
"$lab_dir/tunnelguard-network-probe" tcp 127.0.0.1 8888
"$lab_dir/tunnelguard-network-probe" udp ::1 8889 3
```

### Подпись для активации эксперимента на macOS

Выбран путь прямой установки вне Mac App Store. Нужны сертификат `Developer ID Application` с приватным ключом и два отдельных профиля `Developer ID` с включённой возможностью Network Extensions для `app.tunnelguard.lab` и `app.tunnelguard.lab.filter`. Оба профиля должны разрешать `content-filter-provider-systemextension`. В `Packaging/macOS` подготовлены соответствующие entitlements. Право `com.apple.developer.system-extension.install` указано у приложения-контейнера. [Развёртывание Network Extension на macOS](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment), [Network Extensions Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension), [System Extension Entitlement](https://developer.apple.com/documentation/bundleresources/system-extensions).

Для подписанной сборки каждый профиль помещается в `Contents/embedded.provisionprofile` своего пакета. Расширение подписывается первым, контейнер вторым, с одним Team ID, Hardened Runtime и защищёнными метками времени. Затем сборка проходит нотарификацию. Для активации macOS проверяет подпись, размещение приложения в `/Applications` и запрашивает пользовательское одобрение при необходимости. `codesign`, `notarytool` и `stapler` уже доступны через Command Line Tools на этом Mac. [Профили подписи macOS](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles), [Подпись через командную строку](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/), [Нотарификация](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution/), [Активация системных расширений](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers/).
