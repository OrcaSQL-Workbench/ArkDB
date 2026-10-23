# Official toolchain acquisition for hosted HAR builds

Research date: 2026-10-21. This document distinguishes documented headless compilation from verified unattended acquisition. It does not authorize SDK redistribution, accept license terms, or claim that an untested hosted workflow produces a working artifact.

**Current delivery decision (2026-10-22):** ArkDB uses maintainer-local builds and GitHub Release distribution. This historical hosted-toolchain research is outside the current release critical path. No cloud SDK acquisition, self-hosted runner, or hosted HAR build is required or configured; a version tag identifies source only. See the [local release procedure](releasing.md).

## Conclusion

Huawei documents headless HarmonyOS builds on Windows, Linux, and macOS. A dedicated self-hosted Windows server is therefore **not an inherent requirement** for building ArkDB HARs. The remaining acquisition question is how an ephemeral runner obtains an exact, authorized API-24 Command Line Tools distribution with verified integrity.

A complete, supported, anonymous API-24 bootstrap was **not established**. The earlier 2026-10-05 OrcaSQL investigation had already identified and locally built a specific official CLI archive; its unresolved blocker was noninteractive acquisition, not whether the compiler could produce HARs. That historical evidence was recovered on 2026-10-21 and supersedes any suggestion that the owner needs to download the same archive again.

Do not replace the missing CI acquisition route with a guessed URL, an arbitrary mirror, developer-session cookies, or an OpenHarmony SDK.

## Recovered prior evidence: 2026-10-05

Primary records are the originating OrcaSQL repository's `docs/release/toolchain-evidence.md`, section **Inspected Windows CLI candidate (2026-10-05)**, and `release/config/toolchain-evidence.json.hostedSetup`, together with its **Add local APP release packaging and shared signing** session.

| Historical observation | Recorded result |
| --- | --- |
| Official archive | `commandline-tools-windows-x64-6.1.1.418.zip` |
| Vendor-page SHA-256 matched locally on 2026-10-05 | `13338f9d313db76831a51be6ccbe4ba8c3340ea311431b3ca7fa4328d038c62f` |
| Compressed / expanded size | `2600751070` / `7568546222` bytes, approximately 2.60 / 7.57 GB |
| Archive format | ZIP64, 102,224 entries |
| CLI / Hvigor / OHPM | `6.1.1.418` / `6.24.5` / `6.1.2.285` |
| Embedded SDK | `6.1.1.125`, API 24 |
| Java | No Java executable in the archive; the local validation supplied the existing JBR `21.0.8` |
| Actual local compiler exercise | Clean release `assembleHar` and `assembleHap` succeeded from an isolated extraction |
| Original download route | Huawei content CDN URL with a signed query; two local cookie-free GETs returned HTTP 403, including a browser User-Agent and official Referer probe |
| Hosted admission | `hostedConfigurationReady: false`, `archive.downloadUrl: null`, and no recorded redistribution approval |

The recorded archive is still present at the owner's previously recorded local download path, with the same filename and byte length. That presence/size check is not a fresh digest or compiler rerun. The digest comparison, archive inspection, and clean CLI builds above are dated historical evidence.

This means the **existing download route was not ready for reliable automatic CI**, not that GitHub-hosted compilation was proven impossible. No real hosted acquisition/build was recorded. Local HTTP 403 observations do not prove every GitHub-origin request would receive the same response, nor isolate cookies as the sole cause.

## Documented first-party route

| Source | What it establishes |
| --- | --- |
| [Command Line Tools acquisition](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-get) | Official acquisition guidance; the HarmonyOS SDK is embedded in the CLI distribution |
| [Official download page](https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos) | The vendor's CLI distribution entry point |
| [Pipeline/headless builds](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-command-line-building-app) | Windows/Linux/macOS build support and `hvigorw assembleHar --mode module -p module=library1@default -p product=default --no-daemon` |
| [HarmonyOS CLI environment setup](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-hmos-commandline-get) | SDK selection through `DEVECO_SDK_HOME=<CLI>/sdk` |

The pipeline guide states Linux GLIBC >=2.28, at least 8 GB RAM (16 GB recommended), and a 100 GB disk requirement. For CLI versions below 26 it recommends JDK 17 and describes the matching bundled Node runtime plus `JAVA_HOME`, `NODE_HOME`, and `COMMANDLINE_TOOL_DIR`. These are documentation requirements, not evidence that a particular GitHub-hosted image/archive combination has passed ArkDB's build.

ArkDB's current target is HarmonyOS `6.1.1(24)` and a normalized-OHM-URL bytecode HAR, declared in `build-profile.json5` and `mysql/build-profile.json5`. The installed SDK identifies itself as `6.1.1.125`, API 24, `HarmonyOS-6.1.1`. Studio `6.1.1.300` must not be assumed to be the downloadable CLI archive version.

## Observed download-service behavior

The official download page returned HTTP 200 as a frontend shell. Its first-party download-route implementation checks login state. The frontend uses:

```text
POST https://svc-drcn.developer.huawei.com/svc/community/common/v1/delegate
svc: PartnerCommunityService/v1/developer/downloadCenter/getToolVersionList
reqType: 1
reqJson: {"toolAlias":"command-line-tools-for-hmos","language":"cn"}
```

The anonymous request observed during research returned HTTP 200 with application-level code `90910011`: required header `X-HD-CSRF` was missing. This is a developer-session/request prerequisite, not proof of a network outage or proof that every archive is unavailable anonymously.

