#!/bin/bash
# Fixed tests - feedback should be an array

TOKEN_FILE="/home/chernysh/Projects/yandex/test/token.txt"
TOKEN=$(cat "$TOKEN_FILE" | head -1 2>/dev/null || echo "${YANDEX_TOKEN}")

if [ -z "$TOKEN" ]; then
    echo "ERROR: No token found"
    exit 1
fi

BASE_URL="https://api.music.yandex.net"

echo "CORRECTED /words/cards TESTS"
echo "======================================================================"
echo ""

# Test 1: POST /words/cards with various track sets
echo "TEST 1: POST /words/cards - Get word cards for tracks"
echo "--------------------------------------------------------------------"
echo ""
echo "Request: POST /words/cards"
echo 'Body: {"trackIds": ["49620451", "33835962", "21325043"], "viewedCards": []}'
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/words/cards" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "trackIds": ["49620451", "33835962", "21325043"],
    "viewedCards": []
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo "Response:"
echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
echo ""

# Test 2: POST /words/cards with viewedCards filter
echo "TEST 2: POST /words/cards - With viewedCards (exclude viewed)"
echo "--------------------------------------------------------------------"
echo ""
echo "Request: POST /words/cards"
echo 'Body: {"trackIds": ["49620451", "33835962"], "viewedCards": ["49620451"]}'
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/words/cards" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "trackIds": ["49620451", "33835962"],
    "viewedCards": ["49620451"]
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo "Response:"
echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
echo ""

# Test 3: PUT /words/cards/feedback - ARRAY format (fixed)
echo "TEST 3: PUT /words/cards/feedback - ARRAY format (CORRECTED)"
echo "--------------------------------------------------------------------"
echo ""
echo "Request: PUT /words/cards/feedback"
echo 'Body: {"feedback": [{"trackId": "49620451", "action": "like"}]}'
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/words/cards/feedback" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "feedback": [
      {"trackId": "49620451", "action": "like"}
    ]
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo "Response:"
if [ -z "$BODY" ]; then
    echo "  (empty response - likely 204 No Content)"
else
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
fi
echo ""

# Test 4: PUT /words/cards/feedback - Multiple feedbacks
echo "TEST 4: PUT /words/cards/feedback - Multiple feedbacks"
echo "--------------------------------------------------------------------"
echo ""
echo "Request: PUT /words/cards/feedback"
echo 'Body: {"feedback": [{"trackId": "49620451", "action": "like"}, {"trackId": "33835962", "action": "dislike"}]}'
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/words/cards/feedback" \
  -H "Authorization: OAuth $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "feedback": [
      {"trackId": "49620451", "action": "like"},
      {"trackId": "33835962", "action": "dislike"}
    ]
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo "Response:"
if [ -z "$BODY" ]; then
    echo "  (empty response - likely 204 No Content)"
else
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
fi
echo ""

# Test 5: Check with different action types
echo "TEST 5: PUT /words/cards/feedback - Different action types"
echo "--------------------------------------------------------------------"
echo ""

for action in "like" "dislike" "view" "skip"; do
    echo "Testing action: $action"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/words/cards/feedback" \
      -H "Authorization: OAuth $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"feedback\": [{\"trackId\": \"21325043\", \"action\": \"$action\"}]}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    echo "  HTTP Status: $HTTP_CODE"
done

echo ""
echo ""
echo "======================================================================"
echo "ANALYSIS & FINDINGS:"
echo "======================================================================"
