# Встроенный WiFi AIC8800D40 на Allwinner H618 (Armbian / ophub 6.18) — фикс и точка доступа 802.11ac WPA2

> Запуск встроенного WiFi **AIC8800D40** (802.11ac / WiFi 5, 5 ГГц, одна антенна) на TV-боксах
> Allwinner **H616/H618** (Vontar H618 / X98H и аналоги) под **Armbian с ядром ophub 6.18.x**, и
> подъём из него точки доступа WPA2.

## TL;DR

Чип рабочий. Чистый образ Armbian/ophub не поднимает `wlan0` по **трём независимым причинам** —
у каждой свой симптом в `dmesg`, чинить надо все:

1. **Неправильный firmware-блоб** — штатная firmware заливается, но не бутится
   (`rd_version=00000000`, `8800d80 wifi start fail`, `data error` **нет**). Фикс: родная
   Android-firmware устройства (`fmacfw_8800d80_u02.bin` md5 `48c3e1db`).
2. **DTB `mmc1 max-frequency` завышен (150 МГц)** — device-tree ophub Vontar-H618 разрешает
   SDIO-шине 150 МГц, контроллер поднимает 50 МГц, и заливка firmware ломается
   (`sunxi-mmc: data error`). Это и есть настоящая причина «sunxi-mmc», **а не** тюнинг
   контроллера. Фикс: ограничить mmc1 до **25 МГц** (`ap-config/aic-dtb-25mhz.sh`).
   (`FEATURE_SDIO_CLOCK=150` в драйвере — это *запрос*, а не установка; реальная частота =
   `min(DTB max-frequency, запрос)`, и 25 МГц — рабочая.)
3. **Нет драйвера** — AIC8800 SDIO out-of-tree, в чистом ophub-образе отсутствует. Ничто не
   пробует чип. Фикс: портированный драйвер (prebuilt под `6.18.37-ophub` или пересборка).

Плюс регуляторный домен 5 ГГц (RU) + `hostapd` для AC WPA2 AP.

> **⚠️ Известные готчи (автоматически закрываются `INSTALL.sh`):**
> - **`sunxi-mmc data error`** на чистой установке = DTB-клок завышен → `aic-dtb-25mhz.sh` + ребут.
> - Системный **`wpa_supplicant`** перехватывает `wlan0` раньше `hostapd`; **hostapd по умолчанию
>   masked** в Debian; **HT40-scan на AIC8800 падает** → использовать HT20. `INSTALL.sh` закрывает
>   всё это и поднимает DHCP/DNS/NAT. Ручная настройка — [docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md).

**Результат:** рабочая точка доступа 5 ГГц 802.11ac WPA2 — DHCP, DNS и NAT-интернет для
клиентов. Ожидаемая скорость ~70-90 Мбит/с на приём (потолок 1T1R SDIO PHY — это не баг;
для большего используйте 2×2 USB-свисток).

```bash
git clone https://github.com/skvarovski/Armbian-aic8800D40-wifi-driver-kernel-6.18
cd Armbian-aic8800D40-wifi-driver-kernel-6.18
# 1. скачать firmware из Release и распаковать в firmware/
# 2. установка (дефолты: SSID=AIC8800D40-AP, пароль=ChangeMe12345, канал 36)
./ap-config/INSTALL.sh
# или свои значения:
#   SSID=MyAP PASS=supersecret CHANNEL=36 AP_IP=192.168.43.1 ./ap-config/INSTALL.sh
iw dev wlan0          # → interface wlan0, type AP, ssid AIC8800D40-AP, 5 ГГц
```

## Симптомы (вероятно вы сюда попали из поиска)

**Режим A — неправильная firmware** (`rd_version=0`, `data error` нет):
```
aicbsp: aicbsp_sdio_probe:1 vid:0xC8A1  did:0x0082
aicbsp: aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fmacfw_8800d80_u02.bin
rd_version_val=00000000
8800d80 wifi start fail          # ← со штатной firmware-блобом
```

**Режим B — DTB SDIO-клок завышен** (`data error`; на чистой ophub-установке, когда firmware уже
правильная):
```
aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fw_patch_table_8800d80_u02.bin
sunxi-mmc 4021000.mmc: data error, sending stop command   ← шина на 50 МГц, передача ломается
aicwf_sdio_send_pkt fail-110
```

В обоих случаях: `wlan0` нет, AP нет. Режим A = firmware не бутится (файл не тот). Режим B = сама
SDIO-передача повредилась (шина слишком быстрая). Разные причины — разные фиксы (см. ниже).

## Корневая причина

* **Неправильный firmware-блоб** (режим A). `fmacfw_8800d80_u02.bin` из пакетов Armbian/ophub не
  бутит эту ревизию кремния (`chip rev: 7`). Родная Android-firmware устройства — бутит. Имена
  firmware-файлов содержат `d80` — нейминг вендора/драйвера; сам **чип** — AIC8800D40.
* **DTB `mmc1 max-frequency` завышен** (режим B). Device-tree ophub Vontar-H618 ставит WiFi SDIO-слот
  на 150 МГц. Драйвер просит 150, контроллер поднимает шину на **50 МГц** (SD high-speed), большие
  firmware-передачи ломаются → `sunxi-mmc: data error`. Ограничение mmc1 до **25 МГц** чинит это.
  (`FEATURE_SDIO_CLOCK=150` в драйвере — запрос, а не установка; реально крутится
  `min(DTB max-frequency, запрос)`; 25 МГц — рабочая частота.)
* **Нет драйвера** — out-of-tree, в чистом ophub-образе отсутствует. Чип никто не пробует.

