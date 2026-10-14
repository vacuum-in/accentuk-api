#!/usr/bin/env bash
# Deploy the whole stack from a clean checkout: download the models and the
# lexicon, build the images, restore the lexicon into a fresh volume, start,
# check, and stress a probe sentence.
#
#   uk-tts-frontend/deploy/install.sh
#
# Needs docker with compose v2, curl, python3 and unzip. Re-running is safe:
# downloads already present are kept, and the lexicon is restored only into
# an empty database. Settings come from the environment, else .env.example:
#   ASSETS                 where models and data go     (default: <checkout>/assets)
#   ACCENTUK_DATA_URL      the data release              (default: vacuum-in/accentuk-api data-v2)
#   COMPOSE_PROJECT_NAME, POSTGRES_VOLUME, FRONTEND_PORT, STRESS_API_PORT,
#   UI_PORT, POSTGRES_PORT  to run a second stack beside another
set -euo pipefail

DEPLOY="$(cd "$(dirname "$0")" && pwd)"
FRONTEND="$(dirname "$DEPLOY")"
UKSTRESS_DIR="${UKSTRESS_DIR:-$(cd "$FRONTEND/.." && pwd)/wiki-stress}"
ASSETS="${ASSETS:-$(cd "$FRONTEND/.." && pwd)/assets}"
DATA_URL="${ACCENTUK_DATA_URL:-https://github.com/vacuum-in/accentuk-api/releases/download/data-v2}"
HF="https://huggingface.co"

for tool in docker curl python3 unzip; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 is required" >&2; exit 1; }
[ -f "$UKSTRESS_DIR/db/lexicon_archive.sh" ] || { echo "no wiki-stress checkout at $UKSTRESS_DIR" >&2; exit 1; }
mkdir -p "$ASSETS"

# hf_get REPO DEST [SUBDIR]: every file of a public model repo; weights and
# tokenizer into DEST/SUBDIR, the repo's own metadata beside them in DEST.
hf_get() {
  local repo=$1 dest=$2 sub=${3:-}
  if [ -f "$dest/.complete" ]; then echo "    $repo: present"; return; fi
  mkdir -p "$dest/$sub"
  curl -fsSL "$HF/api/models/$repo" | python3 -c 'import json,sys; print("\n".join(s["rfilename"] for s in json.load(sys.stdin)["siblings"]))' |
  while read -r file; do
    case "$file" in .gitattributes) continue ;; esac
    local target="$dest/$sub/$file"
    case "$file" in serving_manifest.json|training_run.json|README.md) target="$dest/$file" ;; esac
    curl -fsSL --retry 3 -o "$target" "$HF/$repo/resolve/main/$file"
  done
  touch "$dest/.complete"
  echo "    $repo -> $dest"
}

echo "=== models (Hugging Face)"
hf_get aloudreader/uk-stress-crossencoder "$ASSETS/stress-model" checkpoint
hf_get aloudreader/uk-stress-token-classifier "$ASSETS/tok-v5"
hf_get aloudreader/uk-stress-combiner "$ASSETS/combiner-v1"
hf_get aloudreader/marian-uk-verbalizer-spans-ct2-int8 "$ASSETS/verbalizer-spans"
if [ ! -f "$ASSETS/spacy-uk_core_news_trf/config.cfg" ]; then
  # The tagger the morphology tier was measured with: 3.8.0, loaded by path.
  tmp="$(mktemp -d)"
  # Pinned: Hugging Face's `main` serves 3.7.2, whose weights differ and
  # change the morphology tier's answers.
  curl -fsSL --retry 3 -o "$tmp/model.whl" \
    "https://github.com/explosion/spacy-models/releases/download/uk_core_news_trf-3.8.0/uk_core_news_trf-3.8.0-py3-none-any.whl"
  unzip -qo "$tmp/model.whl" -d "$tmp/unpacked"
  inner="$(dirname "$(find "$tmp/unpacked" -name config.cfg -path '*uk_core_news_trf-*' | head -1)")"
  rm -rf "$ASSETS/spacy-uk_core_news_trf" && cp -r "$inner" "$ASSETS/spacy-uk_core_news_trf"
  rm -rf "$tmp"
