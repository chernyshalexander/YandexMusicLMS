#!/usr/bin/env python3
"""
Test script to investigate the impact of 'nocorrect' parameter on search results.
Tests:
1. Difference between nocorrect=True/False
2. Impact of quoted queries
3. search_suggest method
4. Misspelling detection and correction

Usage:
    python3 test/test_search_nocorrect.py

Required:
    - yandex_music library installed
    - test/token.txt with valid OAuth token
"""

import json
import sys
from pathlib import Path

try:
    from yandex_music import Client
except ImportError:
    print("ERROR: yandex_music library not found. Install it with: pip install yandex-music")
    sys.exit(1)

# Get token from test/token.txt
token_file = Path(__file__).parent / 'token.txt'
if not token_file.exists():
    print(f"ERROR: Token file not found at {token_file}")
    print("Please create test/token.txt with your OAuth token")
    sys.exit(1)

token = token_file.read_text().strip()
if not token:
    print("ERROR: Token file is empty")
    sys.exit(1)

print(f"Token loaded: {token[:20]}...\n")

# Initialize client
try:
    client = Client(token).init()
    print("✓ Client initialized successfully\n")
except Exception as e:
    print(f"ERROR: Failed to initialize client: {e}")
    sys.exit(1)

# Test queries - both correct and misspelled
test_queries = [
    {
        'name': 'Correct spelling',
        'query': 'Гражданская оборона',
        'expected_type': 'artist',
    },
    {
        'name': 'Misspelled (missing letter)',
        'query': 'Гражданская абарона',
        'expected_type': 'artist',
    },
    {
        'name': 'Misspelled (extra letter)',
        'query': 'Би-2 Сонг',
        'expected_type': 'artist',
    },
    {
        'name': 'Quoted query',
        'query': '"Гражданская оборона"',
        'expected_type': 'artist',
    },
]

def print_separator(char='=', length=100):
    """Print a separator line."""
    print(char * length)

def format_number(num):
    """Format number with thousands separator."""
    return f"{num:,}" if num is not None else "N/A"

def search_and_compare(query, search_type='all'):
    """
    Search with nocorrect=False and nocorrect=True and compare results.

    Returns:
        dict: Comparison results
    """
    print(f"\nQuery: '{query}'\n")

    results = {}

    for nocorrect_val in [False, True]:
        try:
            search_result = client.search(
                text=query,
                nocorrect=nocorrect_val,
                type_=search_type,
            )

            if search_result is None:
                print(f"  nocorrect={nocorrect_val}: No results")
                results[nocorrect_val] = None
                continue

            results[nocorrect_val] = {
                'search_result': search_result,
                'counts': {},
            }

            # Count results by type
            for result_type in ['tracks', 'artists', 'albums', 'playlists', 'videos', 'podcasts', 'podcast_episodes', 'users']:
                attr = getattr(search_result, result_type, None)
                count = attr.total if attr else 0
                results[nocorrect_val]['counts'][result_type] = count

            # Check for misspelling
            results[nocorrect_val]['misspell_result'] = search_result.misspell_result
            results[nocorrect_val]['misspell_original'] = search_result.misspell_original
            results[nocorrect_val]['misspell_corrected'] = search_result.misspell_corrected
            results[nocorrect_val]['nocorrect_param'] = search_result.nocorrect

        except Exception as e:
            print(f"  nocorrect={nocorrect_val}: ERROR - {e}")
            results[nocorrect_val] = None

    return results

def print_search_results(query, results):
    """Print formatted search results comparison."""
    print_separator('─', 100)

    # Header
    print(f"{'Category':<25} {'nocorrect=False':<30} {'nocorrect=True':<30}")
    print_separator('─', 100)

    if results[False] and results[True]:
        # Total counts
        for result_type in ['tracks', 'artists', 'albums', 'playlists', 'videos', 'podcasts', 'podcast_episodes', 'users']:
            count_false = results[False]['counts'].get(result_type, 0)
            count_true = results[True]['counts'].get(result_type, 0)

            if count_false > 0 or count_true > 0:
                diff = count_true - count_false
                diff_marker = f" (Δ{diff:+d})" if diff != 0 else ""
                print(f"{result_type:<25} {format_number(count_false):<30} {format_number(count_true):<30}{diff_marker}")

        print_separator('─', 100)

        # Misspelling info
        print(f"{'MISSPELLING INFO':<25}")
        print_separator('─', 100)

        for nocorrect_val in [False, True]:
            res = results[nocorrect_val]
            print(f"\nnocorrect={nocorrect_val}:")
            print(f"  Original query:  {res['misspell_original'] or 'N/A'}")
            print(f"  Corrected to:    {res['misspell_result'] or 'N/A'}")
            print(f"  Was corrected:   {res['misspell_corrected']}")
            print(f"  nocorrect param: {res['nocorrect_param']}")
    else:
        print("ERROR: Could not get results for comparison")

    print("\n")

