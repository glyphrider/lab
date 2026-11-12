# Open items

Deferred decisions from the 2026-11-12 power-interruption check-up. Nothing
here is broken; each is an improvement waiting on a decision.

## 1. Move IoT devices off the main (marisol) network

Do this first. Items 2 and 3 only help devices that are actually on the IoT
network (10.47.3.0/24). The marisol pihole shows these on 10.47.2.0/24 instead,
where they can reach workstations and lab services:

| Device | MAC | IP (2026-11-12) | On marisol since |
|---|---|---|---|
| Samsung Frame TV (via Sunroom AP) | c0:23:8d:58:a8:86 | 10.47.2.66 | 2026-05-28 |
| Echo (was 10.47.3.27) | 08:a6:bc:e1:ad:0e | 10.47.2.58 | 2026-05-08 |
| Echo (was 10.47.3.31) | 48:78:5e:eb:61:e6 | 10.47.2.77 | 2026-05-26 |
| Amazon device (likely Echo or Fire TV) | 34:25:be:4a:e7:7b | 10.47.2.38 | 2026-04-14 |
| Amazon device | f4:03:2a:8e:b0:85 | 10.47.2.36 | 2026-04-14 |
| Amazon device | 48:78:5e:9a:fc:81 | 10.47.2.41 | 2026-04-14 |
| Amazon device | 48:78:5e:cb:41:15 | 10.47.2.67 | 2026-04-14 |
| Amazon device | 14:0a:c5:45:94:68 | 10.47.2.42 | 2026-04-14 |
| Amazon device | 0c:43:f9:d3:62:5d | 10.47.2.64 | 2026-04-14 |
| Amazon device | 8c:19:52:9b:ef:7a | 10.47.2.108 | 2026-06-02 |
| Amazon Smart Plug (AmazonPlug142K) | b4:e4:54:e0:bf:46 | 10.47.2.184 | 2026-04-14 |
| Amazon Smart Plug (AmazonPlug04W4) | 68:db:f5:c7:47:32 | 10.47.2.183 | 2026-04-14 |
| WiZ bulb (wiz_ed503a) | a8:bb:50:ed:50:3a | 10.47.2.60 | 2026-04-14 |
| WiZ bulb (wiz_cbd386) | a8:bb:50:cb:d3:86 | 10.47.2.59 | 2026-04-14 |
| Espressif board | 70:03:9f:63:53:bd | 10.47.2.61 | 2026-04-20 |
| Espressif board | 70:03:9f:5f:7a:72 | 10.47.2.63 | 2026-04-20 |
| Espressif board | e8:68:e7:4d:94:1b | 10.47.2.62 | 2026-04-20 |
| Espressif board | c4:dd:57:37:06:bf | 10.47.2.49 | 2026-05-02 |

Background:

- The two Echos switch between the IoT and main networks, probably because
  both Wi-Fi passwords are saved to the Amazon account ("Wi-Fi Simple
  Setup").
- Deleting a saved password from the Amazon account only stops Amazon from
  handing it out again. It doesn't disconnect anything, because each device
  keeps its own credentials, and it doesn't cover non-Amazon devices (WiZ,
  Espressif, Samsung). The menu used to be Amazon account → Content & Devices
  → Preferences → Saved Wi-Fi Passwords, and may offer only "delete all".

Plan:

1. Delete the saved marisol password from the Amazon account.
2. Change the marisol Wi-Fi password in the UniFi controller. Every device
   that knows the old one drops off, so nothing can quietly stay on marisol.
3. Put the new password on personal devices only: phones, laptops,
   workstations.
4. Rejoin each IoT device to the IoT SSID in its own app:
   - Echos and Fire TVs: Alexa app → device → Wi-Fi Network → Change.
   - Amazon Smart Plugs: reset, then set up again in the Alexa app.
   - WiZ bulbs: WiZ app.
   - Espressif boards: the plug's own app (Smart Life/Tuya or similar).
   - Samsung Frame: the TV's network settings or SmartThings.
5. Verify: re-run the query below. No IoT vendors should remain on
   10.47.2.0/24.
6. Optional extra enforcement: block known IoT MACs from the main SSID in
   UniFi, or use MAC-based VLAN assignment.

To regenerate the device list, query the `network` table of `pihole-marisol`'s
`pihole-FTL.db` for IoT vendors (Amazon, WiZ, Espressif, Samsung, Vizio, Tuya).

## 2. IoT-only DNS blocklist (10.47.3.0/24)

Add a denylist applied only to the IoT pihole instances (`pihole-iot` on lab
and on pihole2), managed by the `pihole` role. Proposed in two groups so they
can be enabled independently:

- **Low risk:**
  - `tvinteractive.tv`: Vizio Inscape ACR / viewing-data collection. Also
    turn off "Viewing Data" in the TV's settings.
  - `atiads.tv`, `springserve.com`: TV ad servers. Gravity only covers
    `vid-io-iad.springserve.com`.
  - `o401343.ingest.sentry.io` and `o401343.ingest.us.sentry.io`: Vizio
    crash telemetry.
  - `tag.tapad.com`: cross-device ad tracking that links the TV to other
    devices in the household. Seen from the Vizio at power-on on 2026-11-12.
  - Gravity already blocks other Vizio ad and tracking domains:
    `vid-io-iad.springserve.com`, `ad.doubleclick.net`, `d.agkn.com`,
    `pi.ispot.tv` and `customerevents.netflix.com`.
- **Medium risk (test after enabling):**
  - `*.diagnostic.networking.aws.dev`: Echo network-measurement probes,
    about 45k lookups per Echo over 3 months.
  - `*.minerva.devices.a2z.com`, `unagi-na.amazon.com`: Amazon device and
    Prime Video telemetry.
- **Do not block:**
  - `www.google.com`, `connectivitycheck.gstatic.com`, `clients3.google.com`:
    the TV's connectivity check.
  - Generic `kinesis` / `firehose.*.amazonaws.com`: shared AWS endpoints.
  - `wiz.world`, `tuyaus.com`, Alexa, Spotify, Netflix: the devices need
    these to work.

## 3. Stop IoT devices bypassing the pihole

`roles/gateway-network/files/pf.conf` isolates the IoT network from the other
internal networks, but lets IoT devices reach any external resolver. Add the
following for `$vlan3`:

- redirect outbound TCP and UDP port 53 to the IoT pihole
- block port 853 (DNS over TLS)
- optionally, block known DNS-over-HTTPS endpoints
