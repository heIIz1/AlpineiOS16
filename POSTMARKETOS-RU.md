# postmarketOS с Phosh на iPhone

AlpineiOS запускает виртуальную машину ARM64 внутри iOS-приложения. Проверено на iPhone 14 Pro с iOS 27.0. В образе есть Phosh и Settings. При установке по умолчанию выбраны Firefox, Nautilus и Console. Telegram Desktop, Mousepad и htop можно выбрать отдельно. Изображение идёт через VirtIO GPU в Metal. Звук гостя пока отключён.

## Установка из приложения

На первом экране выбери программы и нажми **Download and install**. По умолчанию образ скачивается из GitHub Releases. [Образ Phosh](https://github.com/Lumid-Off/AlpineiOS-images/releases/tag/phosh-26.06-r1) Приложение загрузит и распакует образ, а после запуска Linux установит выбранные пакеты. Пароль для `user` доступен в **Help**.

Чтобы подготовить образ для своего сервера, запусти на Mac с QEMU:

```sh
bash scripts/prepare_phosh.sh --downloadable work/PhoshRelease
python3 scripts/publish_phosh_image.py work/PhoshRelease work/PhoshAssets
```

Размести файлы из `work/PhoshAssets` рядом друг с другом. Для проверки по Wi-Fi запусти `python3 -m http.server 8765 --directory work/PhoshAssets` и введи в приложении `http://YOUR-MAC.local:8765/phosh.json`. Для публичной сборки можно задать HTTPS-адрес переменной `ALPINE_IMAGE_MANIFEST_URL` при сборке.

## Сборка и ручной импорт

Нужны Mac с Apple silicon, Xcode с поддержкой подключённого iPhone и Homebrew. На телефоне желательно иметь хотя бы 5 ГБ свободного места. Для скачивания образа и пакетов нужен интернет. Подключи iPhone к Xcode и включи режим разработчика. [Инструкция Apple](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

```sh
brew install qemu xcodegen meson ninja pkg-config python
bash scripts/prepare_phosh.sh

export ALPINE_BUNDLE_ID=com.example.alpineios
ALPINE_DEVELOPMENT_TEAM=YOUR_TEAM_ID bash scripts/build_alpine_ios.sh
xcrun devicectl list devices
xcrun devicectl device install app --device YOUR_IPHONE_UDID \
  build/DerivedData/Build/Products/Release-iphoneos/WindowsiOS.app
```

Открой приложение один раз. В «Файлах» или Finder открой **AlpineiOS** и при необходимости создай папку `Machines/PostmarketOS-Native`. Скопируй туда `code.fd`, `vars.fd`, `seed.img` и один из файлов `alpine.hvsparse` или `alpine.img` из `work/PostmarketOS-Native`.

Разблокируй iPhone и запусти приложение с JIT через Mac.

```sh
bash scripts/launch_on_iphone.sh YOUR_IPHONE_UDID "$ALPINE_BUNDLE_ID"
```

После завершения процесса приложения iOS команду нужно повторить. Для входа в консоль используй `user` и сгенерированный пароль из `work/PostmarketOS-Native/login.txt`. Для администрирования используй `doas -s`.

## Управление

- Свайп вверх двумя пальцами внутри рабочей области открывает список приложений Phosh.
- Тап тремя пальцами показывает меню приложения с кнопкой **Apps**, консолью, клавиатурой, коррекцией поворота тача и выключением Linux.
- Свайп от нижнего края возвращает на экран iOS.

Лицензия и авторство указаны в [LICENSE](LICENSE) и [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).


## Данные iPhone внутри Linux

Модель телефона передаётся через SMBIOS и доступна в /sys/class/dmi/id/product_name. Имя известного чипа находится в product_version и SMBIOS type 4. Заряд и состояние зарядки доступны через стандартные устройства /sys/class/power_supply/BAT0 и AC0. Их читает UPower, которым пользуется Phosh.

На экранах ProMotion приложение запрашивает частоту до 120 Гц. Linux получает режимы 120 и 60 Гц. Фактическая частота зависит от состояния iOS и нагрузки виртуальной машины.
