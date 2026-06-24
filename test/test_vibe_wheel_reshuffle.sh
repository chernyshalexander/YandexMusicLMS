#!/bin/bash
# Test hypothesis: reshuffle produces different wave list
# Uses POST /wheel/new with seeds in context

set -e

TOKEN_FILE="/home/chernysh/Projects/yandex/test/token.txt"
TOKEN=$(cat "$TOKEN_FILE" | head -1 2>/dev/null || echo "${YANDEX_TOKEN}")

if [ -z "$TOKEN" ]; then
    echo "ERROR: No token found"
    exit 1
fi

BASE_URL="https://api.music.yandex.net"

echo "========================================================================"
echo "TEST: Vibe Wheel Reshuffle - Different Waves?"
echo "========================================================================"
echo ""

# ========================================================================
# STEP 1: Get wheel for default case (empty seeds)
# ========================================================================

echo "STEP 1: Fetch wheel for DEFAULT case (empty seeds)"
echo "------------------------------------------------------------------------"
echo ""

echo "Request: POST /wheel/new with {\"context\": {\"type\": \"WAVE\"}}"
echo ""

DEFAULT_WHEEL=$(curl -s -X POST "$BASE_URL/wheel/new" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"context": {"type": "WAVE"}}')

if [ -z "$DEFAULT_WHEEL" ]; then
    echo "ERROR: Empty response from API"
    exit 1
fi

# Save to file
echo "$DEFAULT_WHEEL" > /tmp/default_wheel.json

# Count items and extract waves
python3 << 'PYEOF'
import json

data = json.load(open('/tmp/default_wheel.json'))
items = data.get('items', [])

print(f"Got {len(items)} items in wheel")
print()

waves = []
reshuffle_seeds = None

for item in items:
    if item.get('type') != 'WAVE':
        continue

    is_reshuffle = item.get('style', '') == 'CONTROL_ACCENT'
    wave = item.get('data', {}).get('wave', {})
    seeds = wave.get('seeds', [])

    if not seeds:
        continue

    name = 'RESHUFFLE' if is_reshuffle else (wave.get('name') or item.get('id', 'Unknown'))

    if is_reshuffle:
        reshuffle_seeds = seeds
    else:
        waves.append({'name': name, 'seeds': seeds})

print(f"  Regular waves: {len(waves)}")
for i, wave in enumerate(waves[:5]):
    print(f"    {i+1}. {wave['name']}")
if len(waves) > 5:
    print(f"    ... and {len(waves)-5} more")

if reshuffle_seeds:
    print(f"  Reshuffle seeds: {', '.join(reshuffle_seeds)}")
    # Save for next step
    with open('/tmp/reshuffle_seeds.txt', 'w') as f:
        f.write(','.join(reshuffle_seeds))
    # Also save wave names for comparison
    with open('/tmp/default_waves_names.txt', 'w') as f:
        for wave in waves:
            f.write(wave['name'] + '\n')
else:
    print("  ERROR: No reshuffle found!")
    exit(1)

PYEOF

echo ""

# ========================================================================
# STEP 2: Perform reshuffle with seeds
# ========================================================================

echo "STEP 2: Perform RESHUFFLE with new seeds"
echo "------------------------------------------------------------------------"
echo ""

RESHUFFLE_SEEDS=$(cat /tmp/reshuffle_seeds.txt)
echo "Using reshuffle seeds: $RESHUFFLE_SEEDS"
echo ""

echo "Request: POST /wheel/new with seeds in context"
echo ""

RESHUFFLE_WHEEL=$(curl -s -X POST "$BASE_URL/wheel/new" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"context\": {\"type\": \"WAVE\", \"seeds\": [\"$RESHUFFLE_SEEDS\"]}}")

if [ -z "$RESHUFFLE_WHEEL" ]; then
    echo "ERROR: Empty response from API"
    exit 1
fi

# Save to file
echo "$RESHUFFLE_WHEEL" > /tmp/reshuffle_wheel.json

# Count items and extract waves
python3 << 'PYEOF'
import json

data = json.load(open('/tmp/reshuffle_wheel.json'))
items = data.get('items', [])

