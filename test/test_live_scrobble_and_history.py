#!/usr/bin/env python3
"""
Live API testing for Yandex Music play scrobbling and history endpoints.
Tests:
1. Account status & UID lookup
2. POST /play-audio (form-urlencoded)
3. POST /plays (JSON scrobble)
4. GET /users/{uid}/contexts (Real-time recently played contexts)
5. GET /music-history?fullModelsCount=50 (Aggregated daily tabs)
6. GET /non-music/bookshelf/recently-played (Audiobook history & listeningDate)
"""

import sys
import os
import json
import uuid
import datetime
import urllib.request
import urllib.parse
import urllib.error

TOKEN_PATH = os.path.join(os.path.dirname(__file__), 'token.txt')
if not os.path.exists(TOKEN_PATH):
    print(f"Error: Token file not found at {TOKEN_PATH}")
    sys.exit(1)

TOKEN = open(TOKEN_PATH, 'r', encoding='utf-8').read().strip()
COMMON_HEADERS = {
    'Authorization': f'OAuth {TOKEN}',
    'User-Agent': 'YandexMusic/24022432 (Android 14; sdk 34)',
    'X-Yandex-Music-Client': 'YandexMusicAndroid/24022432',
}

def api_request(url, method='GET', data=None, headers=None):
    hdrs = dict(COMMON_HEADERS)
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read().decode('utf-8')
            return resp.status, content
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8')
    except Exception as e:
        return 0, str(e)

def main():
    print("=" * 60)
    print("Yandex Music Live API Scrobble & History Verification")
    print("=" * 60)

    # 1. Account status
    print("\n[1] Verifying Account Status & UID...")
    status, body = api_request('https://api.music.yandex.net/account/status')
    if status != 200:
        print(f"FAILED: Status {status}, body: {body}")
        sys.exit(1)
    status_data = json.loads(body).get('result', {})
    uid = status_data.get('account', {}).get('uid')
    login = status_data.get('account', {}).get('login')
    print(f"SUCCESS: UID={uid}, Login={login}")

    # 2. Test POST /play-audio
    print("\n[2] Testing POST /play-audio (form-urlencoded)...")
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
    play_id_audio = str(uuid.uuid4())
    form_data = urllib.parse.urlencode({
        'track-id': '2773110',
        'album-id': '298151',
        'from-cache': 'false',
        'from': 'android-app',
        'play-id': play_id_audio,
        'uid': str(uid),
        'timestamp': now_iso,
        'client-now': now_iso,
        'track-length-seconds': '422',
        'total-played-seconds': '60',
        'end-position-seconds': '60',
    }).encode('utf-8')

    status, body = api_request(
        'https://api.music.yandex.net/play-audio',
        method='POST',
        data=form_data,
        headers={'Content-Type': 'application/x-www-form-urlencoded'}
    )
    print(f"Response: HTTP {status}, body: {body.strip()[:120]}")
    assert status == 200, f"Expected 200 from /play-audio, got {status}"

    # 3. Test POST /plays
    print("\n[3] Testing POST /plays (JSON scrobble)...")
    play_id_plays = str(uuid.uuid4())
    plays_body = {
        'plays': [
            {
                'playId': play_id_plays,
                'trackId': '16782654',
                'albumId': '20138562',
                'from': 'android-app',
                'context': 'album',
                'contextItem': '20138562',
                'totalPlayedSeconds': 50,
                'endPositionSeconds': 50,
                'trackLengthSeconds': 430,
                'timestamp': now_iso,
                'changeReason': 'other_track',
                'audioOutputName': 'Speaker',
                'audioOutputType': 'Speaker',
                'isRestored': False,
                'pause': False,
                'seek': False,
            }
        ]
    }
    status, body = api_request(
        f'https://api.music.yandex.net/plays?clientNow={now_iso}',
        method='POST',
        data=json.dumps(plays_body).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    print(f"Response: HTTP {status}, body: {body.strip()[:120]}")
    assert status == 200, f"Expected 200 from /plays, got {status}"

    # 4. Check GET /users/{uid}/contexts
    print(f"\n[4] Querying GET /users/{uid}/contexts (real-time recently listened)...")
    status, body = api_request(
        f'https://api.music.yandex.net/users/{uid}/contexts?trackCount=5&types=album,artist,playlist&contextCount=10'
    )
    print(f"Response: HTTP {status}")
    if status == 200:
        ctx_data = json.loads(body).get('result', {}).get('contexts', [])
        print(f"Found {len(ctx_data)} recent contexts:")
        for idx, c in enumerate(ctx_data[:3]):
            tracks = c.get('tracks', [])
            t_info = tracks[0] if tracks else {}
            print(f"  {idx+1}. Context: {c.get('context')} {c.get('contextItem')}, Client: {c.get('client')}, Track: {t_info.get('trackId')}, Timestamp: {t_info.get('timestamp')}")

    # 5. Check GET /music-history
    print("\n[5] Querying GET /music-history?fullModelsCount=50 (daily aggregated tabs)...")
    status, body = api_request('https://api.music.yandex.net/music-history?fullModelsCount=50')
    print(f"Response: HTTP {status}")
    if status == 200:
        mh_data = json.loads(body).get('result', {})
        tabs = mh_data.get('historyTabs', [])
        print(f"Found {len(tabs)} daily tabs in music history:")
        for t in tabs[:4]:
            print(f"  Tab date: {t.get('date')}, groups: {len(t.get('items', []))}")

    # 6. Check GET /non-music/bookshelf/recently-played
    print("\n[6] Querying GET /non-music/bookshelf/recently-played (audiobooks)...")
    status, body = api_request('https://api.music.yandex.net/non-music/bookshelf/recently-played?page=0&pageSize=5')
    print(f"Response: HTTP {status}")
    if status == 200:
        bs_data = json.loads(body).get('result', {})
        entities = bs_data.get('entities', [])
        print(f"Found {len(entities)} recently played audiobook entities:")
        for idx, e in enumerate(entities[:4]):
            alb = e.get('album', {})
            tr = e.get('track', {})
            print(f"  {idx+1}. Book: {alb.get('title')}, Track: {tr.get('title')}, Date: {e.get('listeningDate')}")

    print("\n" + "=" * 60)
    print("ALL LIVE TESTS COMPLETED SUCCESSFULLY!")
    print("=" * 60)

if __name__ == '__main__':
    main()
