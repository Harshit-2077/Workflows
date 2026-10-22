# Poco F6 / Peridot: Clang 19 kernel and QCA6750 WLAN

This is a source port of [Loukious's monitor/injection commit](https://github.com/Loukious/vendor_qcom_opensource_wlan/commit/25875eb1a65e94fae404c6e9188c7a1fe679e0f5), targeted at the supplied **lineage-23.2** kernel/module sources. It is experimental until tested on a Poco F6 with the intended ROM and firmware. A successful build does not prove bootability, monitor reception, or over-air injection.

## Can the original patch be applied directly??

No. Its paths are relative to a standalone WLAN repository, its WCN7750 profiles do not exist here, and several APIs differ. Peridot's [device configuration](https://github.com/peridot-dev/android_device_xiaomi_peridot/blob/lineage-23.2/BoardConfig.mk) uses the pineapple kernel base but selects **`.qca6750`**, not WCN7750.

Pinned inputs:

| Input | Repository / revision |
| --- | --- |
| Kernel | `LineageOS/android_kernel_xiaomi_sm8635` at `db0c2edbbf0e825a9df05c2da98d1359ed6f5780` |
| Modules | `peridot-dev/android_kernel_xiaomi_sm8635-modules` at `307c8a1a872a3594fd049b3d528aaa74653caf1a` |
| Reference change | Loukious `25875eb1a65e94fae404c6e9188c7a1fe679e0f5` |
| Kernel configuration | `gki_defconfig` + `vendor/pineapple_GKI.config` + `vendor/peridot_GKI.config` |
| WLAN profile | `pineapple_gki_qca6750_defconfig` |
| Compiler/linker | Clang/LLVM/LLD **19** |

## Changes

- Port the reference's monitor interface handling, RX filter refresh, radiotap handling, direct datapath helper, TX completion accounting, channel-change coordination and station restoration.
- Enable `CONFIG_FEATURE_FRAME_INJECTION_SUPPORT` in the QCA6750 profile.
- Omit the WCN7750-only RX filter override; retain QCA6750's native monitor filter setup.
- Adapt monitor-channel access to this driver's `mon_chan_freq` / `mon_bandwidth` fields and update them after successful cfg80211 channel changes.
- Linearize packet-socket buffers before parsing and preserve the original MLO capability across monitor teardown.
- Fix host libbpf const correctness and align extract-cert password guards with its OpenSSL/BoringSSL implementation.
- Disable `MODULE_SIG`, `MODULE_SIG_ALL`, `MODULE_SIG_FORCE` and Android `MODULE_SIG_PROTECT`; verify both configuration and unsigned module output. Disable unused-symbol trimming so external modules can link.

**The reference implements management-frame injection only.** The frame validator rejects data and control frames. Radiotap rate/retry/TX-flag fields are not a general transmit-control API. Firmware must support raw TX, the helper AP vdev and monitor RX. Queuing a packet or returning success from a socket is not proof of RF transmission.

## Build locally

On Ubuntu with Clang 19 available in its package repositories:

```sh
sudo apt-get update
sudo apt-get install -y git clang-19 llvm-19 lld-19 build-essential bc bison flex \
  libssl-dev libelf-dev libncurses-dev dwarves cpio rsync zip kmod
JOBS=4 bash scripts/build-peridot.sh
```

Use at least 8 GiB RAM and ample disk space (approximately 30 GiB free recommended). Sources and objects remain under `build/` for incremental builds. To use a different directory:

```sh
BUILD_ROOT=/absolute/path/peridot-build JOBS=4 bash scripts/build-peridot.sh
```

The script fetches exact commits, applies checked patches, builds `Image` and in-tree modules, then builds **rmnet_mem, IPA, WLAN platform modules and `qca_cld3_qca6750.ko`** against that kernel. It does not suppress modpost failures. This is the WLAN dependency set, not a full Android ROM build or all camera/display/audio vendor modules.

Outputs are in `build/dist/`:

- `Image`, `kernel.config`, `Module.symvers`, `System.map`, `kernelrelease.txt`
- `modules.tar.gz`: in-tree modules and the external WLAN dependency set
- `wlan-modinfo.txt`, source revisions, patch hashes, `SHA256SUMS`
- `logs/build.log`; `BUILD_SUCCESS` is written only after every build/verification step passes

The kernel image and module archive are **not flashable boot/vendor_dlkm images**. Integrate them into the matching ROM's image packaging. Its other vendor modules, module load lists, DTB/DTBO, ramdisk, firmware and kernel ABI must agree. Disabling signatures does not bypass symbol-version/ABI mismatches or Android Verified Boot. Do not replace a HyperOS kernel/module blindly with a LineageOS build.

## GitHub Actions

After the workflow is merged into the default branch, use **Actions → Poco F6 Clang 19 kernel and WLAN → Run workflow**, selecting the desired branch. The initial feature-branch build starts automatically on push. Changes to the script, patches or workflow also trigger a build. The workflow calls the same standalone script and uploads compiled artifacts only after success; failure logs are uploaded separately. No signing key is required.

## Apply the patches in an existing source checkout

Start from the pinned revisions above:

```sh
git -C /path/to/sm8635-modules apply --check /path/to/patches/0001-peridot-qca6750-monitor-injection.patch
git -C /path/to/sm8635-modules apply /path/to/patches/0001-peridot-qca6750-monitor-injection.patch
git -C /path/to/sm8635-kernel apply --check /path/to/patches/0002-kernel-host-libbpf-const.patch
git -C /path/to/sm8635-kernel apply /path/to/patches/0002-kernel-host-libbpf-const.patch
```

The WLAN patch paths start at `qcom/opensource/wlan/`; apply it at the **modules repository root**. Signature settings are applied by the build script, so applying the source patch alone does not disable signing.

## Hardware acceptance checks

After integrating a matching kernel/module set into your ROM:

1. Confirm the phone boots, normal Wi-Fi associates, and `dmesg` has no module version, unresolved symbol, firmware or CFI errors. Record `uname -a`, ROM build, firmware version and loaded module path.
2. Confirm `modinfo qca_cld3_qca6750.ko` lists `injection_dp_inflight_limit` and the signer is empty. Check `/proc/config.gz` if enabled for `# CONFIG_MODULE_SIG is not set`.
3. Stop Android's Wi-Fi client management for the test. Identify the actual PHY/interface with `iw dev` and `iw phy`. Create a monitor interface with `iw phy phy0 interface add mon0 type monitor` (substitute the real PHY), bring it up, and set an allowed test channel, e.g. `iw dev mon0 set channel 6 HT20`.
4. Capture with `tcpdump -i mon0 -s 0 -w /data/local/tmp/monitor.pcap`. Confirm radiotap headers and frames from another transmitter, including other-BSS traffic. Repeat after changing channel and after deleting/recreating the monitor interface.
5. On a second monitor-capable radio on the same channel, capture while sending management test frames from the phone (for example, `aireplay-ng --test mon0` against your test network). Verify the frames actually arrive and match the phone's test traffic. Check `dmesg` for `Injection TX helper ready`, setup failures and completion timeouts. Capture evidence is required for a pass.
6. Delete `mon0`, restart normal Wi-Fi, verify association, and repeat the cycle. Check for crashes, hangs, loss of RX after injection, leaked helper vdevs and failure to restore the station.

### Confirm the direct datapath on the phone

The selected configuration enables `CONFIG_KPROBE_EVENTS`. If the ROM exposes tracefs and permits root tracing, the following **device-only, untested-here** diagnostic observes the direct-DP completion hook. Run it in a root shell after loading the new WLAN module:

```sh
trace_root=/sys/kernel/tracing
was_tracing=$(cat "$trace_root/tracing_on")
echo 'p:peridot_dp_complete qca_cld3_qca6750:wma_injection_dp_complete' >> "$trace_root/kprobe_events"
echo 1 > "$trace_root/events/kprobes/peridot_dp_complete/enable"
echo 1 > "$trace_root/tracing_on"
# Send the management test frames, then inspect events:
grep peridot_dp_complete "$trace_root/trace"
# Remove this diagnostic and restore the prior tracing state:
echo 0 > "$trace_root/events/kprobes/peridot_dp_complete/enable"
echo '-:peridot_dp_complete' >> "$trace_root/kprobe_events"
echo "$was_tracing" > "$trace_root/tracing_on"
```

Use the actual loaded module name if different. A completion-hook event confirms the DP path was reached; it does not prove successful RF transmission. Correlate it with frames seen by the independent receiver. A missing event is not conclusive if probe registration failed, tracing is unavailable, or the trace buffer wrapped.

Do not mark hardware support verified until these checks pass on the target firmware. If they fail, provide the build manifest, ROM/kernel version, `iw phy`/`iw dev`, module-load errors, WLAN logs around the failure, and the two capture files.

## Attribution

The main driver implementation is by Loukious, from the commit linked above; this patch adapts it to the supplied Peridot source version. Original source copyright and license notices remain in place.
