# Open items

Deferred decisions from the 2026-11-12 power-interruption check-up. Nothing
here is broken; each is an improvement waiting on a decision.

## 1. IoT-only DNS blocklist (10.47.3.0/24)

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

## 2. Stop IoT devices bypassing the pihole

`roles/gateway-network/files/pf.conf` isolates the IoT network from the other
internal networks, but lets IoT devices reach any external resolver. Add the
following for `$vlan3`:

- redirect outbound TCP and UDP port 53 to the IoT pihole
- block port 853 (DNS over TLS)
- optionally, block known DNS-over-HTTPS endpoints
