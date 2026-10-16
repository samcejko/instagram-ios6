# Realtime connection (MQTToT): findings, 2026-10-16

How the Android app (the one Gramify imitates) gets new DMs, read receipts and typing without polling. Sources:
Nerixyz/instagram_mqtt (TypeScript, `src/realtime`, `src/mqttot`) and mautrix/instagram (Python, `mauigpapi/mqtt`,
the last Android-API bridge before mautrix-meta moved to the web protocol). No traffic was sent for this note.

## Transport

- `edge-mqtt.facebook.com:443`, TLS (plain TLS, not WebSocket), MQTT 3.1 framing (protocol level **3**).
- CONNECT is non-standard ("MQTToT"):
  `0x10 <remaining length> 00 06 "MQTToT" 03 C2 <keepalive u16> <payload>`.
  Flags 0xC2 = username + password + clean session, but there are no username/password fields: the payload is the
  zlib stream (level 9) of a Thrift-compact `RealtimeConfig`, appended **without** a length prefix.
- CONNACK `0x20`: ack flags, return code (0 ok, 4 bad user/password, 5 not authorized); a realtime CONNACK may carry
  a 2-byte-length payload after that (skip it).
- PUBLISH topics are the **numeric ids as strings** ("146", not "/ig_message_sync"). Every payload in both
  directions is zlib-compressed (mautrix inflates every incoming payload; instagram_mqtt tries). Our publishes: QoS 1
  (server answers PUBACK); incoming QoS 1 publishes need a PUBACK from us.
- Keepalive: instagram_mqtt sends 20 s, mautrix 60 s. Plan: 60 in CONNECT, PINGREQ after 30 s of quiet, connection
  dead when no PINGRESP within 20 s.

## RealtimeConfig (Thrift compact)

Top level: 1 clientIdentifier (binary, phone_id[:20]), 2 willTopic, 3 willMessage (unset), 4 clientInfo (struct),
5 password (binary), 6 getDiffsRequests (unset), 9 zeroRatingTokenHash (unset), 10 appSpecificInfo (map
binary→binary). (instagram_mqtt numbers 9/10 from the decompiled app; mautrix's autospec numbers them 7/8, so its
map most likely went to a field the server skips: the map is not critical.)

clientInfo: 1 userId i64 (ds_user_id), 2 userAgent (the app's UA), 3 clientCapabilities i64 183,
4 endpointCapabilities i64 0, 5 publishFormat i32 1, 6 noAutomaticForeground bool, 7 makeUserAvailableInForeground
bool, 8 deviceId (phone_id), 9 isInitiallyForeground bool, 10 networkType i32 1 (Wi-Fi), 11 networkSubtype i32 0,
12 clientMqttSessionId i64 (ms & 0xFFFFFFFF), 14 subscribeTopics list<i32>, 15 clientType "cookie_auth",
16 appId i64 567067343352427, 20 deviceSecret "", 21 clientStack byte 3. (13, 17-19, 22-26 unset.)
Foreground values: instagram_mqtt (a foreground client) false/true/true, mautrix (a background bridge) true/false/false.
Gramify connects only while it is on screen, so it uses instagram_mqtt's.

subscribeTopics: instagram_mqtt `[88, 135, 149, 150, 133, 146]`; mautrix adds 244 /rs_req, 245 /rs_resp, 274
/t_rtc_log, 179 /ls_resp, 34 /pp. Gramify: instagram_mqtt's list + 34 (the server's "reconnect" nudge).

appSpecificInfo: app_version, X-IG-Capabilities, everclear_subscriptions (JSON of query ids:
inapp_notification_subscribe_comment / _comment_mention_and_reply 17899377895239777,
video_call_participant_state_delivery 17977239895057311, presence_subscribe 17846944882223835), User-Agent,
Accept-Language, platform "android", ig_mqtt_route "django", pubsub_msg_type_blacklist "direct, typing_type",
auth_cache_enabled "0".

## Auth with the Bearer IGT:2 token

The token's base64 is JSON `{"ds_user_id": "...", "sessionid": "<id>%3A<...>"}`. Both projects moved to it:
- mautrix-instagram: `password = "authorization=" + <the whole Authorization header>`, i.e.
  `authorization=Bearer IGT:2:<b64>`.
