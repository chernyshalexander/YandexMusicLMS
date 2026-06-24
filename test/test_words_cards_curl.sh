#!/bin/bash
# Simple curl tests for /words/cards endpoints
# Requires YANDEX_TOKEN environment variable or test/token.txt

set -e

# Get token
TOKEN_FILE="/home/chernysh/Projects/yandex/test/token.txt"
if [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE" | head -1)
else
    TOKEN="${YANDEX_TOKEN}"
fi

if [ -z "$TOKEN" ]; then
    echo "ERROR: No token found. Set YANDEX_TOKEN or add token to test/token.txt"
    exit 1
fi

echo "Testing /words/cards endpoints"
echo "========================================================================"
echo "Token: ${TOKEN:0:10}..."
echo ""

# Test 1: POST /words/cards with track IDs
echo "TEST 1: POST /words/cards { trackIds, viewedCards }"
echo "--------------------------------------------------------------------"
echo "Request:"
cat << 'EOF'
{
  "trackIds": ["49620451", "33835962", "21325043"],
  "viewedCards": []
}
EOF
echo ""
echo "Response:"

curl -s -X POST "https://api.music.yandex.net/words/cards" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Yandex-Music-Client: WindowsMusicAPI/5.98" \
  -d '{
    "trackIds": ["49620451", "33835962", "21325043"],
    "viewedCards": []
  }' | jq '.' 2>/dev/null || echo "Could not parse JSON response"

echo ""
echo ""

# Test 2: POST /words/cards with viewedCards filter
echo "TEST 2: POST /words/cards with viewedCards (exclude viewed)"
echo "--------------------------------------------------------------------"
echo "Request:"
cat << 'EOF'
{
  "trackIds": ["49620451", "33835962"],
  "viewedCards": ["49620451"]
}
EOF
echo ""
echo "Response:"

curl -s -X POST "https://api.music.yandex.net/words/cards" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Yandex-Music-Client: WindowsMusicAPI/5.98" \
  -d '{
    "trackIds": ["49620451", "33835962"],
    "viewedCards": ["49620451"]
  }' | jq '.' 2>/dev/null || echo "Could not parse JSON response"

echo ""
echo ""

# Test 3: PUT /words/cards/feedback
echo "TEST 3: PUT /words/cards/feedback { feedback }"
echo "--------------------------------------------------------------------"
echo "Request (try marking card as viewed/liked):"
cat << 'EOF'
{
  "feedback": {
    "trackId": "49620451",
    "action": "like"
  }
}
EOF
echo ""
echo "Response:"

curl -s -X PUT "https://api.music.yandex.net/words/cards/feedback" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Yandex-Music-Client: WindowsMusicAPI/5.98" \
  -d '{
    "feedback": {
      "trackId": "49620451",
      "action": "like"
    }
  }' | jq '.' 2>/dev/null || echo "Could not parse JSON response or endpoint returned empty"

echo ""
echo ""

# Test 4: Try different feedback format
echo "TEST 4: PUT /words/cards/feedback with array of feedbacks"
echo "--------------------------------------------------------------------"
echo "Request:"
cat << 'EOF'
{
  "feedback": [
    {"trackId": "49620451", "action": "like"},
    {"trackId": "33835962", "action": "dislike"}
  ]
}
EOF
echo ""
echo "Response:"

curl -s -X PUT "https://api.music.yandex.net/words/cards/feedback" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Yandex-Music-Client: WindowsMusicAPI/5.98" \
  -d '{
    "feedback": [
      {"trackId": "49620451", "action": "like"},
      {"trackId": "33835962", "action": "dislike"}
    ]
  }' | jq '.' 2>/dev/null || echo "Could not parse JSON response or endpoint returned empty"

echo ""
echo ""
echo "========================================================================"
echo "Test complete. Check responses above for insights."
