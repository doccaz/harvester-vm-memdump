# harvester-vm-memdump

One command to take a memory dump of a running Harvester (KubeVirt) VM and download it.

```bash
./vm-memdump.sh -n labs -o ./dumps ubuntu-2404
```

Output: `<outdir>/<vm>-<pvc>-<timestamp>.memory.dump.gz` (a gzipped QEMU memory-only ELF core).
To open the dump afterwards, see [ANALYZING.md](ANALYZING.md).

## What it does
1. Checks the VM is running and finds its node.
2. Creates a Filesystem-mode RWO PVC sized at 2x guest memory + 2Gi
   (`virtctl`'s own sizing runs out of space and has no `--size` flag).
3. `virtctl memory-dump get` attaches it as a hotplug volume and dumps; the script polls until `Completed`.
4. Starts a read-only busybox helper Pod on the VM's node, streams `gzip -c` of the dump out
   through `kubectl exec`, verifies it (`gzip -t`, ELF header).
5. Cleans up (always, even on failure): helper Pod, dump association
   (`virtctl memory-dump remove`) and the PVC. `--keep` skips the PVC cleanup.

If the VM already has a dump PVC associated, that PVC is reused and never deleted.

## Why not `virtctl memory-dump get --output`?
That flag downloads the dump through a `VirtualMachineExport`, which requires the KubeVirt
`VMExport` feature gate. **The feature gate is not enabled in Harvester 1.8.2**, the version this
script was tested on, and `virtctl` fails with `vm export feature gate not enabled`.
So the script dumps to a PVC and streams the file out through a short-lived helper Pod instead.
If your Harvester/KubeVirt has the gate enabled, plain `virtctl memory-dump get --output` may be simpler.

## Usage
```bash
./vm-memdump.sh [options] <vm-name>
```

| Option | Description | Default |
|--------|-------------|---------|
| `-n`, `--namespace NS` | Namespace of the VM | `default` |
| `-o`, `--output-dir DIR` | Where to save the dump | `.` |
| `-s`, `--storage-class SC` | Storage class for the dump PVC | cluster default |
| `-z`, `--size SIZE` | PVC size, e.g. `16Gi` | 2x guest memory + 2Gi |
| `-k`, `--keep` | Keep the PVC and its association after download | off (cleaned up) |
| `--format FMT` | `elf` (via KubeVirt) or `win-dmp` (experimental, does not work on stock Harvester; use `elf2windmp.py` instead, see below) | `elf` |
| `--kubeconfig FILE` | Kubeconfig to use | `$KUBECONFIG`, else `~/.kube/config` |
| `--secure` | Verify the API server TLS certificate | off (lab uses a self-signed cert) |
| `-h`, `--help` | Show usage | |

## Opening a Windows dump in WinDbg: `elf2windmp.py`
WinDbg does not open the QEMU ELF core. `elf2windmp.py` converts it to a Windows `MEMORY.DMP`
(`PAGEDU64`):

```bash
python3 -m venv .venv && .venv/bin/pip install memprocfs
.venv/bin/python elf2windmp.py dumps/<dump>.memory.dump.gz out.dmp   # ~30-40 s for 6 GiB
```

It writes the ELF LOAD segments to a sparse raw image and has MemProcFS generate the crash dump. That
decodes the `KdDebuggerDataBlock` (its `KDBG` tag is encoded in raw memory) and fills the header.

- Windows x64 guests only. Needs temp space for the raw image (about guest RAM) plus the output.
- `out.dmp` is sparse: it spans the physical address range, so the apparent size exceeds guest RAM (7.75 GiB for a
  5.75 GiB guest, 8 GiB for 6 GiB) but far less on disk. Copy it with `cp --sparse=always` or `rsync -S`.
- The header's bugcheck code is `0xdeaddead` (the VM did not crash): good for live-state inspection,
  not for BSOD analysis. For a real BSOD, have the guest write its own complete `MEMORY.DMP`.
- Verified on two VMs, see [Tested](#tested) and [ANALYZING.md](ANALYZING.md).

### `--format win-dmp` (experimental, does not work on stock Harvester)
KubeVirt's memory-dump API hardcodes the ELF/raw format, so `vm-memdump.sh --format win-dmp` skips it
and runs `virsh dump --memory-only --format win-dmp` inside the `virt-launcher` pod, then streams the
file out as `<vm>-<timestamp>.win-dmp.gz`. On Harvester 1.8.2 plain `virsh` connects, but QEMU fails with
`win-dump: invalid vmcoreinfo note size`: the VM's libvirt domain has no `vmcoreinfo` device and KubeVirt
does not add one. (The guest already has the virtio-win `fwcfg` driver.) Use `elf2windmp.py` instead.

## Requirements
- `kubectl`, `virtctl` (>= 1.7) and `gzip` on the machine running the script.
- Tested on **Harvester 1.8.2** with Linux (Ubuntu 24.04) and Windows Server 2022 guests.

## Analyzing
Full, tested guide with screenshots: **[ANALYZING.md](ANALYZING.md)**.

- **Linux guests:** `crash <vmlinux-with-debuginfo> <dump>.memory.dump`. It needs the guest's exact
  kernel debuginfo (found from the `Linux version` banner in the dump). Tested with `crash` 9.0.2 on
  Ubuntu 24.04; no extra flags needed.
- **Windows guests:** Volatility 3 (`pip install volatility3` in a venv) reads the ELF core directly
  and downloads the Windows symbols itself. Tested on Windows Server 2022 with `windows.info`,
  `pslist`, `cmdline`, `netscan`.
- **WinDbg:** convert first with `elf2windmp.py` (see above). WinDbg 10.0.22621.755 opens the result
  ("Kernel Complete Dump File"), kernel symbols load, `lm` and `!process 0 0` work. See
  [ANALYZING.md](ANALYZING.md).

The dump has memory only: no disk, and no vCPU state beyond QEMU's NOTE segment.

## Tested
All on Harvester 1.8.2.

| Guest | RAM | Dump | PVC | Analysis |
|-------|-----|------|-----|----------|
| Ubuntu 24.04 (`labs/ubuntu-2404`) | 1 GiB | 182 MB gz | 4Gi | `crash`: `sys`, `log`, `bt`, `ps`, `kmem -i` |
| Windows Server 2022 (`labs/windows-server-2022`) | 6 GiB | 551 MB gz | 14Gi | Volatility 3; `elf2windmp.py` + WinDbg (`lm`, `!process 0 0`) |
| Windows Server 2022 (`labs/winsrv2022`, running) | 5.75 GiB | 3.3 GB gz | 14Gi | Volatility 3 (`windows.info`, `pslist`); `elf2windmp.py` header and KDBG checked, not opened in WinDbg |

Not tested: `!analyze -v` on a converted dump, Windows guests other than Server 2022 build 20348, `--keep`, reusing an already-associated PVC through the script, non-default storage classes.

## Layout
- `vm-memdump.sh`: the script.
- `elf2windmp.py`: converts the ELF core to a Windows `MEMORY.DMP` for WinDbg (needs `memprocfs`).
- [`ANALYZING.md`](ANALYZING.md): how to open Linux and Windows dumps (with screenshots from `docs/images/`).
- `symbols/`, `dumps/`, `.venv/`: local working directories (kernel `vmlinux`, dumps, Volatility venv).
  They are large and git-ignored; see [ANALYZING.md](ANALYZING.md) for how to recreate them.

## Caveats
- The VM must be running. The dump may briefly stall the guest.
- The PVC needs free space in the chosen storage class (default class if `-s` omitted).

## License
MIT, see [LICENSE](LICENSE).
