#!/usr/bin/env bash
# ======================================================================
# update-pihole-admiral-allowlist.sh
# Automatically syncs rotating Admiral & Ad-Shield domains plus Stage-2
# detector bait CNAME chains (Admiral, Raptive/AdThrive, Ad-Shield,
# Clean.io, Blockthrough) into Pi-hole (v6 Antigravity or v5 Allowlist).
# ======================================================================
set -euo pipefail

ALLOWLIST_FILE="/etc/pihole/admiral-allowlist.txt"
ALLOWLIST_URI="file://${ALLOWLIST_FILE}"
GRAVITY_DB="/etc/pihole/gravity.db"
COMMENT_TAG="auto-admiral-allowlist"

GH_RAW="https://raw.githubusercontent.com"
EP_PATH="easylist/easylist/master/easyprivacy"
EP_FILE="easyprivacy_trackingservers_admiral.txt"
EL_ADSERVERS="easylist/easylist/master/easylist/easylist_adservers.txt"
UBO_PATH="LanikSJ/ubo-filters/main/filters/getadmiral-domains.txt"

UPSTREAM_URLS=(
  "${GH_RAW}/${EP_PATH}/${EP_FILE}"
  "${GH_RAW}/${UBO_PATH}"
)

# Static Stage-1/Stage-2 detector & bait domains across major providers:
# - Admiral:      getadmiral.com, aax.amazon-adsystem.com (+ CNAMEs)
# - Raptive:      ads.adthrive.com, pagead2.googlesyndication.com
# - Ad-Shield:    html-load.com, html-load.cc, content-loader.com,
#                 pleasantmelon.pro, static.criteo.net (+ CNAMEs)
# - Clean.io:     cadmus.script.ac
# - Blockthrough: btloader.com, cdn.btloader.com, api.btloader.com,
#                 ab.dns-finder.com, wb.dns-finder.com, ad-delivery.net
# - Sourcepoint:  cdn.privacy-mgmt.com
# - Google Video: imasdk.googleapis.com
BAIT_DOMAINS=(
  "getadmiral.com"
  "aax.amazon-adsystem.com"
  "ads.adthrive.com"
  "pagead2.googlesyndication.com"
  "html-load.com"
  "fb.html-load.com"
  "html-load.cc"
  "content-loader.com"
  "fb.content-loader.com"
  "cod.pleasantmelon.pro"
  "static.criteo.net"
  "cadmus.script.ac"
  "btloader.com"
  "cdn.btloader.com"
  "api.btloader.com"
  "ab.dns-finder.com"
  "wb.dns-finder.com"
  "ad-delivery.net"
  "cdn.privacy-mgmt.com"
  "imasdk.googleapis.com"
)

sql_exec() {
  if command -v pihole-FTL >/dev/null 2>&1 && \
     pihole-FTL sqlite3 --version >/dev/null 2>&1; then
    pihole-FTL sqlite3 -ni "${GRAVITY_DB}" "$1"
  elif command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "${GRAVITY_DB}" "$1"
  else
    echo "ERROR: sqlite3 not found." >&2
    exit 1
  fi
}

TMP_RAW="$(mktemp)"
TMP_DOMAINS="$(mktemp)"
TMP_FORMATTED="$(mktemp)"
trap 'rm -f "${TMP_RAW}" "${TMP_DOMAINS}" "${TMP_FORMATTED}"' EXIT

# 1. Download upstream Admiral lists
FETCHED=0
for url in "${UPSTREAM_URLS[@]}"; do
  if curl -fsSL --connect-timeout 10 --max-time 30 \
     "${url}" >> "${TMP_RAW}" 2>/dev/null; then
    printf "\n" >> "${TMP_RAW}"
    FETCHED=$((FETCHED + 1))
  fi
done

# 1b. Also extract rotating Ad-Shield domains from EasyList adservers
if curl -fsSL --connect-timeout 10 --max-time 30 \
   "${GH_RAW}/${EL_ADSERVERS}" 2>/dev/null \
   | awk '/^! ad-shield/{f=1;next} /^!/{if(f&&!/^! https:/)f=0} f' \
   >> "${TMP_RAW}"; then
  printf "\n" >> "${TMP_RAW}"
fi

if [[ "${FETCHED}" -eq 0 ]]; then
  echo "WARN: Upstream fetch failed; keeping current list." >&2
  exit 0
fi