print(f"Got {len(items)} items in wheel")
print()

waves = []
new_reshuffle_seeds = None

for item in items:
    if item.get('type') != 'WAVE':
        continue

    is_reshuffle = item.get('style', '') == 'CONTROL_ACCENT'
    wave = item.get('data', {}).get('wave', {})
    seeds = wave.get('seeds', [])

    if not seeds:
        continue

    name = 'RESHUFFLE' if is_reshuffle else (wave.get('name') or item.get('id', 'Unknown'))

    if is_reshuffle:
        new_reshuffle_seeds = seeds
    else:
        waves.append({'name': name, 'seeds': seeds})

print(f"  Regular waves: {len(waves)}")
for i, wave in enumerate(waves[:5]):
    print(f"    {i+1}. {wave['name']}")
if len(waves) > 5:
    print(f"    ... and {len(waves)-5} more")

if new_reshuffle_seeds:
    print(f"  New reshuffle seeds: {', '.join(new_reshuffle_seeds)}")
else:
    print("  (No new reshuffle found)")

# Save wave names for comparison
with open('/tmp/reshuffle_waves_names.txt', 'w') as f:
    for wave in waves:
        f.write(wave['name'] + '\n')

PYEOF

echo ""

# ========================================================================
# STEP 3: Compare lists
# ========================================================================

echo "STEP 3: COMPARISON"
echo "------------------------------------------------------------------------"
echo ""

python3 << 'PYEOF'
# Read both wave name lists
with open('/tmp/default_waves_names.txt', 'r') as f:
    default_waves = set(line.strip() for line in f if line.strip())

with open('/tmp/reshuffle_waves_names.txt', 'r') as f:
    reshuffle_waves = set(line.strip() for line in f if line.strip())

print(f"Default waves: {len(default_waves)}")
print(f"Reshuffle waves: {len(reshuffle_waves)}")
print()

if default_waves == reshuffle_waves:
    print("✗ RESULT: Wave lists are the SAME")
    print()
    print("  This suggests:")
    print("    - Reshuffle may generate waves dynamically during playback")
    print("    - Or the API doesn't support seeds-based reshuffling")
else:
    print("✓ RESULT: Reshuffle produces DIFFERENT wave list!")
    print()

    disappeared = default_waves - reshuffle_waves
    if disappeared:
        print(f"  Waves that disappeared ({len(disappeared)}):")
        for name in sorted(disappeared)[:5]:
            print(f"    - {name}")
        if len(disappeared) > 5:
            print(f"    ... and {len(disappeared)-5} more")

    print()
    appeared = reshuffle_waves - default_waves
    if appeared:
        print(f"  Waves that appeared ({len(appeared)}):")
        for name in sorted(appeared)[:5]:
            print(f"    - {name}")
        if len(appeared) > 5:
            print(f"    ... and {len(appeared)-5} more")

PYEOF

echo ""

# ========================================================================
# CONCLUSION
# ========================================================================

echo "========================================================================"
echo "CONCLUSION:"
echo ""

python3 << 'PYEOF'
# Read both wave name lists
with open('/tmp/default_waves_names.txt', 'r') as f:
    default_waves = set(line.strip() for line in f if line.strip())

with open('/tmp/reshuffle_waves_names.txt', 'r') as f:
    reshuffle_waves = set(line.strip() for line in f if line.strip())

if default_waves == reshuffle_waves:
    print("Reshuffle does NOT produce different waves.")
    print()
    print("Possible explanations:")
    print("  1. Waves are generated dynamically during playback")
    print("  2. The API requires different parameters for reshuffling")
    print("  3. Seeds are used to influence track selection, not waves")
    print()
    print("Architecture implication:")
    print("  → Live menu update on reshuffle may NOT be feasible")
    print("  → Stick with simple reshuffle (just play the wave)")
else:
    print("Reshuffle DOES produce different waves!")
    print()
    print("This confirms:")
    print("  → Each reshuffle generates a new wave list")
    print("  → Live menu update on reshuffle is feasible!")
    print("  → Can implement: Click reshuffle → menu updates with new waves")

PYEOF

echo "========================================================================"
