#!/bin/bash
# Verbose curl tests with full response details

TOKEN_FILE="/home/chernysh/Projects/yandex/test/token.txt"
if [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE" | head -1)
else
    TOKEN="${YANDEX_TOKEN}"
fi

if [ -z "$TOKEN" ]; then
    echo "ERROR: No token found"
    exit 1
fi

BASE_URL="https://api.music.yandex.net"

echo "VERBOSE TEST OF /words/cards ENDPOINTS"
echo "======================================================================"
echo "Token: ${TOKEN:0:20}..."
echo ""

# Test 1: POST /words/cards - with verbose output
echo "TEST 1: POST /words/cards with verbose output"
echo "======================================================================"
echo ""
echo "Request:"
echo "  URL: POST $BASE_URL/words/cards"
echo "  Headers: Authorization, Content-Type: application/json"
echo "  Body:"
cat << 'EOF'
{
  "trackIds": ["49620451", "33835962", "21325043"],
  "viewedCards": []
}
EOF
echo ""
echo "Response (with HTTP status):"
echo "---"

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/words/cards" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Yandex-Music-Client: WindowsMusicAPI/5.98" \
  -d '{
    "trackIds": ["49620451", "33835962", "21325043"],
    "viewedCards": []
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo "Response Body:"
if [ -z "$BODY" ]; then
    echo "  (empty response)"
else
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
fi
echo ""
echo ""

# Test 2: PUT /words/cards/feedback
echo "TEST 2: PUT /words/cards/feedback with verbose output"
echo "======================================================================"
echo ""
echo "Request:"
echo "  URL: PUT $BASE_URL/words/cards/feedback"
echo "  Body:"
cat << 'EOF'
{
  "feedback": {
    "trackId": "49620451",
    "action": "like"
  }
}
EOF
echo ""
echo "Response (with HTTP status):"
echo "---"

RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/words/cards/feedback" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Yandex-Music-Client: WindowsMusicAPI/5.98" \
  -d '{
    "feedback": {
      "trackId": "49620451",
      "action": "like"
    }
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo "Response Body:"
if [ -z "$BODY" ]; then
    echo "  (empty response)"
else
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
fi
echo ""
echo ""

# Test 3: Try with different seed parameters (in case these are wave/vibe related)
echo "TEST 3: Hypothesis - Check if related to rotor/wave endpoints"
echo "======================================================================"
echo ""
echo "Request:"
echo "  URL: GET $BASE_URL/rotor/wave/settings?seeds=mood:energetic"
echo ""
echo "Response:"
echo "---"

RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/rotor/wave/settings?seeds=mood:energetic" \
  -H "Authorization: OAuth $TOKEN" \
  -H "X-Yandex-Music-Client: WindowsMusicAPI/5.98")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo "Response (first 2000 chars):"
if [ -z "$BODY" ]; then
    echo "  (empty response)"
else
    echo "$BODY" | head -c 2000
    if [ ${#BODY} -gt 2000 ]; then
        echo "... [truncated]"
    fi
fi
echo ""
echo ""

echo "======================================================================"
echo "INVESTIGATION NOTES:"
echo "======================================================================"
echo "If /words/cards returns:"
echo "  - 404: endpoint doesn't exist or requires different parameters"
echo "  - 400: invalid request format"
echo "  - 403: forbidden/requires permissions"
echo "  - 200 with data: returns card/lyric data"
echo "  - 204: successful but no content to return"
echo ""
echo "Compare wave/rotor responses to understand relationship"
