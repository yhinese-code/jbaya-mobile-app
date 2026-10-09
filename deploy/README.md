# Going live on your own server in Iraq

Everything runs on one Ubuntu server with Docker: PostgreSQL (all the data), the backend API, and Caddy (automatic
HTTPS + the office portals as a website). Collectors use the Android app; offices can use the website or the app.

## 1. What you need first

| Item | Why |
|---|---|
| Ubuntu 22.04 or 24.04 server, 8+ cores, 32GB+ RAM, 2× NVMe in RAID 1 | the system + database + photos |
| UPS + generator line, and a second internet line if possible | collectors and Command depend on it all day |
| A **public IP address** with ports 80 and 443 open | HTTPS certificates and the Meta WhatsApp webhook must reach the server. Many Iraqi lines share one IP (CGNAT): ask the ISP for a dedicated public IP. No public IP? Use the Cloudflare Tunnel option (section 6). |
| Two domain names pointing at that IP, e.g. `app.jibaya.iq` and `api.jibaya.iq` | portals and API |
| The company WhatsApp Business number in Meta (Cloud API) | citizens' codes and receipts |

## 2. Install (one time)

```bash
# copy the project to the server (git clone, or copy the folder), then:
cd jbaya-mobile-app/deploy
sudo bash install.sh
```

The script asks for the two domains and the WhatsApp number. It then:

1. installs Docker and a firewall (only SSH, 80, 443);
2. writes `deploy/.env` with new random secrets (keep this file safe; it is also copied into each backup);
3. starts everything and creates the first accounts;
4. schedules the nightly backup at 02:30.

**Right after installing:**

1. Log into **TECH-01 first**. The first device that logs into it is approved automatically.
   The password is `SEED_PASSWORD` in `deploy/.env`.
2. Approve the other staff devices from the tech panel (الأجهزة).
3. Change every account's password from the tech panel (الحسابات).
4. In the tech panel (الإعدادات والمعادلات) set the real values:
   - fee, tariffs, cash cap, taxes and social security;
   - leave days and shift time;
   - draw the real sectors and assign the staff.
5. Remove or suspend the demo accounts and the demo sector you don't need.

## 3. The office portals (website)

Build the web version on your laptop and copy it to the server:

```bash
flutter build web --release --no-web-resources-cdn --dart-define=API_URL=https://api.jibaya.iq
# copy the content of build/web/ into deploy/web/ on the server (scp, WinSCP or a USB disk)
```

No restart is needed: Caddy serves the new files immediately at `https://app.jibaya.iq`.

## 4. The Android app

1. **Create your release key once and keep it forever.** Losing it means phones can't update the app.

   ```bash
   keytool -genkey -v -keystore C:/keys/jibaya-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias jibaya
   ```

2. **Create `android/key.properties`.** It is git-ignored; never commit it.

   ```
   storePassword=...
   keyPassword=...
   keyAlias=jibaya
   storeFile=C:/keys/jibaya-release.jks
   ```

3. **Build the app:**

   ```bash
   flutter build apk --release --dart-define=API_URL=https://api.jibaya.iq
   # → build/app/outputs/flutter-apk/app-release.apk  (share it, or publish on Google Play as com.jbokertech.jibaya)
   ```

Release builds only talk HTTPS. Debug builds still allow `http://<laptop-ip>:8000` for testing on the same Wi-Fi.

## 5. WhatsApp (Meta Cloud API)

1. In Meta Business Manager, create and get approved the 3 templates listed in `jbaya-backend/README.md`. They're only used when a citizen can't message you first.
2. **Set the webhook:** in the Meta app go to WhatsApp → Configuration → Webhook and enter:
   - Callback URL: `https://api.jibaya.iq/whatsapp/webhook`
   - Verify token: the `WHATSAPP_VERIFY_TOKEN` value from `deploy/.env`
   - Subscribe to `messages`
3. **Fill `deploy/.env`:**
   - `WHATSAPP_TOKEN` (a permanent system-user token);
   - `WHATSAPP_PHONE_NUMBER_ID`;
   - `WHATSAPP_APP_SECRET` (App settings → Basic);
   - change `WHATSAPP_MODE=live`.
4. Restart the API: `cd deploy && sudo docker compose up -d`.
5. **Test with one real phone:** register a house and pay a small bill. Check that the citizen's message triggers the free code and that the receipt arrives.

Until step 3 is done, everything works in test mode: messages are printed in the API log (`sudo docker compose logs -f api`), and the tech panel has a "simulate citizen message" box.

## 6. No public IP? Cloudflare Tunnel

1. Create a free Cloudflare account and add your domain to it.
2. Create a tunnel (Zero Trust → Networks → Tunnels).
3. In the tunnel, add two public hostnames (`app.<domain>` and `api.<domain>`), both pointing to `http://caddy:80`.
4. Put the tunnel token in `CLOUDFLARE_TUNNEL_TOKEN` in `deploy/.env`.
5. Switch Caddy to plain http behind the tunnel, and start the tunnel:

   ```bash
   cp Caddyfile.tunnel Caddyfile
   sudo docker compose --profile tunnel up -d
   ```

Cloudflare provides HTTPS. `Caddyfile.tunnel` also passes on the real client IP (`CF-Connecting-IP`), so Command's IP allow-list keeps working.

## 7. Backups and restore

- **Every night at 02:30:** a database dump, the photos and documents, and a copy of `.env` go to `deploy/backups/`. They are kept for 14 days.
- **Keep a copy off the server.** If the disk dies, backups on the same machine die with it. Do one of these:
  - set `BACKUP_COPY_DIR=/mnt/usb` (or a second server path) in `/etc/cron.d/jibaya-backup`;
  - or copy `deploy/backups/` somewhere else weekly.
- **Restore:** `sudo bash restore.sh backups/db-YYYY-MM-DD-HHMM.dump backups/storage-YYYY-MM-DD-HHMM.tar.gz`. It asks you to type YES.

## 8. Updating to a new version

```bash
cd jbaya-mobile-app/deploy && sudo bash update.sh
```

It backs up first, pulls the code, rebuilds and restarts. The database schema updates itself on start. Then upload the new web build (section 3) and, if the app changed, give the collectors the new APK.

## 9. Before the first real day: checklist

- [ ] HTTPS works on both domains; `https://api.<domain>/health` shows `{"status":"ok"}`
- [ ] All demo passwords changed; demo accounts removed or suspended
- [ ] Real sectors drawn; staff assigned to sectors and supervisors
- [ ] Fee, tariffs, cash cap, taxes and the 35% rule mode set (leave `not_set` until the contract is confirmed)
- [ ] WhatsApp live and tested with a real phone (free code after the citizen's message, paid fallback, receipt)
- [ ] Every collector phone approved in الأجهزة; each one logged in once
- [ ] Off-server backup copy configured and one restore tested on a spare machine
- [ ] UPS and generator tested with the server running
