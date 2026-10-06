#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ColdBox — installation en UNE commande sur une machine Linux neuve
# ─────────────────────────────────────────────────────────────────────────────
# Télécharge la dernière version publiée (dépôt privé, clé personnelle du client),
# vérifie son empreinte, la décompresse dans /opt/coldbox puis lance l'installateur
# mono-client avec les options données.
#
#   curl -fsSL -H "Authorization: Bearer CLE" \
#     https://raw.githubusercontent.com/yssab2000/coldbox-saas/feat/mono-client/scripts/get.sh \
#     | sudo COLDBOX_KEY=CLE bash -s -- \
#         --company "Nom du client" --email admin@client.dz --host froid.client.dz --tls letsencrypt
#
# Version courte, via la page publique (https://yssab2000.github.io/coldbox-install/ génère la commande) :
#   sudo apt-get update -qq && sudo apt-get install -y -qq curl ca-certificates   # si curl manque (Debian minimal)
#   curl -fsSL https://yssab2000.github.io/coldbox-install/get.sh | sudo COLDBOX_KEY=CLE bash -s -- <options>
#
# CLE = jeton GitHub « fine-grained » en lecture seule (Contents) sur ce dépôt, donné par l'éditeur.
# La clé n'est écrite nulle part : elle sert uniquement au téléchargement.
#
# Variables facultatives :
#   COLDBOX_KEY       jeton GitHub (obligatoire si le dépôt est privé)
#   COLDBOX_VERSION   étiquette de la version voulue (défaut : la dernière), ex. v1.0.0
#   COLDBOX_HOME      dossier d'installation (défaut : /opt/coldbox)
#   COLDBOX_REPO      dépôt GitHub (défaut : yssab2000/coldbox-saas)
#   COLDBOX_DOWNLOAD_ONLY=1   télécharge et vérifie seulement, n'installe pas
# Toutes les options après « -- » sont transmises à scripts/install-single-tenant.sh (--help).
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

log()  { printf '\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

REPO="${COLDBOX_REPO:-yssab2000/coldbox-saas}"
HOME_DIR="${COLDBOX_HOME:-/opt/coldbox}"
KEY="${COLDBOX_KEY:-}"
VERSION="${COLDBOX_VERSION:-}"
API="https://api.github.com/repos/${REPO}"

[[ "${COLDBOX_DOWNLOAD_ONLY:-}" == 1 || $EUID -eq 0 ]] || die "à lancer en root : ajoute « sudo » devant « bash »."
[[ "$HOME_DIR" == /* && "$HOME_DIR" != "/" ]] || die "COLDBOX_HOME doit être un chemin absolu (et pas /)."

# Outils nécessaires (Debian/Ubuntu).
need=()
for c in curl jq tar sha256sum; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
if [[ ${#need[@]} -gt 0 ]]; then
  command -v apt-get >/dev/null 2>&1 || die "outils manquants (${need[*]}) et apt-get indisponible : installe-les à la main."
  log "Installation des outils manquants : ${need[*]}"
  apt-get update -qq
  # sha256sum vient de coreutils
  apt-get install -y -qq curl jq tar coreutils
fi

AUTH=()
[[ -n "$KEY" ]] && AUTH=(-H "Authorization: Bearer ${KEY}")
gh_api() { curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

if [[ -n "$VERSION" ]]; then URL="${API}/releases/tags/${VERSION}"; else URL="${API}/releases/latest"; fi
log "Recherche de la version ${VERSION:-la plus récente}"
if ! REL="$(gh_api "$URL")"; then
  die "version introuvable ou accès refusé. Vérifie COLDBOX_KEY (jeton valide, lecture sur ${REPO}) et COLDBOX_VERSION."
fi
TAG="$(jq -r '.tag_name' <<<"$REL")"
ASSET_ID="$(jq -r '[.assets[] | select(.name | test("^coldbox-.*\\.tar\\.gz$"))][0].id // empty' <<<"$REL")"
ASSET_NAME="$(jq -r '[.assets[] | select(.name | test("^coldbox-.*\\.tar\\.gz$"))][0].name // empty' <<<"$REL")"
SUM_ID="$(jq -r --arg n "${ASSET_NAME}.sha256" '[.assets[] | select(.name == $n)][0].id // empty' <<<"$REL")"
[[ -n "$ASSET_ID" ]] || die "la version ${TAG} ne contient pas de fichier coldbox-*.tar.gz."
[[ -n "$SUM_ID" ]]   || die "la version ${TAG} n'a pas de fichier d'empreinte (${ASSET_NAME}.sha256) : téléchargement refusé."

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
download() { curl -fsSL "${AUTH[@]}" -H "Accept: application/octet-stream" -o "$2" "${API}/releases/assets/$1"; }
log "Téléchargement de ${ASSET_NAME} (${TAG})"
download "$ASSET_ID" "$WORK/$ASSET_NAME"
download "$SUM_ID" "$WORK/$ASSET_NAME.sha256"

log "Vérification de l'empreinte"
expected="$(awk '{print $1}' "$WORK/$ASSET_NAME.sha256")"
actual="$(sha256sum "$WORK/$ASSET_NAME" | awk '{print $1}')"
[[ -n "$expected" && "$expected" == "$actual" ]] || die "empreinte différente : fichier corrompu ou modifié, installation annulée."
echo "  OK ($actual)"

if [[ "${COLDBOX_DOWNLOAD_ONLY:-}" == 1 ]]; then
  log "Téléchargement vérifié (COLDBOX_DOWNLOAD_ONLY=1) : rien n'est installé. Fichier : $WORK/$ASSET_NAME"
  trap - EXIT
  exit 0
fi

# Dossier d'installation : refus d'écraser une installation existante (mise à jour = « coldbox update »).
if [[ -f "$HOME_DIR/laravel/.env" ]]; then
  die "ColdBox est déjà installé dans $HOME_DIR. Pour mettre à jour : coldbox update <archive>."
fi
if [[ -d "$HOME_DIR" && -n "$(ls -A "$HOME_DIR" 2>/dev/null)" ]]; then
  if [[ -f "$HOME_DIR/scripts/install-single-tenant.sh" && ! -f "$HOME_DIR/laravel/.env" ]]; then
    log "Reprise d'une tentative interrompue dans $HOME_DIR (rien n'avait été installé)"
  else
    die "$HOME_DIR existe et n'est pas vide : choisis un autre dossier avec COLDBOX_HOME."
  fi
fi
mkdir -p "$HOME_DIR"
tar -xzf "$WORK/$ASSET_NAME" -C "$HOME_DIR" --strip-components=1
[[ -f "$HOME_DIR/scripts/install-single-tenant.sh" ]] || die "archive inattendue : installateur introuvable."
# Mémorise la version et le dépôt (sans la clé) pour « coldbox update ».
mkdir -p "$HOME_DIR/.installer"; printf '%s' "$TAG" > "$HOME_DIR/.installer/release-tag"; printf '%s' "$REPO" > "$HOME_DIR/.installer/repo"
# La clé (lecture seule sur ce dépôt) est mémorisée en root pour les mises à jour : le client n'a rien à saisir.
if [[ -n "$KEY" ]]; then ( umask 077; printf '%s' "$KEY" > "$HOME_DIR/.installer/key" ); fi
log "ColdBox ${TAG} décompressé dans $HOME_DIR — lancement de l'installateur"
unset KEY COLDBOX_KEY
trap - EXIT; rm -rf "$WORK"
cd "$HOME_DIR"
exec bash scripts/install-single-tenant.sh "$@"
