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

The page displays both factory IDs, without claiming Worker runtime verification.
Uninstall afterward: `hdc -t <target> uninstall dev.arkdb.dualhar.example`.

P27B owns the separate real Worker entry, bidirectional messages, lifecycle
isolation and acknowledged shutdown. They are intentionally absent here.
Embedded core constructors remain package-local, without cross-HAR `instanceof`
compatibility. Evidence covers only these candidate archives and offline tests,
not Worker dispatch, live servers, signed-device validation or certification.