A second probe used a fresh, isolated browser session with the real page scripts rather than a hand-written API request. Navigating to the official CLI page redirected to Huawei Account login (`https://id5.cloud.huawei.com/CAS/portal/loginAuth.html`, title `华为账号-登录`) before any CLI metadata response. No account credentials, cookies from an existing profile, download buttons, or agreement acceptance were used.

The frontend's download-URL operation is `PartnerCommunityService/v1/developer/downloadCenter/getToolVersionDownloadUrl`, using `sdkId`, `versionId`, and `packageId`. Its implementation handles real-name authentication (`92300013`) and required/new agreements (`92138106`) before accepting a returned `value.downloadUrl`. Package metadata supports `sha256` and optional `ascDownloadUrl`.

First-party implementation sources inspected:

- [Download frontend](https://developer.huawei.com/consumer/cn/download/main.6b40eb560c9f5281.js)
- [Download/authentication handling](https://developer.huawei.com/consumer/cn/download/common.ad7165ac7b5e9713.js)
- [Package integrity fields](https://developer.huawei.com/consumer/cn/download/3627.bea496ea7b6ab60e.js)

These versioned frontend assets are observations, not a promised public automation interface. The historical record above supplies a specific archive identity and vendor-page digest. It does not supply a reusable, authorized unattended download/refresh mechanism or a verified URL lifetime. Whether the conditional agreement/identity gates apply to a newly requested archive remains unverified.

## SDK-manager metadata is not the compiler distribution

The installed first-party SDK-manager client identifies the domain `https://devecostudio-drcn.deveco.dbankcloud.com` and catalogue operations `/sdkmanager/v8/hos/getSdkList` and `/sdkmanager/v9/hos/getSdkList`. It also contains `/sdkmanager/v7/hos/download` and `/sdkmanager/license` operations.

Anonymous Windows/x64 catalogue probes returned HTTP 200 and emulator-image catalogues, including API-24 images. A Linux/x64 v9 probe returned an empty list. **Neither result identified the API-24 compiler SDK distribution.** An emulator-image checksum must never be used as the compiler/toolchain checksum.

Discovery source: the installed Huawei plugin's `sdk-hos-core-6.1.1.300.jar`, including `sdk-hos-core.properties`, `BizUrlUtil`, and `MetaReqDto`. These internal first-party operations are not established as a supported public CI installation contract. No emulator image was downloaded and no download/license operation was invoked.

## Inputs required before enabling automatic acquisition

The archive identity, digest, layout, and local compiler compatibility do not need to be rediscovered. The remaining owner/vendor inputs are:

1. A supported noninteractive official download/refresh mechanism for the known archive, or an explicitly authorized alternative acquisition route.
2. Applicable access terms; any proposed private caching or redistribution must be reviewed separately.
3. A hosted-runner capacity check and an actual clean hosted acquisition/build using the verified distribution.
4. The selected runner's Java/runtime setup; the historical CLI archive does not contain Java.

The intended delivery does not require OHPM publisher credentials:

```text
ephemeral GitHub-hosted runner
  -> obtain an exact authorized official CLI distribution
  -> verify published integrity and SDK identity
  -> configure Java, SDK, and compiler runtime
  -> select actual registered driver directories
  -> compile and inspect HARs
  -> publish HAR/checksum/manifest downloads
```

Until those acquisition inputs are established, do not describe this outline as an operational hosted bootstrap. ArkDB already supports explicit `HARMONYOS_HVIGORW`, `HARMONYOS_OHPM`, and `DEVECO_SDK_HOME` paths, so a verified CLI distribution need not imitate Studio's directory layout. Repository Node >=22.19 remains separate from the compiler's matching runtime.

No account login, credential extraction, agreement acceptance, full SDK installation, or vendor-archive redistribution was performed during this research. Real-device interoperability and Previewer execution are separate from successfully compiling a HAR.

## GitHub size limits are separate from SDK acquisition

GitHub's [regular Git-file limit](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github) blocks files above 100 MiB in ordinary repository history. That is **not** a 100 MiB limit on files downloaded by a running Actions job. The vendor toolchain should not be committed to ArkDB or bundled into the downloadable driver artifacts.

The [standard hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) currently lists public-repository Linux/x64 and Windows/x64 runners with 4 CPUs, 16 GB RAM, and 14 GB SSD storage. Thus a standard runner cannot be assumed sufficient merely because the compiler archive downloads successfully.

The recovered archive's compressed-plus-expanded size is approximately **10.17 GB before Java, dependencies, build intermediates and outputs**. The vendor guide's 100 GB disk requirement and the standard runner's published 14 GB storage are a real capacity concern. The archive sizes are known; actual peak storage on a GitHub-hosted build is not. The historical blocker was the download route, not a demonstrated disk-full hosted run.

GitHub-managed [larger runners](https://docs.github.com/en/actions/reference/runners/larger-runners) include a 4-CPU/16-GB/150-GB Ubuntu or Windows option, with image/plan/billing constraints. They remain ephemeral hosted machines rather than a server maintained by the ArkDB owner. This is a possible paid fallback, not a configured or owner-approved default.

First resolve the authorized unattended acquisition route, then measure hosted peak storage using the already identified distribution. Do not assume that standard free runners fit it, that a large compressed file necessarily rules out Actions, or that proprietary SDK caching/redistribution is authorized. Only the small driver HAR and its checksum/source records belong in ArkDB's user-download output.
