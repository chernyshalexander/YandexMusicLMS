#!/bin/bash
# Test: reshuffle produces different wave list
# Using CORRECT format: context.data.seeds (not context.seeds)

TOKEN=$(cat /home/chernysh/Projects/yandex/test/token.txt | head -1)

BASE_URL="https://api.music.yandex.net"

echo "========================================================================"
echo "TEST: Vibe Wheel Reshuffle - CORRECT FORMAT"
echo "========================================================================"
echo ""

# STEP 1: Default (user:onyourwave)
echo "STEP 1: DEFAULT wheel (user:onyourwave)"
echo "------------------------------------------------------------------------"
echo ""

echo "Request body:"
echo '{"context": {"type": "WAVE", "data": {"seeds": ["user:onyourwave"]}}}'
echo ""

DEFAULT=$(curl -s -X POST "$BASE_URL/wheel/new" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"context": {"type": "WAVE", "data": {"seeds": ["user:onyourwave"]}}}')

python3 << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
items = [i for i in data.get('items', []) if i.get('type') == 'WAVE' and i.get('style') != 'CONTROL_ACCENT']
names = [i.get('data', {}).get('wave', {}).get('name', i.get('id')) for i in items]
print(f"Got {len(names)} waves:")
for n in names[:5]:
    print(f"  - {n}")
print(f"  ... and {len(names)-5} more" if len(names) > 5 else "")
print()

# Save for comparison
with open('/tmp/default_waves_correct.json', 'w') as f:
    json.dump(names, f)

# Find reshuffle seed
for item in data.get('items', []):
    if item.get('style') == 'CONTROL_ACCENT':
        seeds = item.get('data', {}).get('wave', {}).get('seeds', [])
        if seeds:
            with open('/tmp/reshuffle_seed_correct.txt', 'w') as f:
                f.write(seeds[0])
            print(f"Reshuffle seed: {seeds[0]}")
        break

PYEOF "$DEFAULT"

echo ""

# STEP 2: After reshuffle
RESHUFFLE_SEED=$(cat /tmp/reshuffle_seed_correct.txt)

echo "STEP 2: RESHUFFLE wheel (diversity:reshuffle_...)"
echo "------------------------------------------------------------------------"
echo ""

echo "Request body:"
echo "{\"context\": {\"type\": \"WAVE\", \"data\": {\"seeds\": [\"$RESHUFFLE_SEED\"]}}}"
echo ""

RESHUFFLE=$(curl -s -X POST "$BASE_URL/wheel/new" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"context\": {\"type\": \"WAVE\", \"data\": {\"seeds\": [\"$RESHUFFLE_SEED\"]}}}")

python3 << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
items = [i for i in data.get('items', []) if i.get('type') == 'WAVE' and i.get('style') != 'CONTROL_ACCENT']
names = [i.get('data', {}).get('wave', {}).get('name', i.get('id')) for i in items]
print(f"Got {len(names)} waves:")
for n in names[:5]:
    print(f"  - {n}")
print(f"  ... and {len(names)-5} more" if len(names) > 5 else "")
print()

# Save for comparison
with open('/tmp/reshuffle_waves_correct.json', 'w') as f:
    json.dump(names, f)

# Find new reshuffle seed
for item in data.get('items', []):
    if item.get('style') == 'CONTROL_ACCENT':
        seeds = item.get('data', {}).get('wave', {}).get('seeds', [])
        if seeds:
            print(f"New reshuffle seed: {seeds[0]}")
        break

PYEOF "$RESHUFFLE"

echo ""

# STEP 3: Compare
echo "STEP 3: COMPARISON"
echo "------------------------------------------------------------------------"
echo ""

python3 << 'PYEOF'
import json

with open('/tmp/default_waves_correct.json') as f:
    default = set(json.load(f))

with open('/tmp/reshuffle_waves_correct.json') as f:
    reshuffle = set(json.load(f))

print(f"Default:  {len(default)} waves")
print(f"Reshuffle: {len(reshuffle)} waves")
print()

if default == reshuffle:
    print("✗ Lists are IDENTICAL - no change")
else:
    print("✓ Lists are DIFFERENT!")
    print()

    disappeared = default - reshuffle
    if disappeared:
        print(f"Disappeared ({len(disappeared)}):")
        for name in sorted(disappeared)[:5]:
            print(f"  - {name}")
        if len(disappeared) > 5:
            print(f"  ... and {len(disappeared)-5} more")

    print()
    appeared = reshuffle - default
    if appeared:
        print(f"Appeared ({len(appeared)}):")
        for name in sorted(appeared)[:5]:
            print(f"  - {name}")
        if len(appeared) > 5:
            print(f"  ... and {len(appeared)-5} more")

PYEOF

echo ""
echo "========================================================================"
