#!/usr/bin/env python3
"""
Discovery script for finding microgenres in /rotor/stations/list endpoint

This script discovered that microgenres (367 of them) exist as separate stations
in the /rotor/stations/list endpoint with type='micro-genre', NOT as sub_genres
in the /genres endpoint.
"""

import urllib.request
import json
from pathlib import Path

# Read token
token_file = Path(__file__).parent / 'token.txt'
with open(token_file, 'r') as f:
    token = f.read().strip()

print("Discovering microgenres in /rotor/stations/list endpoint...")
print("=" * 100 + "\n")

# Fetch from /rotor/stations/list endpoint
url = 'https://api.music.yandex.net/rotor/stations/list'
req = urllib.request.Request(url)
req.add_header('Authorization', f'OAuth {token}')
req.add_header('X-Yandex-Music-Client', 'YandexMusicAndroid/24023621')
req.add_header('Accept-Language', 'ru')

response = urllib.request.urlopen(req, timeout=10)
data = json.loads(response.read().decode('utf-8'))

# Get all stations (result is a list)
stations_list = data.get('result', []) if isinstance(data.get('result'), list) else []

print(f"✓ Fetched {len(stations_list)} total stations from /rotor/stations/list\n")

# Group by type
by_type = {}
for station in stations_list:
    station_data = station.get('station', {})
    station_id = station_data.get('id', {})
    station_type = station_id.get('type', 'unknown')

    if station_type not in by_type:
        by_type[station_type] = []
    by_type[station_type].append(station_data)

# Show all types
print("Stations by type:")
print("-" * 100)
for st_type in sorted(by_type.keys()):
    count = len(by_type[st_type])
    print(f"  {st_type:30} | {count:3} stations")

# Extract microgenres
print("\n" + "=" * 100)
print("🎯 MICROGENRES DISCOVERY")
print("=" * 100 + "\n")

micro_genres = by_type.get('micro-genre', [])
print(f"✓ Found {len(micro_genres)} microgenres!\n")

print("First 30 microgenres:")
print("-" * 100)
for i, mg in enumerate(micro_genres[:30], 1):
    tag = mg.get('id', {}).get('tag', '?')
    name = mg.get('name', 'Unknown')
    print(f"{i:3}. {tag:40} | {name}")

print(f"\n... and {len(micro_genres) - 30} more microgenres\n")

# Show complete list
print("=" * 100)
print(f"COMPLETE LIST OF ALL {len(micro_genres)} MICROGENRES")
print("=" * 100 + "\n")

for i, mg in enumerate(micro_genres, 1):
    tag = mg.get('id', {}).get('tag', '?')
    name = mg.get('name', 'Unknown')
    print(f"{i:3}. {tag:40} | {name}")

# Save to file
output_file = Path(__file__).parent / 'MICROGENRES_DISCOVERED.txt'
with open(output_file, 'w', encoding='utf-8') as f:
    f.write("=" * 100 + "\n")
    f.write(f"MICROGENRES DISCOVERY REPORT - {len(micro_genres)} MICROGENRES FOUND\n")
    f.write("=" * 100 + "\n")
    f.write(f"Endpoint: /rotor/stations/list\n")
    f.write(f"Type filter: micro-genre\n")
    f.write(f"Total microgenres: {len(micro_genres)}\n\n")

    f.write("All microgenres:\n")
    f.write("-" * 100 + "\n")
    for i, mg in enumerate(micro_genres, 1):
        tag = mg.get('id', {}).get('tag', '?')
        name = mg.get('name', 'Unknown')
        f.write(f"{i:3}. {tag:40} | {name}\n")

print(f"\n✓ Results saved to: {output_file}")

# Show example microgenre structure
print("\n" + "=" * 100)
print("EXAMPLE MICROGENRE STRUCTURE")
print("=" * 100 + "\n")
if micro_genres:
    print(json.dumps(micro_genres[0], indent=2, ensure_ascii=False)[:1500])
    print("\n...")
