#!/bin/bash
# Jednorázový setup — spusti raz po klonovaní projektu.

set -e
cd "$(dirname "$0")"

echo "→ Creating virtual environment..."
python3 -m venv .venv

echo "→ Installing dependencies..."
.venv/bin/pip install --upgrade pip -q
.venv/bin/pip install -r requirements.txt -q

echo "→ Copying .env template (ak .env este neexistuje)..."
if [ ! -f .env ]; then
  cp .env.example .env
  echo "   Upravte .env a doplnte kredenciale!"
else
  echo "   .env uz existuje, preskakujem."
fi

echo ""
echo "✓ Setup hotovy."
echo ""
echo "Dalsi kroky:"
echo "  1. Upravte .env — doplnte Garmin + SMTP kredenciale"
echo "  2. Spustite manualny test:"
echo "     .venv/bin/python main.py --fit /cesta/k/aktivite.fit"
echo "  3. Auto rezim (Garmin Connect + email):"
echo "     .venv/bin/python main.py --auto --email"