Подробный разбор → [docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md). Таблица симптом→диагноз →
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Подтверждённое железо

| | |
|---|---|
| Плата | Vontar H618 / класс X98H (Allwinner H616/H618) |
| WiFi/BT | **AIC8800D40**, SDIO (`vid 0xc8a1 / did 0x0082`), chip rev 7, одна антенна (1T1R) |
| Возможности | 802.11a/b/g/n/ac (5 ГГц, VHT, ~390 Мбит/с PHY), AP + STA |
| ОС | Armbian (Debian/trixie) с ядром **ophub 6.18.37** |

## Быстрый старт (turnkey)

Требования: бокс уже под ophub 6.18.37 Armbian, установлены заголовки ядра
(`/lib/modules/$(uname -r)/build`), после загрузки драйвера появляется `wlan0`. Доступ в интернет
для `apt install hostapd dnsmasq`.

```bash
git clone https://github.com/skvarovski/Armbian-aic8800D40-wifi-driver-kernel-6.18 && cd Armbian-aic8800D40-wifi-driver-kernel-6.18
# Firmware: скачать последний Release-asset (aic8800D40-firmware.tar.gz),
#           распаковать в ./firmware/ (чтобы .bin лежали там).
#           Сверка: sha256sum -c firmware/SHA256SUMS
SSID=MyAP PASS=ChangeMe12345 CHANNEL=36 AP_IP=192.168.43.1 ./ap-config/INSTALL.sh
```

`INSTALL.sh` идемпотентен: ставит prebuilt-модули под `6.18.37-ophub`, раскладывает firmware по всем
путям загрузчика, выставляет regdom RU, ставит hostapd/dnsmasq, маскирует `wpa_supplicant`,
отключает `systemd-resolved`, ставит drop-in для авто-рестарта hostapd + NAT-скрипт, настраивает
DHCP+DNS+NAT и стартует AP. После: `iw dev wlan0` покажет `type AP`, а клиенты получат DHCP + DNS +
интернет.

> Другое ядро? Prebuilt `.ko` совпадает только с `6.18.37-ophub` (vermagic). Под любое другое ядро —
> пересоберите драйвер из исходников: [docs/BUILD-DRIVER.md](docs/BUILD-DRIVER.md).

## Firmware
<a name="firmware"></a>

Рабочая firmware **проприетарна** (вендор AICSEMI/ArtinChip), поэтому **не** коммитится в дерево
репо. Возьмите её одним из способов:

* **(просто)** Скачать `aic8800D40-firmware.tar.gz` со страницы **Releases** этого репо. Проверить:
  `firmware/SHA256SUMS`.
* **(чисто / легально / любой бокс)** Извлечь самим из дампа Android-eMMC своего устройства — см.
  [firmware/FIRMWARE-EXTRACTION.md](firmware/FIRMWARE-EXTRACTION.md). Метод работает для любого
  бокса AIC8800D40, если bundled-firmware отличается.

Если вы — правообладатель firmware и хотите убрать Release-asset, откройте issue.

## Настройка AP

Дефолты (переопределяются через env в `INSTALL.sh` или правкой `/etc/hostapd/hostapd.conf` после):

| Параметр | По умолчанию |
|---|---|
| SSID | `AIC8800D40-AP` |
| Пароль WPA2 | `ChangeMe12345` |
| Диапазон / канал | 5 ГГц / 36 |
| Режим | 802.11ac (HT20, WPA2-PSK/CCMP) — HT40-scan падает на AIC8800, см. [ROOT-CAUSE.md §3](docs/ROOT-CAUSE.md) |
| IP AP / DHCP | `192.168.43.1/24`, DHCP `.10–.50` |

Пакет поднимает **WiFi AP с полным интернетом для клиентов**: DHCP + DNS через `dnsmasq`
(forward на `1.1.1.1` / `8.8.8.8`), NAT через `iptables` MASQUERADE (WAN определяется динамически).
Каптивный портал — out of scope, добавляйте свой при необходимости.

## Состав

```
driver/prebuilt-6.18.37-ophub/   # готовые aic8800_bsp.ko + aic8800_fdrv.ko (ophub 6.18.37)
driver/patches/                  # порт на 6.18 (cfg80211 wdev, timer API, запрос клока 150 МГц, ...)
driver/build.sh                  # пересборка под своё ядро (upstream LYU4662 + патчи)
firmware/SHA256SUMS              # сверка Release-asset'а firmware
firmware/FIRMWARE-EXTRACTION.md # извлечение firmware из своего Android-дампа
ap-config/aic-dtb-25mhz.sh       # ★ патч DTB: mmc1 WiFi 150 МГц → 25 МГц (чинит sunxi-mmc data error)
ap-config/                        # hostapd.conf (HT20), dnsmasq, NAT, hostapd retry drop-in, INSTALL.sh
docs/                             # ROOT-CAUSE, BUILD-DRIVER, TROUBLESHOOTING
```

## Благодарности и ссылки

* **LYU4662/aic8800-sdio-linux-1.0** — база драйвера (SDIO, base+D80 процедура).
* **Документация ArtinChip по aic8800D40L** — подтвердила, что тот же чип (`rev 7`, SDIO `0x0082`)
  работает с 150 МГц + корректным firmware-блобом.
* **NickAlilovic/build** — патч device-tree для X98H подтвердил распайку питания/pwrseq WiFi.

## Лицензия

GPL-2.0 для кода/скриптов/документации (см. [LICENSE](LICENSE)). Firmware-блобы — собственность
вендора, выложены как Release-asset для удобства.
