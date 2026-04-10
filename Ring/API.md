# Talk9 Registration Portal — API Reference

All endpoints accept and return `application/json`. All are `POST`.

## Common Response Format

**Success**
```json
{ "ok": true, ...fields }
```

**Error**
```json
{ "ok": false, "error": "api.err_otp_wrong" }
```

Error values are dot-notation i18n keys (e.g. `api.err_otp_wrong`). The frontend translates them via `useTranslation`. Raw strings are passed through as-is.

---

## Tokens

All multi-step flows use a stateless HMAC-SHA256 signed token:

```
base64(JSON payload) + "." + HMAC-SHA256(base64, TOKEN_SECRET)
```

The token is opaque to the client. Pass it back verbatim in the next step.

---

## Register Flow

```
[1] POST /api/send_otp        ← username, phone, password
        ↓  token + masked_phone
[2] POST /api/verify_otp      ← token, otp
        ↓  register_token
[3] POST /api/set_display_name  ← register_token, display_name (optional)
        ↓  done
```

### Step 1 — Send OTP

`POST /api/send_otp`

**Request**
```json
{
  "username":     "john_doe",
  "country_code": "60",
  "phone":        "123456789",
  "password":     "mypassword",
  "password2":    "mypassword"
}
```

| Field | Notes |
|---|---|
| `username` | Lowercase letters, numbers, `.` `_` `-`, 3–32 characters |
| `country_code` | Digits only, no `+` (e.g. `"60"` for Malaysia) |
| `phone` | Local number without country code, digits only |
| `password` | Minimum 8 characters |
| `password2` | Must match `password` |

**Response — success**
```json
{
  "ok": true,
  "token": "eyJ0eXBlIjoib3RwIi...<hmac>",
  "masked_phone": "+601***6789"
}
```

**Response — error examples**
```json
{ "ok": false, "error": "api.err_username_invalid" }
{ "ok": false, "error": "api.err_no_country_code" }
{ "ok": false, "error": "api.err_invalid_phone" }
{ "ok": false, "error": "api.err_invalid_country_code" }
{ "ok": false, "error": "api.err_phone_format" }
{ "ok": false, "error": "api.err_password_too_short" }
{ "ok": false, "error": "api.err_password_mismatch" }
{ "ok": false, "error": "api.err_rate_limit_daily" }
{ "ok": false, "error": "api.err_otp_send_failed" }
```

---

### Step 2 — Verify OTP

`POST /api/verify_otp`

**Request**
```json
{
  "token": "eyJ0eXBlIjoib3RwIi...<hmac>",
  "otp":   "123456"
}
```

| Field | Notes |
|---|---|
| `token` | Token returned from Step 1 |
| `otp` | 6-digit code received via SMS; expires in 5 minutes |

**Response — success**

Creates the LDAP account and returns a short-lived token for the display name step.
```json
{
  "ok": true,
  "register_token": "eyJ0eXBlIjoicmVnaXN0ZXIi...<hmac>"
}
```

`register_token` expires in **10 minutes**.

**Response — error examples**
```json
{ "ok": false, "error": "api.err_missing_token" }
{ "ok": false, "error": "api.err_otp_format" }
{ "ok": false, "error": "api.err_token_invalid" }
{ "ok": false, "error": "api.err_otp_expired" }
{ "ok": false, "error": "api.err_otp_wrong" }
```

---

### Step 2b — Resend OTP (optional)

`POST /api/resend_otp`

Generates a new OTP and invalidates the old one by reissuing the token.

**Request**
```json
{
  "token": "eyJ0eXBlIjoib3RwIi...<hmac>"
}
```

**Response — success**
```json
{
  "ok": true,
  "token": "eyJ0eXBlIjoib3RwIi...<new_hmac>",
  "masked_phone": "+601***6789"
}
```

Use the new `token` for subsequent verify or resend calls.

**Response — error examples**
```json
{ "ok": false, "error": "api.err_token_invalid" }
{ "ok": false, "error": "api.err_rate_limit_daily" }
{ "ok": false, "error": "api.err_otp_send_failed" }
```

---

### Step 3 — Set Display Name (optional)

`POST /api/set_display_name`

**Request**
```json
{
  "register_token": "eyJ0eXBlIjoicmVnaXN0ZXIi...<hmac>",
  "display_name":   "John Doe"
}
```

`display_name` is optional. If empty or omitted, the username is used as the display name (no LDAP write is made).

**Response — success (with display name)**
```json
{
  "ok": true,
  "display_name": "John Doe"
}
```

**Response — success (display name skipped)**
```json
{
  "ok": true
}
```

