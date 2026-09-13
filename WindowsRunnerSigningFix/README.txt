Pikmin Pilot Stage 7.8.4 — Nested XCTest Signing Fix
====================================================

WHY THIS EXISTS
---------------
The phone now reaches:
  runner-pid=... • driver=ready • Failed to load the test bundle
and the failing path is:
  Runner.app/PlugIns/PikminPilotRunnerUITests.xctest/<test executable>

That means the phone-local RSD / DTX / Runner launch / XCTestDriverInterface path is alive.
The remaining failure is the nested test bundle load.

A known Sideloadly behavior with XCTest runners is that the OUTER Runner.app can be
signed/installed while PlugIns/*.xctest is left without the matching developer-team
signature. iOS Library Validation then refuses to load the nested test executable.

WHAT THIS FIX DOES
------------------
This is a ONE-TIME INSTALL/RESIGN step on Windows. It is NOT part of Pikmin Pilot's
runtime and it does NOT create a Windows-resident service.

1. Uses the same cert/key Sideloadly already created under %APPDATA%\Sideloadly.
2. Reads the still-valid PikminPilotRunner provisioning profile back from your iPhone.
3. Uses go-ios only as a recursive code SIGNER/INSTALLER so both:
      Runner.app
      Runner.app/PlugIns/*.xctest
   are signed with the SAME Team ID.
4. Installs the repaired Runner over the current Runner bundle ID.

NO WDA is started. No localhost:8100 is used. No Windows process needs to stay open.
The final automation runtime remains iPhone-only.

HOW TO USE
----------
A. Build/download the GitHub Actions artifact:
   PikminPilotRunner-Stage7.8.4-Nested-XCTest-Signing-Fix-unsigned.ipa

B. IMPORTANT: first sign/install that Runner once normally with Sideloadly using the
   same Apple ID you already use. This mints/installs the Runner provisioning profile.

C. Then drag the UNSIGNED Runner IPA file onto:
   FIX_RUNNER_SIGNING.bat

The BAT checks/install-time dependencies:
- Python 3
- go-ios (installed via npm if needed)
- pymobiledevice3 (installed via pip if needed)
- OpenSSL (Git for Windows normally supplies it)

After SUCCESS, close the window. You do NOT keep CMD/PowerShell running.

D. On iPhone test exactly as before:
   LocalDevVPN
   -> Pikmin Pilot
   -> CONNECT PHONE-LOCAL RSD
   -> RUN XCTEST -> PIKMIN CENTER TAP

You do not need to redo RPPairing, RSD, DTX probes, or Runner discovery.


STAGE 9.1 OUTPUT
----------------
This version also writes a recursively signed IPA next to the unsigned input:
  <original-name>-SIGNED.ipa

You can copy that SIGNED IPA to iPhone Files and import it into Pikmin Pilot Stage 9.1.
Pikmin Pilot can then upload it through phone-local AFC/PublicStaging and ask
InstallationProxy to install/update the Runner itself. This proves the transport
needed for the later one-user-facing-install package.
