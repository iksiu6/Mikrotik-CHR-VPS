# Mikrotik-CHR-VPS

Instalacja **najnowszej wersji stable MikroTik RouterOS CHR (v7)** na VPS – jednym poleceniem.
Działa na VPS Nazwa.pl z Ubuntu 16.04 (i nowszych).

> ⚠️ Skrypt **kasuje cały dysk VPS** i nadpisuje go obrazem CHR.

## Instalacja (jedna komenda)

```
wget -qO- https://raw.githubusercontent.com/iksiu6/Mikrotik-CHR-VPS/main/script.sh | sudo CHR_PASSWORD='TwojeHaslo' bash
```

Skrypt sam:
- sprawdza na serwerach MikroTika, która wersja jest najnowsza w kanale stable i ją pobiera,
- wykrywa interfejs sieciowy, adres IP, bramę i dysk (nie trzeba nic edytować w `nano`),
- ustawia IP, bramę, DNS, wyłącza telnet/ftp/api i ustawia użytkownika `root` z Twoim hasłem,
- wypisuje dane logowania, czeka 10 s (Ctrl+C przerywa), zapisuje dysk i restartuje.

Jeśli nie podasz `CHR_PASSWORD`, hasło zostanie wygenerowane i wyświetlone na ekranie – **zapisz je**.

## Opcje

Zmienne wstawiasz przed `bash`, np. `sudo CHR_PASSWORD='x' CHR_DISK=/dev/sda bash`

| Zmienna | Domyślnie | Opis |
|---|---|---|
| `CHR_PASSWORD` | losowe | hasło użytkownika |
| `CHR_USER` | `root` | login |
| `CHR_CHANNEL` | `stable` | `stable`, `long-term` lub `testing` |
| `CHR_VERSION` | najnowsza | wymuszenie konkretnej wersji, np. `7.24.4` |
| `CHR_IFACE` | auto | interfejs sieciowy, np. `enp1s0` |
| `CHR_DISK` | auto | dysk docelowy, np. `/dev/vda` |
| `CHR_YES` | – | `1` = bez 10-sekundowego odliczania |

## Po instalacji

Zaloguj się przez WinBox lub SSH na adres IP VPS-a, login `root` i hasło z instalacji.
Zalecane: od razu ustaw firewall i wyłącz niepotrzebne usługi.