# 2. Extract valid FQDNs (strip ABP prefixes/modifiers, skip raw IPs)
sed -e 's/^@@||//' -e 's/^||//' -e 's/\^.*$//' -e 's/\$[^\n]*$//' \
  "${TMP_RAW}" \
  | tr '[:upper:]' '[:lower:]' \
  | grep -E '^[a-z0-9]([a-z0-9_-]*[a-z0-9])?(\.[a-z0-9_-]+)+$' \
  | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' > "${TMP_DOMAINS}"

# 3. Add Stage-2 bait domains + dynamically resolve live CNAME chains
for bait in "${BAIT_DOMAINS[@]}"; do
  echo "${bait}" >> "${TMP_DOMAINS}"
  if command -v dig >/dev/null 2>&1; then
    for dns in 1.1.1.1 9.9.9.9; do
      cnames="$(dig @"${dns}" +time=3 +tries=1 +short "${bait}" \
        2>/dev/null \
        | sed -nE 's/\.$//; /^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$/p' \
        | tr '[:upper:]' '[:lower:]' || true)"
      if [[ -n "${cnames}" ]]; then
        echo "${cnames}" >> "${TMP_DOMAINS}"
        break
      fi
    done
  fi
done

sort -u -o "${TMP_DOMAINS}" "${TMP_DOMAINS}"

DOMAIN_COUNT="$(wc -l < "${TMP_DOMAINS}")"
if [[ "${DOMAIN_COUNT}" -lt 500 ]]; then
  echo "WARN: Domain count (${DOMAIN_COUNT}) too low; aborting." >&2
  exit 1
fi

# 4. Detect Pi-hole v6 (adlist.type column) vs Pi-hole v5
SQL_CHECK="SELECT COUNT(*) FROM pragma_table_info('adlist')"
SQL_CHECK="${SQL_CHECK} WHERE name='type';"
HAS_ANTIGRAVITY="$(sql_exec "${SQL_CHECK}")"

if [[ "${HAS_ANTIGRAVITY}" -ge 1 ]]; then
  sed 's/^/@@||/; s/$/^/' "${TMP_DOMAINS}" > "${TMP_FORMATTED}"

  SQL_EX="SELECT COUNT(*) FROM adlist"
  SQL_EX="${SQL_EX} WHERE address='${ALLOWLIST_URI}' AND type=1;"
  ADLIST_EXISTS="$(sql_exec "${SQL_EX}")"

  if [[ "${ADLIST_EXISTS}" -eq 0 ]]; then
    sql_exec "BEGIN TRANSACTION;
      INSERT OR IGNORE INTO adlist (address, enabled, comment, type)
      VALUES ('${ALLOWLIST_URI}', 1, '${COMMENT_TAG}', 1);
      COMMIT;"
    FORCE_RELOAD=1
  else
    FORCE_RELOAD=0
  fi

  if [[ "${FORCE_RELOAD}" -eq 1 ]] || \
     [[ ! -f "${ALLOWLIST_FILE}" ]] || \
     ! cmp -s "${TMP_FORMATTED}" "${ALLOWLIST_FILE}"; then
    install -m 0644 "${TMP_FORMATTED}" "${ALLOWLIST_FILE}"
    echo "Updated ${ALLOWLIST_FILE} (${DOMAIN_COUNT} domains)."
    pihole -g
  else
    echo "Allowlist unchanged (${DOMAIN_COUNT} domains)."
  fi
else
  cp "${TMP_DOMAINS}" "${TMP_FORMATTED}"
  if [[ ! -f "${ALLOWLIST_FILE}" ]] || \
     ! cmp -s "${TMP_FORMATTED}" "${ALLOWLIST_FILE}"; then
    install -m 0644 "${TMP_FORMATTED}" "${ALLOWLIST_FILE}"
    SQL_TMP="$(mktemp)"
    {
      echo "PRAGMA synchronous = OFF;"
      echo "BEGIN TRANSACTION;"
      echo "DELETE FROM domainlist WHERE comment='${COMMENT_TAG}';"
      awk -v c="${COMMENT_TAG}" '{
        printf "INSERT OR IGNORE INTO domainlist "
        printf "(type,domain,enabled,comment) "
        printf "VALUES (0,'\''%s'\'',1,'\''%s'\'');\n", $1, c
      }' "${ALLOWLIST_FILE}"
      echo "COMMIT;"
    } > "${SQL_TMP}"
    sql_exec "$(cat "${SQL_TMP}")"
    rm -f "${SQL_TMP}"
    echo "Synced ${DOMAIN_COUNT} domains (Pi-hole v5)."
    pihole restartdns reload-lists
  else
    echo "Allowlist unchanged (${DOMAIN_COUNT} domains)."
  fi
fi
