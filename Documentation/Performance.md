# Performance and validation

Measured on an Apple M2 Pro (Mac14,12, 10 logical cores / 6 performance cores), APFS, using optimized Swift 6.2 builds and the official Petal v0.1.0 macOS release executable. Petal tag: `90bb813c207738b2f6bd25ab46c04c53fa66770d`. Measurements are warm-cache scans, ten separate process runs per tool, alternating tool order, with identical scopes and permissions. No concurrent build or scan workloads ran during the timing comparison.

| Scope | Items | Swift median | Petal median | Swift / Petal |
| --- | ---: | ---: | ---: | ---: |
| fastlane checkout | 3,820 | 0.01112 s | 0.012 s | 0.926 |
| XcodesApp checkout | 9,899 | 0.03571 s | 0.039 s | 0.916 |
| Full workspace | 63,718 | 0.19485 s | 0.1805 s | 1.080 |

Every run matched item count, allocated bytes and access-error count. All three scopes met the median time gate of at most 110% of Petal. Petal reports times rounded to milliseconds. These measurements establish the gate on this machine and these scopes, not on all volumes or hardware. Raw samples and accounting are in [BenchmarkResults.json](BenchmarkResults.json).

## Reproduce

Build the package with `swift build -c release`. Obtain the official [Petal v0.1.0 release](https://github.com/henrydennis/petal/releases/tag/v0.1.0) executable without changing either scanner. Supply absolute binary paths and identical readable scopes:

```sh
python3 Scripts/compare-petal.py \
  --swift /path/to/cleanup-benchmark \
  --petal /path/to/Petal.app/Contents/MacOS/petal \
  --output comparison.json /path/to/scope /path/to/another-scope
```

The script alternates launches, records raw samples, compares accounting fingerprints, and fails if accounting differs or the 10% gate fails. Static scopes are essential: files changing between runs invalidate the comparison. Choose equivalent permissions and filesystem boundaries. Repeat on cold caches before making general performance claims. Native Intel hardware validation is outside the current feature scope.

## First finding

A disposable fixture placed a developer home under the scan root (`Users/<username>/Library/Developer/Xcode/DerivedData`) with 30,000 APFS clones of a 64 KB file. Both tools recognized the same DerivedData finding. Ten optimized Swift runs reported first complete finding latency around 0.032 seconds; ten Petal `--bench-live` runs reported approximately 0.04 seconds (rounded to hundredths). This is a finding-detection measurement: Petal's displayed coverage timing is separately throttled, and Xcodes window rendering was not measured. Run `cleanup-benchmark ROOT 10 6 FIXTURE_HOME` and `petal --bench-live ROOT 10` to compare those signals. The scan's public progress exposes raw `firstFindingElapsedNanoseconds`.

## Completed validation

- Thirteen Foundation-only package tests passed on Apple silicon, including cancellation, independent sessions, retained completed results, category-free browsing, raw paths, hierarchy, overlapping roots, hard links, sparse files, symlinks, access failures, cloud-policy restoration and malformed metadata bounds.
- Opt-in APFS tests created a disposable volume, compared clone-family estimates with actual deleted allocation, checked partial-clone bounds, and tested explicit mount roots plus excluded nested mount points.
- The package built for x86_64. The same thirteen tests also passed under Rosetta using a directly compiled Swift Testing runner. This bypassed the installed toolchain's ARM-only SwiftPM testing helper; it is not a native Intel hardware run.
- XcodesApp Debug and Release builds and all 54 app tests passed, including unavailable-device filtering, stale-target rejection and injected Trash behavior. The existing CLI has no modifications.

## Remaining manual checks

Cold-cache performance, live iCloud dataless items, broader concurrent-disappearance scenarios, Full Disk Access granted/denied, real active-tool/window lifecycle flows, signing/distribution, actual user cleanup failures and full app rendering performance remain unverified. Native UI automation lost its connection after opening the Clean Up toolbar entry, so visual/end-to-end window verification could not finish. No user files or simulator devices were deleted during verification. These are outstanding acceptance checks, rather than implied passes.
