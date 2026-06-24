#!/usr/bin/env python3
"""
Detailed Yandex Music API /genres endpoint test

Analyzes each genre for presence of sub_genres field.
"""

import sys
import json
import urllib.request
from pathlib import Path
from datetime import datetime

# Read token
token_file = Path(__file__).parent / 'token.txt'
with open(token_file, 'r') as f:
    token = f.read().strip()

print("Fetching genres from API...")

# Make request
url = 'https://api.music.yandex.net/genres'
req = urllib.request.Request(url)
req.add_header('Authorization', f'OAuth {token}')
req.add_header('X-Yandex-Music-Client', 'YandexMusicAndroid/24023621')
req.add_header('Accept-Language', 'ru')

response = urllib.request.urlopen(req, timeout=10)
data = json.loads(response.read().decode('utf-8'))

genres = data['result']
print(f"\nTotal genres: {len(genres)}\n")

# Analyze each genre
genres_with_subgenres = []
genres_without_subgenres = []

print("Analyzing each genre for sub_genres field:\n")

for genre in genres:
    genre_id = genre.get('id', 'UNKNOWN')
    genre_title = genre.get('title', 'UNKNOWN')
    has_subgenres = 'sub_genres' in genre
    subgenres = genre.get('sub_genres', [])
    num_subgenres = len(subgenres) if subgenres else 0

    status = "✓ HAS" if has_subgenres and num_subgenres > 0 else "✗ NO"
    print(f"{status:10} | {genre_id:20} | {genre_title:25} | {num_subgenres} sub_genres")

    if has_subgenres and num_subgenres > 0:
        genres_with_subgenres.append({
            'id': genre_id,
            'title': genre_title,
            'subgenres': subgenres,
            'count': num_subgenres
        })
    else:
        genres_without_subgenres.append({
            'id': genre_id,
            'title': genre_title
        })

# Print summary
print("\n" + "=" * 80)
print("SUMMARY")
print("=" * 80)
print(f"Genres WITH sub_genres:    {len(genres_with_subgenres)}")
print(f"Genres WITHOUT sub_genres: {len(genres_without_subgenres)}")
print(f"Total sub_genres found:    {sum(g['count'] for g in genres_with_subgenres)}")

# Show genres with sub_genres
if genres_with_subgenres:
    print("\n" + "=" * 80)
    print("GENRES WITH SUB_GENRES")
    print("=" * 80)
    for g in genres_with_subgenres:
        print(f"\n{g['title']} ({g['id']}):")
        for sub in g['subgenres']:
            print(f"  - {sub.get('title', 'UNKNOWN')} ({sub.get('id', 'UNKNOWN')})")
else:
    print("\n✗ NO GENRES WITH SUB_GENRES FOUND")

# Show genre structure comparison
print("\n" + "=" * 80)
print("GENRE STRUCTURE ANALYSIS")
print("=" * 80)

# Get first genre as example
first = genres[0]
print("\nFields in first genre (from API):")
for key in sorted(first.keys()):
    print(f"  - {key}")

print("\nExpected fields (from Python model):")
expected_fields = [
    'id', 'weight', 'composer_top', 'title', 'titles', 'images', 'show_in_menu',
    'show_in_regions', 'full_title', 'url_part', 'color', 'radio_icon', 'sub_genres'
]
for field in expected_fields:
    present = field in first
    status = "✓" if present else "✗"
    print(f"  {status} {field}")

# Save detailed report
report_file = Path(__file__).parent / 'GENRES_DETAILED_ANALYSIS.txt'

with open(report_file, 'w', encoding='utf-8') as f:
    f.write("════════════════════════════════════════════════════════════════════════════════════════════════════════\n")
    f.write("YANDEX MUSIC API - DETAILED GENRES ANALYSIS REPORT\n")
    f.write("════════════════════════════════════════════════════════════════════════════════════════════════════════\n")
    f.write(f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    f.write("Endpoint: GET /genres\n")
    f.write(f"Status: {response.status}\n\n")

    f.write("SUMMARY\n")
    f.write("─" * 100 + "\n")
    f.write(f"Total genres returned:      {len(genres)}\n")
    f.write(f"Genres WITH sub_genres:     {len(genres_with_subgenres)}\n")
    f.write(f"Genres WITHOUT sub_genres:  {len(genres_without_subgenres)}\n")
    f.write(f"Total microgenres found:    {sum(g['count'] for g in genres_with_subgenres)}\n\n")

    if genres_with_subgenres:
        f.write("✓ MICROGENRES FOUND IN API RESPONSE\n\n")
        f.write("Genres with Sub_genres:\n")
        for g in genres_with_subgenres:
            f.write(f"\n  {g['title']} ({g['id']}) - {g['count']} subgenres:\n")
            for sub in g['subgenres']:
                f.write(f"    - {sub.get('title', 'UNKNOWN')} (id: {sub.get('id', 'UNKNOWN')})\n")
    else:
        f.write("✗ NO MICROGENRES (sub_genres) FOUND IN API RESPONSE\n")
        f.write("  The sub_genres field is not populated in the /genres response\n\n")

    f.write("\n\nFIELD STRUCTURE COMPARISON\n")
    f.write("─" * 100 + "\n")
    f.write("Expected Genre fields (from Python API model):\n")
    f.write("  - id\n")
    f.write("  - weight\n")
    f.write("  - composer_top\n")
    f.write("  - title\n")
    f.write("  - titles (dict)\n")
    f.write("  - images\n")
    f.write("  - show_in_menu\n")
    f.write("  - show_in_regions (optional)\n")
    f.write("  - full_title (optional)\n")
    f.write("  - url_part (optional)\n")
    f.write("  - color (optional)\n")
    f.write("  - radio_icon (optional)\n")
    f.write("  - sub_genres (optional) ← THIS IS THE FIELD WE'RE LOOKING FOR\n\n")

    f.write("Actual fields in API response (example from first genre):\n")
    for key in sorted(first.keys()):
        f.write(f"  - {key}\n")

    f.write("\n\nFull genres list (alphabetical):\n")
    f.write("─" * 100 + "\n")
    for genre in sorted(genres, key=lambda g: g.get('title', 'UNKNOWN')):
        genre_id = genre.get('id', 'UNKNOWN')
        genre_title = genre.get('title', 'UNKNOWN')
        has_sub = 'sub_genres' in genre and genre.get('sub_genres')
        status = "✓ HAS SUBGENRES" if has_sub else "✗ NO SUBGENRES"
        f.write(f"{status:20} | {genre_id:20} | {genre_title}\n")

print(f"\nReport saved to: {report_file}")
