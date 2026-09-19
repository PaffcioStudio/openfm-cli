#!/bin/bash
#
# openfm-play.sh — odtwarza dowolną stację z open.fm w VLC
#
# Użycie:
#   ./openfm-play.sh trance
#   ./openfm-play.sh "smooth-jazz"
#
# Jeśli nie znasz sluga stacji, uruchom bez argumentów albo z --list
# żeby zobaczyć/wyszukać dostępne stacje.
#VERSION=1.0.0

set -euo pipefail

if [ "${1:-}" == "--version" ]; then
    echo "1.0.0"
    exit 0
fi

INSTALL_PATH="/usr/local/bin/openfm"

# --- Tryb: instalacja / deinstalacja ---
if [ "${1:-}" == "--install" ]; then
    SELF="$(readlink -f "$0")"
    echo "Instaluję jako '${INSTALL_PATH}' (poproszę o hasło sudo)..." >&2
    sudo cp -- "$SELF" "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"
    echo "Zainstalowano. Odpal teraz po prostu: openfm <slug-stacji>" >&2
    exit 0
fi

if [ "${1:-}" == "--uninstall" ]; then
    if [ ! -e "$INSTALL_PATH" ]; then
        echo "'${INSTALL_PATH}' nie istnieje, nic do usunięcia." >&2
        exit 0
    fi
    echo "Usuwam '${INSTALL_PATH}' (poproszę o hasło sudo)..." >&2
    sudo rm -f -- "$INSTALL_PATH"
    echo "Odinstalowano." >&2
    exit 0
fi

UA="Mozilla/5.0 (X11; Linux x86_64; rv:153.0) Gecko/20100101 Firefox/153.0"
CACHE_DIR="${HOME}/.cache/openfm-play"
STATIONS_FILE="${CACHE_DIR}/stations.tsv"
LAST_STATION_FILE="${CACHE_DIR}/last_station"
STATIONS_MAX_AGE_DAYS=7

LOG_DIR="${CACHE_DIR}/logs"
LOG_FILE="${LOG_DIR}/openfm_$(date '+%Y-%m-%d').log"
LOG_MAX_AGE_HOURS=48

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SYSTEMD_UNIT_NAME="openfm-autostart.service"
SYSTEMD_UNIT_FILE="${SYSTEMD_USER_DIR}/${SYSTEMD_UNIT_NAME}"

TMUX_SESSION="openfm"

mkdir -p "$CACHE_DIR" "$LOG_DIR"

# Zapisuje linię do dzisiejszego pliku logu z timestampem, np:
# [2026-08-22 10:03:11] [PID 12345] Odtwarzam: https://...
log() {
    printf '[%s] [PID %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >> "$LOG_FILE"
}

# Usuwa pliki logów starsze niż LOG_MAX_AGE_HOURS godzin (domyślnie 48h)
cleanup_old_logs() {
    find "$LOG_DIR" -maxdepth 1 -name 'openfm_*.log' -type f \
        -mmin "+$(( LOG_MAX_AGE_HOURS * 60 ))" -delete 2>/dev/null || true
}

cleanup_old_logs

# Mapowanie: polecenie -> nazwa pakietu apt (bo cvlc jest w pakiecie 'vlc', nie 'cvlc')
declare -A REQUIRED_DEPS=(
    [curl]="curl"
    [cvlc]="vlc"
    [tmux]="tmux"
)

check_dependencies() {
    local missing_cmds=()
    local missing_pkgs=()
    local cmd pkg

    for cmd in "${!REQUIRED_DEPS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
            missing_pkgs+=("${REQUIRED_DEPS[$cmd]}")
        fi
    done

    if [ "${#missing_cmds[@]}" -eq 0 ]; then
        return 0
    fi

    echo "Brakuje wymaganych programów: ${missing_cmds[*]}" >&2
    echo "Trzeba zainstalować pakiety: ${missing_pkgs[*]}" >&2
    read -r -p "Zainstalować teraz przez apt? [t/n] " ANSWER

    case "$ANSWER" in
        [tTyY])
            echo "Instaluję (poproszę o hasło sudo)..." >&2
            sudo apt update
            sudo apt install -y "${missing_pkgs[@]}"
            ;;
        *)
            echo "Bez tych programów skrypt nie zadziała poprawnie. Kończę." >&2
            exit 1
            ;;
    esac

    for cmd in "${missing_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Błąd: '$cmd' nadal niedostępny po instalacji. Sprawdź ręcznie." >&2
            exit 1
        fi
    done

    echo "Zależności zainstalowane." >&2
}

