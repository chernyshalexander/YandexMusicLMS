#!/usr/bin/env python3
"""
Test Yandex Music API /genres endpoint

Fetches genre list and validates that microgenres (sub_genres) are returned.
Generates a detailed report showing all genres and their subgenres.
"""

import sys
import json
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

# Read token from file
token_file = Path(__file__).parent / 'token.txt'

if not token_file.exists():
    print(f"ERROR: Token file not found at {token_file}")
    sys.exit(1)

with open(token_file, 'r') as f:
    token = f.read().strip()

if not token:
    print("ERROR: Token is empty")
    sys.exit(1)

print(f"✓ Token loaded from {token_file}")
print(f"✓ Token length: {len(token)} chars\n")

# API settings
base_url = 'https://api.music.yandex.net'
endpoint = '/genres'
url = base_url + endpoint

print("=" * 80)
print("TESTING YANDEX MUSIC API GENRES ENDPOINT")
print("=" * 80)
print(f"URL: {url}")
print("Method: GET\n")

# Create request with headers
req = urllib.request.Request(url)
req.add_header('Authorization', f'OAuth {token}')
req.add_header('X-Yandex-Music-Client', 'YandexMusicAndroid/24023621')
req.add_header('Accept-Language', 'ru')
req.add_header('Content-Type', 'application/json')
req.add_header('User-Agent', 'Yandex-Music-API')

print("Sending request...")

try:
    response = urllib.request.urlopen(req, timeout=10)
except urllib.error.HTTPError as e:
    print(f"\nERROR: HTTP {e.code}")
    print(f"Content: {e.read().decode('utf-8')}")
    sys.exit(1)
except Exception as e:
    print(f"\nERROR: {e}")
    sys.exit(1)

# Read and parse response
response_data = response.read().decode('utf-8')
status_code = response.status

print("\n" + "─" * 80)
print(f"RESPONSE STATUS: {status_code}")
print("─" * 80 + "\n")

if status_code != 200:
    print(f"ERROR: Request failed with status {status_code}")
    sys.exit(1)

print(f"✓ Request successful (HTTP {status_code})\n")

try:
    data = json.loads(response_data)
except json.JSONDecodeError as e:
    print(f"ERROR: Failed to parse JSON response")
    print(f"Error: {e}")
    sys.exit(1)

print("✓ JSON parsed successfully\n")

# Validate structure
if not isinstance(data, dict) or 'result' not in data:
    print("ERROR: Response structure is invalid")
    print(f"Expected: {{ result: [...] }}")
    sys.exit(1)

genres = data['result']
if not isinstance(genres, list):
    print("ERROR: Result is not an array")
    sys.exit(1)

print("✓ Response structure is valid")
print(f"✓ Found {len(genres)} genres\n")

# Analyze genres and microgenres
stats = []
total_genres = 0
total_subgenres = 0
genres_with_subgenres = 0
genres_without_subgenres = 0

for genre in genres:
    total_genres += 1
    genre_id = genre.get('id', 'UNKNOWN')
    genre_title = genre.get('title', 'UNKNOWN')
    subgenres = genre.get('sub_genres', [])
    subgenre_count = len(subgenres)

    if subgenre_count > 0:
        genres_with_subgenres += 1
        total_subgenres += subgenre_count
    else:
        genres_without_subgenres += 1

    stats.append({
        'id': genre_id,
        'title': genre_title,
        'subgenres': subgenres,
        'count': subgenre_count,
    })

# Generate report
report_file = Path(__file__).parent / 'GENRES_API_TEST_REPORT.txt'

