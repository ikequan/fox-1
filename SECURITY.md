# Security

## Reporting a problem

Please **don't open a public issue** for a security problem. Report it
privately through GitHub: **Security → Report a vulnerability** on this
repository. Say what you found, how to reproduce it, and what it exposes.
You'll get a reply as soon as possible, and credit if you'd like it.

## How FOX-1 handles sensitive things

- **API keys** (Gemini, agent gateways) are typed in on the device or in the
  FOX-1 Hub at runtime. They are stored in the app's private storage and are
  never part of the source code or of any build.
- **FOX-1 Hub** (`http://<device-ip>:8080`) is off by default, except during
  first-time setup, when it stays on until setup is finished. Each time it is
  turned on it gets a new 6-digit PIN. Five wrong tries lock it for a minute,
  and each further lockout doubles that time. Signing in sets an HttpOnly,
  SameSite=Strict session cookie. The Hub turns itself off after 30
  minutes without a signed-in request, and every session ends with it. It
  uses **plain HTTP on your local network**, so use it only on networks you
  trust, or on the device's own hotspot.
- **Personal data** (notes, health, conversations, memory, call reports) is
  kept in the app's internal storage on the device. Nothing is sent to a
  FOX-1 server; there isn't one. While the assistant is awake, your voice
  (and camera frames when it looks) goes to the live model's API, and voice
  notes are sent to Gemini to be transcribed.
- **Phone calls:** things a caller says are stored as unverified *claims*,
  never as facts. A caller can't make the assistant "remember" something about
  you.
- **Optional WRITE_SECURE_SETTINGS** (granted only over ADB, by you): used for
  one thing — putting FOX-1's own accessibility service back when Android drops
  it. Other apps' services are left as they are.
- **The accessibility service** lets the assistant act on the screen. It does
  that only when asked, inside a conversation you started.

## Not yet done

- Release APKs are signed with debug keys. Build and sign your own if that
  matters to you.
- FOX-1 Hub has no TLS.
