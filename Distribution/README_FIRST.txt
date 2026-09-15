PIKMIN PILOT 11.5.4.11 — END USER INSTALL KIT
Build: 1153
Runtime baseline: Stage 11.5.3
Automation fixes: Hard Count + Green-X Double ACK

THIS KIT IS FOR A DEVICE THAT IS ALREADY INCLUDED IN THE APP/TUNNEL/RUNNER PROVISIONING PROFILES.

INSTALL
1. Install PikminPilot-11.5.4.11.ipa on the registered iPhone.
2. If iOS asks, enable Developer Mode and approve/trust the developer build.
3. Open Pikmin Pilot once and allow the VPN configuration when iOS asks.
4. Pairing setup:
   - PERSONALIZED build: the device-specific RPPairing record is embedded; no file picker is expected.
   - GENERIC build: press START PILOT and select rp_pairing_file.plist once when the Files picker opens.
5. FIRST-TIME PREP: run START PILOT once with Wi-Fi ON. This validates RPPairing and caches/validates the DDI/Runner path.
6. Normal Wi-Fi use: START PILOT.
7. Cellular warm-session use: follow the in-app 11.5.4.11 prompts. When a live persistent RSD session already exists, 4G/5G can start directly. A cold cellular bootstrap may still ask for the temporary Airplane Mode step.

DO NOT install a second VPN app for Pikmin Pilot. The app already contains the verified Integrated Tunnel.
DO NOT replace the embedded Runner. Runner revision must remain 1153-xfix.

If installation fails before the app opens, send the installer error plus RELEASE-INFO.json to the maintainer.
If START PILOT fails, use COPY LOG inside Pikmin Pilot and send the exact result.