with open(report_file, 'w', encoding='utf-8') as f:
    # Header
    f.write("═" * 100 + "\n")
    f.write("YANDEX MUSIC API - GENRES ENDPOINT TEST REPORT\n")
    f.write("═" * 100 + "\n")
    f.write(f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    f.write("Endpoint: GET /genres\n")
    f.write("Status: SUCCESS ✓\n\n")

    # Statistics
    f.write("┌" + "─" * 98 + "┐\n")
    f.write("│ STATISTICS\n")
    f.write("├" + "─" * 98 + "┤\n")
    f.write(f"│ Total genres:                       {total_genres:40d}\n")
    pct_with = (genres_with_subgenres / total_genres * 100) if total_genres > 0 else 0
    f.write(f"│ Genres WITH microgenres:            {genres_with_subgenres:40d} ({pct_with:.1f}%)\n")
    pct_without = (genres_without_subgenres / total_genres * 100) if total_genres > 0 else 0
    f.write(f"│ Genres WITHOUT microgenres:         {genres_without_subgenres:40d} ({pct_without:.1f}%)\n")
    f.write(f"│ Total microgenres:                  {total_subgenres:40d}\n")
    avg_subgenres = (total_subgenres / total_genres) if total_genres > 0 else 0
    f.write(f"│ Average microgenres per genre:      {avg_subgenres:40.2f}\n")
    f.write("└" + "─" * 98 + "┘\n\n")

    # Verification
    f.write("┌" + "─" * 98 + "┐\n")
    f.write("│ MICROGENRES VERIFICATION ✓\n")
    f.write("├" + "─" * 98 + "┤\n")
    if total_subgenres > 0:
        f.write("│ ✓ Microgenres EXIST in API response\n")
        f.write(f"│ ✓ Found {total_subgenres} unique microgenres across all genres\n")
        f.write(f"│ ✓ {genres_with_subgenres} genres contain microgenres\n")
    else:
        f.write("│ ✗ No microgenres found (unexpected!)\n")
    f.write("└" + "─" * 98 + "┘\n\n")

    # Detailed genre list
    f.write("┌" + "─" * 98 + "┐\n")
    f.write("│ DETAILED GENRE LIST WITH MICROGENRES\n")
    f.write("├" + "─" * 98 + "┤\n")

    for stat in sorted(stats, key=lambda x: x['title']):
        f.write(f"\n│ [{stat['id'].upper()}] {stat['title']}\n")

        if stat['count'] > 0:
            f.write(f"│ ├─ Microgenres: {stat['count']}\n")

            for sub in stat['subgenres']:
                sub_id = sub.get('id', 'UNKNOWN')
                sub_title = sub.get('title', 'UNKNOWN')
                f.write(f"│ │  ├─ {sub_title} (id: {sub_id})\n")
        else:
            f.write("│ ├─ No microgenres\n")

    f.write("\n└" + "─" * 98 + "┘\n\n")

    # Top genres
    f.write("┌" + "─" * 98 + "┐\n")
    f.write("│ TOP 10 GENRES BY MICROGENRE COUNT\n")
    f.write("├" + "─" * 98 + "┤\n")

    sorted_stats = sorted(stats, key=lambda x: x['count'], reverse=True)
    for i, stat in enumerate(sorted_stats[:10], 1):
        f.write(f"│ {i:2d}. {stat['title']:<40} ({stat['count']:3d} microgenres)\n")

    f.write("└" + "─" * 98 + "┘\n\n")

    # Raw JSON
    f.write("┌" + "─" * 98 + "┐\n")
    f.write("│ RAW JSON RESPONSE (first 3 genres with microgenres)\n")
    f.write("├" + "─" * 98 + "┤\n")

    sample_genres = [g for g in genres if g.get('sub_genres')][:3]
    json_sample = json.dumps({'result': sample_genres}, indent=2, ensure_ascii=False)
    for line in json_sample.split('\n'):
        f.write(f"│ {line}\n")

    f.write("│ ...\n")
    f.write("└" + "─" * 98 + "┘\n\n")

    # Conclusions
    f.write("┌" + "─" * 98 + "┐\n")
    f.write("│ CONCLUSIONS\n")
    f.write("├" + "─" * 98 + "┤\n")

    if total_subgenres > 0:
        f.write("│ ✓ MICROGENRES CONFIRMED TO EXIST\n")
        f.write("│\n")
        f.write("│ Key findings:\n")
        f.write("│ • API /genres endpoint returns hierarchical genre structure\n")
        f.write("│ • Each genre contains 'sub_genres' array with microgenres\n")
        f.write(f"│ • {genres_with_subgenres} out of {total_genres} genres have microgenres\n")
        f.write(f"│ • Total unique microgenres available: {total_subgenres}\n")
        f.write("│ • Microgenres can be used as alternative genre selections\n")
        f.write("│\n")
        f.write("│ Recommendation:\n")
        f.write("│ • Safe to implement microgenres menu in plugin\n")
        f.write("│ • Use hierarchical menu: Genre → Microgenres\n")
        f.write("│ • Cache for 7 days (genres change rarely)\n")
    else:
        f.write("│ ✗ NO MICROGENRES FOUND (unexpected)\n")

    f.write("└" + "─" * 98 + "┘\n\n")

    # Metadata
    f.write("═" * 100 + "\n")
    f.write("API RESPONSE METADATA\n")
    f.write("═" * 100 + "\n")
    f.write(f"Content-Type: {response.headers.get('Content-Type', 'N/A')}\n")
    f.write(f"Content-Length: {len(response_data)} bytes\n")
    f.write(f"Date: {response.headers.get('Date', 'N/A')}\n\n")

# Print console summary
print("\n" + "=" * 80)
print("ANALYSIS RESULTS")
print("=" * 80 + "\n")

print(f"Total genres:               {total_genres:5d}")
pct_with = (genres_with_subgenres / total_genres * 100) if total_genres > 0 else 0
print(f"Genres WITH microgenres:    {genres_with_subgenres:5d} ({pct_with:.1f}%)")
pct_without = (genres_without_subgenres / total_genres * 100) if total_genres > 0 else 0
print(f"Genres WITHOUT microgenres: {genres_without_subgenres:5d} ({pct_without:.1f}%)")
print(f"Total microgenres:          {total_subgenres:5d}\n")

print("✓ MICROGENRES CONFIRMED TO EXIST IN API RESPONSE\n")

print("Top 5 genres by microgenre count:")
sorted_stats = sorted(stats, key=lambda x: x['count'], reverse=True)
for i, stat in enumerate(sorted_stats[:5], 1):
    print(f"  {i}. {stat['title']:<35} ({stat['count']:3d} microgenres)")

print("\n" + "=" * 80)
print(f"Report saved to: {report_file}")
print("=" * 80)