require_tmux() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo "Błąd: 'tmux' nie jest zainstalowany. Zainstaluj go: sudo apt install tmux" >&2
        exit 1
    fi
}

session_running() {
    command -v tmux >/dev/null 2>&1 && tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

# Pobiera świeży, podpisany URL streamu dla STATION_CODE ustawionego przez wołającego
get_stream_url() {
    local fp token_response http_code url tmp_body

    fp="https://stream-cdn-1.open.fm/${STATION_CODE}/ngrp:standard/playlist.m3u8"

    tmp_body="$(mktemp)"
    http_code=$(curl -s -o "$tmp_body" -w '%{http_code}' \
        "https://open.fm/api/user/token?fp=${fp}" \
        -H "User-Agent: $UA" \
        -H 'Referer: https://open.fm/') || http_code="curl_error"
    token_response="$(cat "$tmp_body")"
    rm -f "$tmp_body"

    if [ "$http_code" != "200" ]; then
        echo "Błąd: API tokenu open.fm zwróciło HTTP ${http_code} dla stacji ${STATION_CODE}." >&2
        echo "$token_response" >&2
        log "BŁĄD: API tokenu zwróciło HTTP ${http_code} dla STATION_CODE=${STATION_CODE}. Treść: ${token_response}"
        return 1
    fi

    url=$(echo "$token_response" | grep -oE 'https://stream-cdn[^"]*')

    if [ -z "$url" ]; then
        echo "Błąd: nie udało się uzyskać URL streamu. Odpowiedź serwera:" >&2
        echo "$token_response" >&2
        log "BŁĄD: brak URL streamu dla STATION_CODE=${STATION_CODE}. Odpowiedź API (HTTP ${http_code}): ${token_response}"
        return 1
    fi

    echo "$url"
}

# Wyciąga "artysta - tytuł" aktualnie granego utworu z wyrenderowanej strony
# open.fm/stacje-muzyczne/<slug>. Strona to Next.js SSR, żadne API JSON nie
# niesie tej informacji (nowPlaying w __NEXT_DATA__ jest zawsze null) — dane
# siedzą tylko w wyrenderowanym HTML, w bloku <ul class="playSoon">.
get_now_playing() {
    local slug="$1" html now_playing_html artist title

    html=$(curl -s -A "$UA" "https://open.fm/stacje-muzyczne/${slug}") || {
        echo "Błąd: nie udało się pobrać strony stacji." >&2
        log "BŁĄD: nie udało się pobrać strony open.fm dla now-playing, slug='${slug}'"
        return 1
    }

    if [ -z "$html" ]; then
        echo "Błąd: pusta odpowiedź ze strony open.fm." >&2
        log "BŁĄD: pusta strona open.fm dla now-playing, slug='${slug}'"
        return 1
    fi

    # Pierwszy <li> w playSoon zawiera "Teraz gra:" jako ukryty span,
    # a treść w <strong>: <b>Artysta</b> - Tytuł
    # [^<]* zamiast .*? -- grep -E nie wspiera leniwych kwantyfikatorow,
    # wiec .*? lapalby chciwie az do OSTATNIEGO </strong> na calej stronie
    now_playing_html=$(echo "$html" | grep -oE '<span class="visuallyhidden">Teraz gra:</span><strong><b>[^<]*</b>[^<]*</strong>' | head -1)

    if [ -z "$now_playing_html" ]; then
        echo "Błąd: nie znaleziono bloku \"Teraz gra\" na stronie stacji." >&2
        echo "Strona mogła zmienić układ albo stacja '${slug}' nie ma tej sekcji." >&2
        log "BŁĄD: brak bloku 'Teraz gra' dla slug='${slug}' (strona mogła się zmienić)"
        return 1
    fi

    artist=$(echo "$now_playing_html" | grep -oE '<b>[^<]*</b>' | sed -E 's/<\/?b>//g')
    title=$(echo "$now_playing_html" | sed -E 's/.*<\/b> - //; s/<\/strong>$//')

    # Odkodowanie encji HTML. &amp; musi być na końcu, żeby nie popsuć
    # innych encji zaczynających się od "&" (np. najpierw &#x27; -> ',
    # dopiero potem ewentualne &amp; -> &).
    decode_entities() {
        sed -e "s/&#x27;/'/g" -e "s/&#039;/'/g" -e "s/&#39;/'/g" \
            -e 's/&quot;/"/g' -e 's/&#x22;/"/g' \
            -e 's/&lt;/</g' -e 's/&gt;/>/g' \
            -e 's/&nbsp;/ /g' \
            -e 's/&#x2013;/-/g' -e 's/&#8211;/-/g' \
            -e 's/&#x2019;/'"'"'/g' -e 's/&#8217;/'"'"'/g' \
            -e 's/&amp;/\&/g'
    }
    artist=$(echo "$artist" | decode_entities)
    title=$(echo "$title" | decode_entities)

    if [ -z "$artist" ] && [ -z "$title" ]; then
        echo "Błąd: nie udało się rozdzielić artysty i tytułu." >&2
        log "BŁĄD: parsing artysta/tytuł nieudany dla slug='${slug}'"
        return 1
    fi

    printf '%s - %s\n' "$artist" "$title"
}

# --- Tryb: dołącz do aktualnie grającej sesji ---
if [ "${1:-}" == "--attach" ]; then
    require_tmux
    if ! session_running; then
        echo "Nic teraz nie gra." >&2
        exit 1
    fi
    echo "Odłącz się bez zabijania: Ctrl+B, potem D. Ctrl+C zatrzyma granie." >&2
    sleep 1
    exec tmux attach -t "$TMUX_SESSION"
fi

# --- Tryb: zatrzymaj aktualnie grającą sesję ---
if [ "${1:-}" == "--stop" ]; then
    require_tmux
    if ! session_running; then
        echo "Nic teraz nie gra." >&2
        exit 0
    fi
    log "Zatrzymuję sesję na żądanie użytkownika (--stop)"
    tmux kill-session -t "$TMUX_SESSION"
    echo "Zatrzymano." >&2
    exit 0
fi

# --- Tryb: status ---
if [ "${1:-}" == "--status" ]; then
    if session_running; then
        CURRENT="$(cat "$LAST_STATION_FILE" 2>/dev/null || echo "?")"
        echo "Gra: $CURRENT" >&2
        if command -v curl >/dev/null 2>&1; then
            NOW_PLAYING="$(get_now_playing "$CURRENT" 2>/dev/null)" || NOW_PLAYING=""
            if [ -n "$NOW_PLAYING" ]; then
                echo "Teraz gra: $NOW_PLAYING" >&2
            fi
        fi
    else
        echo "Nic teraz nie gra." >&2
    fi
    
    # Stan autostartu
    if [ -f "$SYSTEMD_UNIT_FILE" ] && systemctl --user is-enabled --quiet "$SYSTEMD_UNIT_NAME" 2>/dev/null; then
        echo "Autostart: włączony" >&2
    else
        echo "Autostart: wyłączony" >&2
    fi
    echo "Podłącz się: openfm --attach" >&2
    exit 0
fi

# --- Tryb: pokaż aktualnie grany utwór (tytuł i wykonawcę) ---
if [ "${1:-}" == "--nowplaying" ]; then
    SLUG_NP="${2:-}"

    if [ -z "$SLUG_NP" ]; then
        if [ ! -s "$LAST_STATION_FILE" ]; then
            echo "Nie wiadomo jaka stacja gra. Podaj slug: openfm --nowplaying <slug>" >&2
            echo "Albo najpierw odpal stację: openfm <slug>" >&2
            exit 1
        fi
        SLUG_NP="$(cat "$LAST_STATION_FILE")"
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Błąd: 'curl' nie jest zainstalowany. Zainstaluj go: sudo apt install curl" >&2
        exit 1
    fi

    NOW_PLAYING=$(get_now_playing "$SLUG_NP") || exit 1
    echo "$NOW_PLAYING"
    exit 0
fi

# --- Tryb: pokaż ostatnie logi ---
if [ "${1:-}" == "--logs" ]; then
    N="${2:-50}"
    if ! [[ "$N" =~ ^[0-9]+$ ]]; then
        echo "Użycie: openfm --logs [liczba-linii]" >&2
        exit 1
    fi
    # Logi z dziś + wczoraj, posortowane chronologicznie, ostatnie N linii
    cat "${LOG_DIR}/openfm_$(date '+%Y-%m-%d').log" \
        "${LOG_DIR}/openfm_$(date -d 'yesterday' '+%Y-%m-%d').log" \
        2>/dev/null | sort | tail -n "$N"
    exit 0
fi

# --- Tryb: wznów ostatnio graną stację ---
if [ "${1:-}" == "--resume" ]; then
    check_dependencies
    require_tmux
    if session_running; then
        CURRENT="$(cat "$LAST_STATION_FILE" 2>/dev/null || echo "?")"
        echo "Już gra: $CURRENT" >&2
        echo "Podłącz się: openfm --attach" >&2
        exit 0
    fi
    if [ ! -s "$LAST_STATION_FILE" ]; then
        echo "Brak zapisanej ostatnio granej stacji." >&2
        exit 1
    fi
    LAST_SLUG="$(cat "$LAST_STATION_FILE")"
    BIN_PATH="$(readlink -f "$0")"
    tmux new-session -d -s "$TMUX_SESSION" "$BIN_PATH" --_inner-play "$LAST_SLUG"
    log "Wznawiam (--resume): ${LAST_SLUG}"
    echo "Wznawiam: $LAST_SLUG" >&2
    if command -v curl >/dev/null 2>&1; then
        NOW_PLAYING="$(get_now_playing "$LAST_SLUG" 2>/dev/null)" || NOW_PLAYING=""
        if [ -n "$NOW_PLAYING" ]; then
            echo "Teraz gra: $NOW_PLAYING" >&2
        fi
    fi
    echo "Podłącz się w dowolnym terminalu: openfm --attach" >&2
    exit 0
fi

# --- Tryb: autostart on/off ---
if [ "${1:-}" == "--autostart" ]; then
    MODE="${2:-}"

    if [ "$MODE" != "on" ] && [ "$MODE" != "off" ]; then
        echo "Użycie: openfm --autostart on|off" >&2
        exit 1
    fi

    if [ "$MODE" == "off" ]; then
        systemctl --user disable --now "$SYSTEMD_UNIT_NAME" 2>/dev/null || true
        rm -f -- "$SYSTEMD_UNIT_FILE"
        systemctl --user daemon-reload
        echo "Autostart wyłączony." >&2
        exit 0
    fi

    # MODE == on
    check_dependencies
    
    # Jeśli nie ma zapisanej stacji, ustaw domyślną (trance)
    if [ ! -s "$LAST_STATION_FILE" ]; then
        DEFAULT_STATION="trance"
        echo "$DEFAULT_STATION" > "$LAST_STATION_FILE"
        log "Autostart: ustawiono domyślną stację '$DEFAULT_STATION'"
        echo "Ustawiono domyślną stację: $DEFAULT_STATION" >&2
    fi

    BIN_PATH="$(readlink -f "$0")"
    mkdir -p "$SYSTEMD_USER_DIR"

    # Upewnij się, że systemd user linger jest włączony
    if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "yes"; then
        echo "Włączam systemd user linger (potrzeba do autostartu przy logowaniu)..." >&2
        sudo loginctl enable-linger "$USER" || {
            echo "Błąd: nie udało się włączyć linger. Spróbuj ręcznie: sudo loginctl enable-linger $USER" >&2
            exit 1
        }
    fi

    # Tworzymy serwis z Type=oneshot i RemainAfterExit=yes
    cat > "$SYSTEMD_UNIT_FILE" <<EOF
[Unit]
Description=openfm - wznowienie ostatnio granej stacji
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=$BIN_PATH --_autostart-run
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "$SYSTEMD_UNIT_NAME"
    
    CURRENT_STATION="$(cat "$LAST_STATION_FILE")"
    echo "Autostart włączony. Przy logowaniu wznowi: $CURRENT_STATION" >&2
    echo "Uwaga: Jeśli autostart nie działa, upewnij się, że:" >&2
    echo "  1. systemd user jest włączony (sudo loginctl enable-linger $USER)" >&2
    echo "  2. masz zainstalowane: tmux, curl, vlc" >&2
    exit 0
fi

# --- Tryb wewnętrzny: wywoływany przez systemd przy starcie sesji ---
if [ "${1:-}" == "--_autostart-run" ]; then
    if [ ! -s "$LAST_STATION_FILE" ]; then
        # Brak zapisanej stacji - nic nie robimy, kończymy od razu, zero zjadania RAM-u
        exit 0
    fi
    require_tmux
    if session_running; then
        # coś już gra (np. zdążyłeś odpalić ręcznie zanim systemd wystartował) - nie dublujemy
        exit 0
    fi
    LAST_SLUG="$(cat "$LAST_STATION_FILE")"
    BIN_PATH="$(readlink -f "$0")"
    log "Autostart (systemd): startuję sesję tmux dla stacji '${LAST_SLUG}'"
    tmux new-session -d -s "$TMUX_SESSION" "$BIN_PATH" --_inner-play "$LAST_SLUG"
    exit 0
fi

# --- Krok 1: pobierz i odśwież listę stacji (cache na 7 dni) ---
refresh_stations() {
    echo "Pobieram aktualną listę stacji z open.fm..." >&2
    local html
    html=$(curl -s -A "$UA" "https://open.fm/stacje-muzyczne/trance")
    if [ -z "$html" ]; then
        echo "Błąd: nie udało się pobrać strony open.fm. Sprawdź połączenie internetowe." >&2
        exit 1
    fi
    # Wyciągamy id, name, slug -> zapisujemy jako TSV: slug<TAB>id<TAB>name
    echo "$html" | grep -oE '"id":[0-9]+,"name":"[^"]*","slug":"[^"]*"' \
        | sed -E 's/"id":([0-9]+),"name":"([^"]*)","slug":"([^"]*)"/\3\t\1\t\2/' \
        | sort -u -t $'\t' -k1,1 > "$STATIONS_FILE"

    local count
    count=$(wc -l < "$STATIONS_FILE")
    if [ "$count" -lt 10 ]; then
        echo "Ostrzeżenie: znaleziono tylko $count stacji, coś mogło pójść nie tak." >&2
    else
        echo "Zapisano $count stacji do cache." >&2
    fi
}

needs_refresh() {
    [ ! -f "$STATIONS_FILE" ] && return 0
    local age_days
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$STATIONS_FILE") ) / 86400 ))
    [ "$age_days" -ge "$STATIONS_MAX_AGE_DAYS" ]
}

check_dependencies

if needs_refresh; then
    refresh_stations
fi

# --- Tryb: pomoc ---
if [ "${1:-}" == "--help" ] || [ "${1:-}" == "-h" ]; then
    cat >&2 <<EOF
openfm-play.sh — odtwarza dowolną stację z open.fm w cvlc (bez GUI)

Dostępne komendy:
  openfm <slug-stacji>               odtwarza daną stację w tle (sesja tmux), np. openfm trance
  openfm <slug-stacji> --url-only    wypisuje sam URL streamu, bez odpalania cvlc
  openfm --attach                    podłącza się do aktualnie grającej sesji (Ctrl+B potem D = odłącz bez zabijania; Ctrl+C = zatrzymuje granie)
  openfm --stop                      zatrzymuje aktualnie grającą sesję
  openfm --status                    pokazuje czy coś gra, jaka to stacja i jaki utwór aktualnie leci
  openfm --nowplaying [slug]         pokazuje wykonawcę i tytuł aktualnie granego utworu (domyślnie: stacja z --status)
  openfm --logs [N]                  pokazuje ostatnie N linii logu (domyślnie 50) - przydatne gdy stacja nie gra
  openfm --resume                    wznawia ostatnio graną stację, jeśli nic teraz nie gra
  openfm                             bez argumentów: interaktywny wybór stacji przez fzf (jeśli zainstalowany), inaczej pełna lista
  openfm --list                      pokazuje pełną listę dostępnych stacji (tekstowo)
  openfm --list <fraza>              wyszukuje stacje po nazwie/slug, np. openfm --list rock
  openfm --refresh                   wymusza odświeżenie listy stacji z open.fm
  openfm --install                   instaluje skrypt jako 'openfm' w /usr/local/bin (sudo)
  openfm --uninstall                 usuwa zainstalowany 'openfm' z /usr/local/bin (sudo)
  openfm --autostart on              włącza autostart ostatnio granej stacji przy logowaniu
  openfm --autostart off             wyłącza autostart
  openfm --help, -h                  pokazuje tę pomoc

Jednocześnie może grać tylko jedna stacja (jedna sesja tmux "$TMUX_SESSION").
Żeby zmienić stację, najpierw zrób --stop, potem odtwórz nową.

Skrypt sam sprawdza czy masz curl, vlc i tmux - jeśli czegoś brakuje, zapyta
czy zainstalować przez apt (wymaga hasła sudo).

Lista stacji jest cache'owana lokalnie na $STATIONS_MAX_AGE_DAYS dni w:
  $STATIONS_FILE

Logi (start/stop, błędy tokenu, błędy cvlc, reconnecty) zapisują się do:
  $LOG_DIR/openfm_YYYY-MM-DD.log
Logi starsze niż $LOG_MAX_AGE_HOURS godzin są automatycznie usuwane przy każdym uruchomieniu.
EOF
    exit 0
fi

# --- Tryb: lista / wyszukiwanie stacji (tekstowo) ---
if [ "${1:-}" == "--list" ] || [ "${1:-}" == "-l" ]; then
    QUERY="${2:-}"
    echo "Dostępne stacje${QUERY:+ pasujące do '$QUERY'}:" >&2
    if [ -n "$QUERY" ]; then
        grep -i -- "$QUERY" "$STATIONS_FILE" | awk -F'\t' '{printf "  %-30s %s\n", $1, $3}'
    else
        awk -F'\t' '{printf "  %-30s %s\n", $1, $3}' "$STATIONS_FILE"
    fi
    echo "" >&2
    echo "Użycie: openfm <slug-stacji>   (np. openfm trance)" >&2
    echo "Pełna pomoc: openfm --help" >&2
    exit 0
fi

# --- Tryb: brak argumentów - interaktywny wybór przez fzf, jeśli dostępny ---
if [ $# -eq 0 ]; then
    if command -v fzf >/dev/null 2>&1; then
        PICKED=$(awk -F'\t' '{printf "%-30s %s\n", $1, $3}' "$STATIONS_FILE" \
            | fzf --prompt="Stacja> " --header="Enter = graj, Esc = wyjdź" --height=90% --border) || true
        if [ -z "${PICKED:-}" ]; then
            echo "Nie wybrano żadnej stacji." >&2
            exit 0
        fi
        SLUG_PICKED=$(awk '{print $1}' <<< "$PICKED")
        # Wybór przez fzf to jednoznaczna decyzja użytkownika - jeśli coś już gra, zamieniamy stację
        # zamiast odbijać się od blokady "już gra"
        if command -v tmux >/dev/null 2>&1 && session_running; then
            tmux kill-session -t "$TMUX_SESSION"
        fi
        exec "$0" "$SLUG_PICKED"
    fi

    echo "Dostępne stacje:" >&2
    awk -F'\t' '{printf "  %-30s %s\n", $1, $3}' "$STATIONS_FILE"
    echo "" >&2
    echo "Użycie: openfm <slug-stacji>   (np. openfm trance)" >&2
    echo "Pełna pomoc: openfm --help" >&2
    echo "Wskazówka: zainstaluj 'fzf' (sudo apt install fzf) dla interaktywnego wyszukiwania." >&2
    exit 0
fi

if [ "${1:-}" == "--refresh" ]; then
    refresh_stations
    exit 0
fi

INNER_PLAY=0
if [ "${1:-}" == "--_inner-play" ]; then
    INNER_PLAY=1
    shift
fi

SLUG="$1"
URL_ONLY=0
if [ "${2:-}" == "--url-only" ]; then
    URL_ONLY=1
fi

# --url-only to jednorazowe zapytanie o link, nie sesja odtwarzania - nie dotyka tmux
if [ "$INNER_PLAY" -eq 0 ] && [ "$URL_ONLY" -eq 1 ]; then
    LINE=$(grep -P -- "^${SLUG}\t" "$STATIONS_FILE" || true)
    if [ -z "$LINE" ]; then
        echo "Nie znaleziono stacji o slug '$SLUG'." >&2
        exit 1
    fi
    STATION_ID=$(echo "$LINE" | cut -f2)
    STATION_CODE="OFM${STATION_ID}"
    STREAM_URL=$(get_stream_url) || exit 1
    echo "$STREAM_URL"
    exit 0
fi

if [ "$INNER_PLAY" -eq 0 ]; then
    require_tmux
    if session_running; then
        CURRENT="$(cat "$LAST_STATION_FILE" 2>/dev/null || echo "?")"
        echo "Już gra: $CURRENT" >&2
        echo "Podłącz się: openfm --attach" >&2
        echo "Albo zatrzymaj: openfm --stop" >&2
        exit 1
    fi
    # Weryfikujemy slug PRZED utworzeniem sesji tmux, żeby literówka nie tworzyła pustej sesji
    if [ -z "$(grep -P -- "^${SLUG}\t" "$STATIONS_FILE" || true)" ]; then
        echo "Nie znaleziono stacji o slug '$SLUG'." >&2
        echo "" >&2
        echo "Podobne stacje:" >&2
        grep -i -- "$SLUG" "$STATIONS_FILE" | awk -F'\t' '{printf "  %-30s %s\n", $1, $3}' >&2
        echo "" >&2
        echo "Użyj 'openfm --list' żeby zobaczyć wszystkie dostępne stacje, albo 'openfm --help' po pełną pomoc." >&2
        log "BŁĄD: nie znaleziono stacji o slug '${SLUG}' w cache (uruchomienie z terminala)"
        exit 1
    fi
    BIN_PATH="$(readlink -f "$0")"
    tmux new-session -d -s "$TMUX_SESSION" "$BIN_PATH" --_inner-play "$SLUG"
    log "Startuję sesję tmux dla stacji '${SLUG}'"
    echo "Odtwarzanie wystartowało w tle." >&2
    if command -v curl >/dev/null 2>&1; then
        NOW_PLAYING="$(get_now_playing "$SLUG" 2>/dev/null)" || NOW_PLAYING=""
        if [ -n "$NOW_PLAYING" ]; then
            echo "Teraz gra: $NOW_PLAYING" >&2
        fi
    fi
    echo "Podłącz się w dowolnym terminalu: openfm --attach" >&2
    exit 0
fi

# --- Krok 2: znajdź numer stacji (OFM<id>) po slug ---
LINE=$(grep -P -- "^${SLUG}\t" "$STATIONS_FILE" || true)

if [ -z "$LINE" ]; then
    echo "Nie znaleziono stacji o slug '$SLUG'." >&2
    echo "" >&2
    echo "Podobne stacje:" >&2
    grep -i -- "$SLUG" "$STATIONS_FILE" | awk -F'\t' '{printf "  %-30s %s\n", $1, $3}' >&2
    echo "" >&2
    echo "Użyj 'openfm --list' żeby zobaczyć wszystkie dostępne stacje, albo 'openfm --help' po pełną pomoc." >&2
    log "BŁĄD: nie znaleziono stacji o slug '${SLUG}' w cache (inner-play)"
    exit 1
fi

STATION_ID=$(echo "$LINE" | cut -f2)
STATION_NAME=$(echo "$LINE" | cut -f3)
STATION_CODE="OFM${STATION_ID}"

echo "$SLUG" > "$LAST_STATION_FILE"

echo "Stacja: $STATION_NAME (${STATION_CODE})" >&2
log "Start odtwarzania: slug='${SLUG}' nazwa='${STATION_NAME}' kod='${STATION_CODE}'"

# --- Krok 3: pobierz świeży, podpisany URL streamu ---
STREAM_URL=$(get_stream_url) || { log "BŁĄD: nie udało się pobrać URL streamu dla '${SLUG}' - przerywam"; exit 1; }

# --- Krok 4: odpal VLC (albo wypisz sam URL, jeśli --url-only) ---
if [ "${2:-}" == "--url-only" ]; then
    echo "$STREAM_URL"
    exit 0
fi

# Pułapka na Ctrl+C: wychodzimy czysto z pętli reconnect zamiast próbować grać dalej
STOP=0
trap 'STOP=1' INT TERM

echo "Odtwarzam: $STREAM_URL" >&2
log "Odtwarzam URL: ${STREAM_URL}"

while [ "$STOP" -eq 0 ]; do
    # --intf dummy / --vout dummy: to czysty strumień audio, nie inicjalizuj video/VAAPI/VDPAU
    # --http-reconnect + --network-caching: automatyczny reconnect przy zerwaniu TLS/HTTP
    # --verbose 1 zamiast --quiet: inaczej VLC połyka błędy HTTP (np. 403) bez śladu w logach
    # (verbose 1 = błędy + ostrzeżenia, bez pełnego debug spamu jaki dałby verbose 2)
    CVLC_ERR_TMP="$(mktemp)"

    set +e
    cvlc \
        --intf dummy \
        --vout dummy \
        --no-video \
        --http-reconnect \
        --network-caching=3000 \
        --verbose 1 \
        "$STREAM_URL" \
        2> "$CVLC_ERR_TMP"
    RC=$?
    set -e

    # Pokaż na żywo i dopisz do dzisiejszego logu (zwykła redyrekcja, bez process substitution -
    # ta wersja nie gubi/nie miesza linii)
    cat "$CVLC_ERR_TMP" >&2
    cat "$CVLC_ERR_TMP" >> "$LOG_FILE"
    # Jeśli w stderr VLC pojawił się kod HTTP błędu, wyciągnij go osobno do logu - to jest
    # najważniejsza linia przy diagnozowaniu "czemu ta stacja nie gra"
    if grep -qE 'HTTP/[0-9.]+ [0-9]{3}|error.*[0-9]{3}|Forbidden|403' "$CVLC_ERR_TMP"; then
        HTTP_ERR_LINE="$(grep -E 'HTTP/[0-9.]+ [0-9]{3}|error.*[0-9]{3}|Forbidden|403' "$CVLC_ERR_TMP" | head -1)"
        log "BŁĄD HTTP z cvlc dla '${SLUG}': ${HTTP_ERR_LINE}"
    fi
    rm -f "$CVLC_ERR_TMP"

    if [ "$STOP" -eq 1 ]; then
        log "Zatrzymano na żądanie (Ctrl+C / --stop) dla stacji '${SLUG}'"
        break
    fi

    if [ "$RC" -eq 0 ]; then
        # cvlc wyszedł czysto sam z siebie (np. koniec streamu) - traktujemy to jak sygnał do reconnectu
        echo "cvlc zakończył się bez błędu, próbuję wznowić..." >&2
        log "cvlc zakończył się kodem 0 dla '${SLUG}' (nieoczekiwany koniec streamu), próbuję wznowić"
    else
        echo "cvlc padł (kod $RC), pobieram nowy token i wznawiam za 3s..." >&2
        log "BŁĄD: cvlc padł z kodem ${RC} dla '${SLUG}', wznawiam za 3s"
    fi

    sleep 3

    NEW_URL=$(get_stream_url) || { echo "Nie udało się odświeżyć URL, kończę." >&2; log "BŁĄD KRYTYCZNY: nie udało się odświeżyć URL dla '${SLUG}', kończę"; exit 1; }
    STREAM_URL="$NEW_URL"
    echo "Wznawiam: $STREAM_URL" >&2
    log "Wznawiam z nowym URL: ${STREAM_URL}"
done

echo "Zatrzymano." >&2