fi
python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["version"]; print("    uk_core_news_trf", v); sys.exit(v != "3.8.0")' \
  "$ASSETS/spacy-uk_core_news_trf/meta.json" || { echo "uk_core_news_trf must be 3.8.0; remove $ASSETS/spacy-uk_core_news_trf" >&2; exit 1; }

echo "=== data release ($DATA_URL)"
if [ ! -f "$ASSETS/lexicon/suffix_table.json" ]; then
  mkdir -p "$ASSETS/lexicon"
  curl -fsSL --retry 3 "$DATA_URL/lexicon-assets.tar.gz" | tar -xz -C "$ASSETS/lexicon"
fi
if [ ! -f "$ASSETS/lexicon-serving/MANIFEST.tsv" ]; then
  mkdir -p "$ASSETS/lexicon-serving"
  curl -fsSL --retry 3 "$DATA_URL/lexicon-serving.tar" | tar -x -C "$ASSETS/lexicon-serving"
fi
ls "$ASSETS/lexicon" | sed 's/^/    /'

echo "=== $DEPLOY/.env"
python3 - "$DEPLOY/.env.example" "$DEPLOY/.env" "$ASSETS" "$UKSTRESS_DIR" <<'PY'
import os, re, sys
template, out, assets, ukstress = sys.argv[1:]
lines = []
for line in open(template, encoding="utf-8"):
    line = line.replace("../../assets", assets).replace("../../wiki-stress", ukstress)
    m = re.match(r"^([A-Z_]+)=(.*)$", line.rstrip("\n"))
    if m:
        key = m.group(1)
        value = {"HOST_UID": str(os.getuid()), "HOST_GID": str(os.getgid())}.get(key, m.group(2))
        line = f"{key}={os.environ.get(key, value)}\n"   # the environment overrides the template
    lines.append(line)
open(out, "w", encoding="utf-8").writelines(lines)
PY
set -a; . "$DEPLOY/.env"; set +a
grep -E "^(COMPOSE_PROJECT_NAME|POSTGRES_VOLUME|STRESS_API_PORT|FRONTEND_PORT)=" "$DEPLOY/.env" | sed 's/^/    /'

cd "$DEPLOY"
echo "=== images"
docker compose build

echo "=== lexicon"
docker volume create "$POSTGRES_VOLUME" >/dev/null
docker compose up -d --no-build postgres
until docker compose exec -T postgres pg_isready -U ukstress_owner -d ukstress >/dev/null 2>&1; do sleep 2; done
psql_owner=(docker compose exec -T postgres psql -U ukstress_owner -d ukstress -v ON_ERROR_STOP=1 -X -q)
present=$("${psql_owner[@]}" -At -c "select count(*) from pg_tables where schemaname='public' and tablename='stress_lookup'" < /dev/null)
if [ "$present" = 0 ]; then
  PSQL="${psql_owner[*]}" "$UKSTRESS_DIR/db/lexicon_archive.sh" import "$ASSETS/lexicon-serving"
else
  echo "    stress_lookup exists: keeping the database as it is"
fi
# The schema creates the application roles without passwords.
"${psql_owner[@]}" -c "ALTER ROLE ukstress_api WITH PASSWORD '${API_PASSWORD:-ukstress_api}'" < /dev/null

echo "=== start"
docker compose up -d --no-build
WIKI_STRESS=/nonexistent ./restart.sh

echo "=== check"
curl -fsS "http://127.0.0.1:${STRESS_API_PORT}/health/ready"; echo
curl -fsS -X POST "http://127.0.0.1:${FRONTEND_PORT}/v1/prepare" -H 'Content-Type: application/json' \
  -d '{"text": "О 7:45 ранку 3 квітня потяг № 12 прибув до Львова. Мої сестри прийшли додому."}' \
  | python3 -c 'import json,sys; print("   ", json.load(sys.stdin)["results"][0]["text"])'
echo "=== done: stress API http://127.0.0.1:${STRESS_API_PORT}  frontend http://127.0.0.1:${FRONTEND_PORT}  UI http://127.0.0.1:${UI_PORT}"
