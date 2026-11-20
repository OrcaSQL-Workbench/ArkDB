# Dual standalone HAR consumer

After building both local self-contained HARs, run from the repository root:

```powershell
npm run test:dual-consumer
```

This P27A consumer restores both exact standalone archives with an unavailable
registry and compiles a minimal application importing both factories. It requires
the `Dual standalone HAR identity boundaries` Hypium case
`keepsFactoryResultAndErrorIdentityPackageLocal` to pass; unrelated passing cases
are rejected. The case checks factory IDs, package-local result/error constructors
and each unconnected driver's own error identity.

Only successful runs output a unique `Runtime HAP` path and SHA-256. The label
identifies an application artifact, not proof it was executed. Use only that
successful output's artifact, verify its digest, and require
`install bundle successfully` before launching on an unlocked API-24 emulator:

```powershell
hdc -t <target> install <successful-output-HAP>
hdc -t <target> shell aa start -a EntryAbility -b dev.arkdb.dualhar.example
hdc -t <target> shell hilog -x
```

On launch, the page sends offline probes through separate MySQL and PostgreSQL
Workers. It checks each Worker's package-local error identity, independent
state, host-to-Worker and Worker-to-host messages, replacement of a stopped
Worker while the other continues, and host-requested shutdown acknowledged by
the Worker before a zero-code exit. `P27_WORKERS_PASS` is emitted only after
these checks; a queued unsolicited exit without the shutdown acknowledgement is
a failure. Late invalid replies also fail the probe. Shutdown waits for exit
confirmation after forced termination; if exit remains unconfirmed, the app
blocks retries until restart to avoid overlapping Worker generations. The
dual-consumer Node suite also tests these failure paths and the no-delay exit
regression.

For device evidence, use only a successful `Runtime HAP` path and verify its
SHA-256 before installation. Require `install bundle successfully`, start
`dev.arkdb.dualhar.example` on a fresh API-24 emulator, and confirm the pass
marker from that app process. Uninstall the app and remove the task-owned
emulator after capture. This verifies only the exact candidate HARs and that
emulator/toolchain; it does not establish live server compatibility, signed
physical-device validation or certification.

Embedded core constructors remain package-local; this does not claim
cross-HAR `instanceof` compatibility.