- instagram_mqtt: `password = "sessionid=" + parsedAuthorization.sessionid` (decoded from that JSON, cookie-encoded
  as it is), falling back to the sessionid cookie.

Gramify: `authorization=` first; on CONNACK 4/5 one try with `sessionid=` a few seconds later; the form that worked
is remembered; both refused = no more tries until the next app start or 30 min, polling only. userId must be the
token's ds_user_id. Nothing of the password is ever logged.

## After CONNACK

All published QoS 1 (zlib):
- `149` /ig_realtime_sub `{"sub": ["1/graphqlsubscriptions/<query id>/{\"input_data\": {...}}", ...]}`: typing
  (17867973967082385, input_data {user_id}), direct status (17854499065530643, {client_subscription_id: uuid}),
  app presence (17846944882223835, {client_subscription_id}).
- `88` /pubsub `{"sub": ["ig/u/v1/<user id>"]}` (skywalker; typing arrives here in mautrix).
- `134` /ig_sub_iris `{"seq_id", "snapshot_at_ms", "snapshot_app_version", "timezone_offset" (s),
  "subscription_type": "message"}` with seq_id + snapshot_at_ms from the **top level of direct_v2/inbox/**.
  Answer on `135`: `{"succeeded", "error_type", "error_message", "latest_seq_id", "subscribed_at_ms"}`; when
  latest_seq_id is newer the server replays the gap over 146. An error = fetch the inbox again for a fresh pair.

## What arrives

- `146` /ig_message_sync: JSON array of `{"event": "patch", "data": [{"op", "path", "value"}], "seq_id",
  "message_type", "mutation_token", "realtime"}`. `value` is a JSON **string**. Remember the highest seq_id for the
  next subscribe. Paths:
  - `/direct_v2/threads/<t>/items/<item>` op add (value = the item, same shape as direct_v2/threads items), replace
    (edited, reactions: `.../items/<i>/reactions/<type>/<user>`), remove (unsent).
  - `/direct_v2/threads/<t>/participants/<user>/has_seen` op replace, value `{"timestamp": "<µs>", "item_id"}`:
    a read receipt.
  - `/direct_v2/inbox/threads/<t>` add/replace/remove: thread metadata (new chat, title, mute, removed).
  - others (admin_user_ids, approval_required_for_new_members, thread image ...): only "the inbox changed".
- `88` /pubsub and `149` /ig_realtime_sub: Thrift `{1: topic (binary or i32), 2: payload (binary JSON)}`; topic
  "direct" (149) and pubsub carry `{"event": "patch", "data": [{"op", "path":
  "/direct_v2/threads/<t>/activity_indicator_id/<id>", "value": "{\"timestamp\", \"sender_id\", \"ttl\": 12000,
  \"activity_status\": 0 off | 1 text | 2 visual}"}]}` = typing.
- `150` /t_region_hint, `133` send responses: ignored. `34` /pp: mautrix reconnects on it.

## Calls

Not documented anywhere public (no write-up, no open client). What the sources show: the Android client subscribes
to `/rs_req` (244), `/rs_resp` (245) and `/t_rtc_log` (274) on this same connection (mautrix's list; "rs" = Meta's
rsys calling stack) and asks for the GraphQL `video_call_participant_state_delivery` (17977239895057311) through
everclear_subscriptions. So call **signalling very likely travels over this same edge-mqtt connection** (Thrift/
rsys payloads, format unknown), while the media goes through Meta's WebRTC-like stack (ICE/SRTP, own TURN). Not
verified. Gramify does not subscribe to 244/245/274 now (a client that never answers should not be offered calls);
a later step can add them in debug builds and log topic + size only during a test call to learn the format.

## Risks

- Meta is moving Instagram DMs to the Messenger backend (mautrix-meta uses the web Lightspeed protocol instead);
  the account's chats still come over direct_v2 REST, so iris sync should still carry them, but this is unproven
  until a device test. Polling stays as the fallback either way.
- The test account is restricted: one connection per foreground, backoff 2 s → 5 min, auth failures stop retrying.
