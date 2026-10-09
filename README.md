# harvester-vm-memdump

One command to take a memory dump of a running Harvester (KubeVirt) VM and download it.

```bash
./vm-memdump.sh -n labs -o ./dumps ubuntu-2404
```

Output: `<outdir>/<vm>-<pvc>-<timestamp>.memory.dump.gz` (a gzipped QEMU memory-only ELF core).

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
It goes through `VirtualMachineExport`, which needs the KubeVirt `VMExport` feature gate.
The lab doesn't enable it (error: `vm export feature gate not enabled`).

## Options
`-n NS`, `-o DIR`, `-s STORAGECLASS`, `-z SIZE`, `-k/--keep`, `--kubeconfig FILE`
(default `$KUBECONFIG`, else `~/Projetos/local-harvester.yaml`), `--secure` (verify TLS;
default skips it for the self-signed lab cert).

Requires `kubectl`, `virtctl` (>= 1.7), `gzip`. Tested on Linux (Ubuntu 24.04) and Windows Server 2022 guests; see ANALYZING.md.

## Analyzing (full, tested guide: ANALYZING.md)
- **Linux guests:** `crash <vmlinux-with-debuginfo> <dump>.memory.dump`. It needs the guest's exact
  kernel debuginfo (found from the `Linux version` banner in the dump). Tested with `crash` 9.0.2 on
  Ubuntu 24.04; no extra flags needed.
- **Windows guests:** Volatility 3 (`pip install volatility3` in a venv) reads the ELF core directly
  and downloads the Windows symbols itself. Tested on Windows Server 2022 with `windows.info`,
  `pslist`, `cmdline`, `netscan`.

The dump has memory only: no disk, and no vCPU state beyond QEMU's NOTE segment.

## Tested
| Guest | RAM | Dump | PVC | Analysis |
|-------|-----|------|-----|----------|
| Ubuntu 24.04 (`labs/ubuntu-2404`) | 1 GiB | 182 MB gz | 4Gi | `crash`: `sys`, `log`, `bt`, `ps`, `kmem -i` |
| Windows Server 2022 (`labs/windows-server-2022`) | 6 GiB | 551 MB gz | 14Gi | Volatility 3 |

Not tested: `--keep`, reusing an already-associated PVC through the script, non-default storage classes.

## Layout
- `vm-memdump.sh`: the script.
- `ANALYZING.md`: how to open Linux and Windows dumps (with screenshots from `docs/images/`).
- `symbols/`, `dumps/`, `.venv/`: local working directories (kernel `vmlinux`, dumps, Volatility venv).
  They are large and git-ignored; see ANALYZING.md for how to recreate them.

## Caveats
- The VM must be running. The dump may briefly stall the guest.
- The PVC needs free space in the chosen storage class (default class if `-s` omitted).

## License
MIT, see [LICENSE](LICENSE).
