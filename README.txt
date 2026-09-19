# openfm-cli

![open.fm](https://reklama.wp.pl/files/5kyk1vkeekwdx2taw1js/openfm_logo.png)

Skrypt Bash do odtwarzania stacji radiowych z [open.fm](https://open.fm) w terminalu za pomocą VLC (cvlc).

---

## Opis

`openfm-cli` to narzędzie wiersza poleceń, które umożliwia odtwarzanie dowolnych stacji radiowych z serwisu open.fm bezpośrednio w terminalu. Skrypt wykorzystuje VLC w trybie konsoli (`cvlc`) oraz `tmux` do zarządzania sesjami w tle, dzięki czemu muzyka gra nawet po odłączeniu od terminala.

**Główne funkcjonalności:**

- Odtwarzanie dowolnej stacji z open.fm w tle
- Pełna lista stacji z automatycznym cache'owaniem (odświeżanie co 7 dni)
- Wyszukiwanie i interaktywny wybór stacji (z obsługą `fzf`)
- Automatyczny reconnect przy zerwaniu połączenia
- Autostart ostatnio granej stacji przy logowaniu (systemd)
- Logowanie błędów i aktywności do plików

---

## Wymagania

- `curl` - pobieranie listy stacji i tokenów streamu
- `vlc` (konkretnie `cvlc`) - odtwarzanie strumieni audio
- `tmux` - zarządzanie sesjami w tle

### Instalacja zależności (Debian/Ubuntu)

```bash
sudo apt update && sudo apt install -y curl vlc tmux
```

---

## Instalacja

### Sposób 1: Instalacja systemowa

```bash
chmod +x openfm.sh
sudo ./openfm.sh --install
```

Po instalacji skrypt będzie dostępny globalnie jako komenda `openfm`.

### Sposób 2: Uruchomienie bezpośrednie

```bash
chmod +x openfm.sh
./openfm.sh trance
```

---

## Użycie

| Komenda | Opis |
|---------|------|
| `openfm <slug>` | Odtwarza stację w tle (np. `openfm trance`) |
| `openfm <slug> --url-only` | Wypisuje tylko URL streamu (do VLC, MPV itp.) |
| `openfm --attach` | Podłącza się do aktualnie grającej sesji |
| `openfm --stop` | Zatrzymuje odtwarzanie |
| `openfm --resume` | Wznawia ostatnio graną stację |
| `openfm --status` | Pokazuje, co aktualnie gra |
| `openfm --nowplaying [slug]` | Pokazuje wykonawcę i tytuł aktualnie granego utworu (domyślnie: stacja z `--status`) |
| `openfm --list` | Pokazuje pełną listę dostępnych stacji |
| `openfm --list <fraza>` | Szuka stacji po nazwie/slug (np. `openfm --list rock`) |
| `openfm --logs [N]` | Pokazuje ostatnie N linii logu (domyślnie 50) |
| `openfm --refresh` | Wymusza odświeżenie listy stacji z open.fm |
| `openfm --help` | Pokazuje pełną pomoc |

---

## Dostępne stacje

Pełną listę stacji można wyświetlić komendą:

```bash
openfm --list
```

**Popularne kategorie:**

| Kategoria | Przykładowe stacje |
|-----------|---------------------|
| Trance/Electronic | `trance`, `elektronika`, `house`, `edm-anthems` |
| Rock/Metal | `rock-pl`, `polski-rock`, `classic-rock`, `giganci-rocka` |
| Hip-Hop/Rap | `hip-hop-pl`, `polski-rap`, `trap-pl` |
| Pop/Hity | `100-hits`, `500-hits`, `1001-hits`, `hity-na-caly-dzien` |
| Chill/Relax | `chill`, `chillout`, `spokoj`, `piano-chill` |
| Klasyki | `lata-80`, `lata-90`, `classic-hits` |
| Polskie stacje | `eska2`, `radio-zet`, `rmf24`, `rmf-classic` |

---

## Sterowanie sesją tmux

- **Ctrl+B, D** - Odłącz od sesji (muzyka dalej leci w tle)
- **Ctrl+C** - Zatrzymaj odtwarzanie (w sesji tmux)

---

## Autostart

Możliwość automatycznego wznawiania ostatnio granej stacji przy logowaniu do systemu:

```bash
# Włącz autostart
openfm --autostart on

# Wyłącz autostart
openfm --autostart off
```

---

## Pliki konfiguracyjne

| Plik | Opis |
|------|------|
| `~/.cache/openfm-cli/stations.tsv` | Cache listy stacji (format: slug TAB id TAB nazwa) |
| `~/.cache/openfm-cli/last_station` | Ostatnio grana stacja |
| `~/.cache/openfm-cli/logs/openfm_*.log` | Logi aktywności i błędów |

---

## Rozwiązywanie problemów

### Stacja nie gra?

1. Sprawdź, co gra:
   ```bash
   openfm --status
   ```
2. Zobacz logi:
   ```bash
   openfm --logs 20
   ```
3. Odśwież listę stacji:
   ```bash
   openfm --refresh
   ```
4. Zrestartuj sesję:
   ```bash
   openfm --stop && openfm trance
   ```

### Błąd "Brak stacji o slug X"?

- Sprawdź poprawność nazwy:
  ```bash
  openfm --list
  ```
- Odśwież cache:
  ```bash
  openfm --refresh
  ```

### Błąd VLC (cvlc)?

- Zainstaluj VLC:
  ```bash
  sudo apt install vlc
  ```
- Sprawdź, czy `cvlc` działa:
  ```bash
  cvlc --version
  ```

---

## Licencja

MIT - używaj, modyfikuj, rozprowadzaj swobodnie.

---

## Autor

Paweł (Paffcio)

---

## Współpraca

Jeśli znajdziesz błędy lub masz pomysły na ulepszenia, zgłoś Issue lub Pull Request.