**Response — error examples**
```json
{ "ok": false, "error": "api.err_token_invalid" }
{ "ok": false, "error": "api.err_token_expired" }
```

---

## Reset Password Flow

```
[1] POST /api/reset_send_otp     ← username, new password
        ↓  token + masked_phone
[2] POST /api/reset_verify_otp   ← token, otp
        ↓  done (password updated in LDAP)
```

> **Anti-enumeration:** Step 1 always returns `ok: true` even if the username does not exist. If the user doesn't exist, an OTP is generated but never sent; the token is issued but will never verify correctly (unless the master code is used). `masked_phone` is `"***"` for non-existent users.

### Step 1 — Send OTP

`POST /api/reset_send_otp`

**Request**
```json
{
  "username":  "john_doe",
  "password":  "newpassword",
  "password2": "newpassword"
}
```

| Field | Notes |
|---|---|
| `username` | The username to reset |
| `password` | New password, minimum 8 characters |
| `password2` | Must match `password` |

**Response — success (user exists)**
```json
{
  "ok": true,
  "token": "eyJ0eXBlIjoicmVzZXRfb3RwIi...<hmac>",
  "masked_phone": "+601***6789"
}
```

**Response — success (user does not exist)**
```json
{
  "ok": true,
  "token": "eyJ0eXBlIjoicmVzZXRfb3RwIi...<hmac>",
  "masked_phone": "***"
}
```

The frontend shows a neutral message ("If that username is registered, a code will be sent…") when `masked_phone` is `"***"`.

**Response — error examples**
```json
{ "ok": false, "error": "api.err_username_required" }
{ "ok": false, "error": "api.err_new_password_too_short" }
{ "ok": false, "error": "api.err_password_mismatch" }
{ "ok": false, "error": "api.err_rate_limit" }
```

---

### Step 2 — Verify OTP

`POST /api/reset_verify_otp`

**Request**
```json
{
  "token": "eyJ0eXBlIjoicmVzZXRfb3RwIi...<hmac>",
  "otp":   "123456"
}
```

**Response — success**

Updates the LDAP password (if user exists) and returns success regardless.
```json
{
  "ok": true
}
```

**Response — error examples**
```json
{ "ok": false, "error": "api.err_missing_token" }
{ "ok": false, "error": "api.err_otp_format" }
{ "ok": false, "error": "api.err_token_invalid" }
{ "ok": false, "error": "api.err_otp_expired" }
{ "ok": false, "error": "api.err_otp_wrong" }
```

---

### Step 2b — Resend OTP (optional)

`POST /api/reset_resend_otp`

**Request**
```json
{
  "token": "eyJ0eXBlIjoicmVzZXRfb3RwIi...<hmac>"
}
```

**Response — success (user exists)**
```json
{
  "ok": true,
  "token": "eyJ0eXBlIjoicmVzZXRfb3RwIi...<new_hmac>",
  "masked_phone": "+601***6789"
}
```

**Response — success (user does not exist)**
```json
{
  "ok": true,
  "token": "eyJ0eXBlIjoicmVzZXRfb3RwIi...<new_hmac>",
  "masked_phone": "***"
}
```

**Response — error examples**
```json
{ "ok": false, "error": "api.err_token_invalid" }
{ "ok": false, "error": "api.err_rate_limit" }
```

---

## Error Code Reference

| Key | Meaning |
|---|---|
| `api.err_username_invalid` | Username format invalid (lowercase, numbers, `.` `_` `-`, 3–32 chars) |
| `api.err_no_country_code` | Country code missing |
| `api.err_invalid_phone` | Phone number too short or too long |
| `api.err_invalid_country_code` | Country code not in allowed list |
| `api.err_phone_format` | E.164 format check failed |
| `api.err_password_too_short` | Password under 8 characters |
| `api.err_password_mismatch` | `password` and `password2` differ |
| `api.err_new_password_too_short` | New password under 8 characters (reset flow) |
| `api.err_username_required` | Username field empty (reset flow) |
| `api.err_rate_limit_daily` | Phone has hit the daily OTP send cap (default: 5/day) |
| `api.err_rate_limit` | General rate limit exceeded |
| `api.err_otp_send_failed` | SMS gateway returned an error |
| `api.err_missing_token` | `token` field missing from request |
| `api.err_otp_format` | OTP is not exactly 6 digits |
| `api.err_token_invalid` | Token signature invalid or wrong type |
| `api.err_otp_expired` | Token `expires` timestamp has passed (5-minute window) |
| `api.err_otp_wrong` | OTP does not match |
| `api.err_token_expired` | `register_token` expired (10-minute window) |
| `api.err_request_failed` | Generic request failure (frontend fallback) |
| `api.err_network` | Network/fetch error (frontend only) |