def test_search_suggest(query_part):
    """Test search_suggest method."""
    print(f"\nTesting search_suggest with query part: '{query_part}'\n")
    print_separator('─', 100)

    try:
        suggestions = client.search_suggest(part=query_part)

        if suggestions is None or not suggestions.suggests:
            print("No suggestions found")
            return

        print(f"Found {len(suggestions.suggests)} suggestions:\n")

        # Group suggestions by type
        by_type = {}
        for i, suggest in enumerate(suggestions.suggests[:10], 1):
            if suggest not in by_type:
                by_type[suggest] = 0
            by_type[suggest] += 1
            print(f"  {i}. {suggest}")

    except Exception as e:
        print(f"ERROR: {e}")

    print("\n")

def test_quoted_queries(queries):
    """Test impact of quotes on search results."""
    print("\n" + "="*100)
    print("TESTING IMPACT OF QUOTES ON SEARCH RESULTS")
    print("="*100 + "\n")

    for query in queries[:2]:  # Test first 2 queries
        unquoted = query
        quoted = f'"{query}"'

        print(f"Comparing quoted vs unquoted: {query}\n")
        print_separator('─', 100)

        results_unquoted = search_and_compare(unquoted, 'track')
        results_quoted = search_and_compare(quoted, 'track')

        print(f"{'Parameter':<30} {'Unquoted':<30} {'Quoted':<30}")
        print_separator('─', 100)

        # Compare basic counts
        if results_unquoted[False] and results_quoted[False]:
            for result_type in ['tracks', 'artists', 'albums']:
                count_unquoted = results_unquoted[False]['counts'].get(result_type, 0)
                count_quoted = results_quoted[False]['counts'].get(result_type, 0)
                diff = count_quoted - count_unquoted
                diff_marker = f" (Δ{diff:+d})" if diff != 0 else ""
                print(f"{result_type:<30} {format_number(count_unquoted):<30} {format_number(count_quoted):<30}{diff_marker}")

        print("\n")

def main():
    """Main test function."""
    print("\n" + "="*100)
    print("YANDEX MUSIC SEARCH NOCORRECT PARAMETER TEST")
    print("="*100)

    # Test 1: Compare nocorrect=True/False
    print("\n" + "="*100)
    print("TEST 1: NOCORRECT PARAMETER IMPACT")
    print("="*100)

    for test_query in test_queries:
        print(f"\n{test_query['name']}:")
        results = search_and_compare(test_query['query'])
        print_search_results(test_query['query'], results)

    # Test 2: search_suggest
    print("\n" + "="*100)
    print("TEST 2: SEARCH_SUGGEST METHOD")
    print("="*100)

    test_search_suggest('граж')
    test_search_suggest('би')

    # Test 3: Impact of quotes
    test_quoted_queries([
        'Гражданская оборона',
        'Bi-2',
        'Pink Floyd',
    ])

    # Test 4: Detailed best result comparison
    print("\n" + "="*100)
    print("TEST 3: BEST RESULT COMPARISON")
    print("="*100 + "\n")

    query = 'Гражданская абарона'
    print(f"Query: '{query}' (misspelled)\n")

    for nocorrect_val in [False, True]:
        search_result = client.search(query, nocorrect=nocorrect_val, type_='all')

        print(f"\nnocorrect={nocorrect_val}:")
        print(f"  Misspell corrected: {search_result.misspell_corrected}")
        print(f"  Original: {search_result.misspell_original}")
        print(f"  Result:   {search_result.misspell_result}")

        if search_result.best:
            best = search_result.best
            print(f"  Best result type: {best.type}")
            if hasattr(best.result, 'name'):
                print(f"  Best result: {best.result.name}")
            elif hasattr(best.result, 'title'):
                print(f"  Best result: {best.result.title}")

    print("\n" + "="*100)
    print("✓ Tests completed successfully!")
    print("="*100 + "\n")

if __name__ == '__main__':
    main()
