#!/usr/bin/env bash
# Dump a running Harvester/KubeVirt VM's memory and download it as .memory.dump.gz.
#
# Why not `virtctl memory-dump get --output`? It needs the KubeVirt VMExport
# feature gate, which Harvester 1.8.2 (the tested version) doesn't enable. Instead we dump to a PVC and
# stream the file out through a short-lived helper Pod on the VM's node.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options] <vm-name>

Options:
  -n, --namespace NS     VM namespace (default: default)
  -o, --output-dir DIR   where to save the dump (default: .)
  -s, --storage-class SC storage class for the dump PVC (default: cluster default)
  -z, --size SIZE        PVC size, e.g. 16Gi (default: 2x guest memory + 2Gi)
  -k, --keep             keep the PVC/association after download
      --format FMT       elf (default, via KubeVirt) or win-dmp (WinDbg MEMORY.DMP, via virsh in the
                         virt-launcher pod; experimental, Windows x64 guests only)
      --kubeconfig FILE  kubeconfig (default: \$KUBECONFIG, else kubectl's default ~/.kube/config)
      --secure           verify the API server TLS cert (default: skip, lab uses self-signed)
  -h, --help
USAGE
}

NS=default OUT=. SC="" SIZE="" KEEP=0 INSECURE=1 FORMAT=elf
KUBECONFIG="${KUBECONFIG:-}"  # empty: kubectl/virtctl use their own default (~/.kube/config)
VM=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NS=$2; shift 2;;
    -o|--output-dir) OUT=$2; shift 2;;
    -s|--storage-class) SC=$2; shift 2;;
    -z|--size) SIZE=$2; shift 2;;
    -k|--keep) KEEP=1; shift;;
    --format) FORMAT=$2; shift 2;;
    --kubeconfig) KUBECONFIG=$2; shift 2;;
    --secure) INSECURE=0; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2;;
    *) [[ -z $VM ]] || { echo "only one VM allowed" >&2; exit 2; }; VM=$1; shift;;
  esac
done
[[ -n $VM ]] || { usage >&2; exit 2; }
[[ $FORMAT == elf || $FORMAT == win-dmp ]] || { echo "--format must be elf or win-dmp" >&2; exit 2; }
[[ -z $KUBECONFIG ]] || export KUBECONFIG

K=(kubectl -n "$NS")
(( INSECURE )) && K=(kubectl --insecure-skip-tls-verify -n "$NS")
V=(virtctl -n "$NS")
for t in kubectl virtctl gzip; do command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }; done

log() { printf '==> %s\n' "$*" >&2; }

PHASE=$("${K[@]}" get vmi "$VM" -o jsonpath='{.status.phase}' 2>/dev/null || true)
[[ $PHASE == Running ]] || { echo "VM $NS/$VM is not running (phase: '${PHASE:-none}')" >&2; exit 1; }
NODE=$("${K[@]}" get vmi "$VM" -o jsonpath='{.status.nodeName}')

# --format win-dmp: skip KubeVirt's memory-dump API (it hardcodes the ELF/raw format) and ask
# libvirt for a Windows crash dump directly, from inside the virt-launcher pod.
if [[ $FORMAT == win-dmp ]]; then
  UID_=$("${K[@]}" get vmi "$VM" -o jsonpath='{.metadata.uid}')
  LPOD=$("${K[@]}" get pod -l "kubevirt.io=virt-launcher,kubevirt.io/created-by=$UID_" \
    -o jsonpath='{.items[0].metadata.name}')
  [[ -n $LPOD ]] || { echo "virt-launcher pod for $NS/$VM not found" >&2; exit 1; }
  DOM="${NS}_${VM}"
  REMOTE="/var/run/kubevirt/$VM-$(date +%Y%m%d-%H%M%S).dmp"
  mkdir -p "$OUT"
  DEST="$OUT/$VM-$(date +%Y%m%d-%H%M%S).win-dmp.gz"
  trap '"${K[@]}" exec "$LPOD" -c compute -- rm -f "$REMOTE" >/dev/null 2>&1 || true' EXIT
  log "virsh dump --memory-only --format win-dmp in $LPOD (needs ~guest RAM free in the pod's /var/run/kubevirt)"
  # Newer virt-launchers run an unprivileged libvirt on a unix socket; try plain virsh first.
  ok=0
  for uri in "" "qemu+unix:///session?socket=/var/run/kubevirt-private/libvirt/virtqemud-sock" "qemu:///system"; do
    if "${K[@]}" exec "$LPOD" -c compute -- virsh ${uri:+-c "$uri"} dump "$DOM" "$REMOTE" \
        --memory-only --format win-dmp >&2; then ok=1; break; fi
  done
  (( ok )) || { echo "virsh dump failed. win-dmp needs a Windows x64 guest with the QEMU vmcoreinfo device and the fw_cfg guest driver (virtio-win)." >&2; exit 1; }
  log "downloading to $DEST"
  if ! "${K[@]}" exec "$LPOD" -c compute -- gzip -c "$REMOTE" > "$DEST.part"; then
    rm -f "$DEST.part"; echo "download failed" >&2; exit 1
  fi
  gzip -t "$DEST.part"
  mv "$DEST.part" "$DEST"
  MAGIC=$( (gzip -dc "$DEST" | head -c 8) || true )
  [[ $MAGIC == PAGEDU64 ]] || log "warning: unexpected header '$MAGIC' (expected PAGEDU64)"
  log "done: $(ls -lh "$DEST" | awk '{print $5}')  $DEST"
  echo "$DEST"
  exit 0
fi

POD="memdump-reader-$VM"
POD=${POD:0:63}
CLAIM=""
CREATED_CLAIM=0

cleanup() {
  local rc=$?
  "${K[@]}" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  if (( KEEP )); then
    [[ -z $CLAIM ]] || log "kept PVC $CLAIM (release: virtctl memory-dump remove $VM -n $NS; kubectl delete pvc $CLAIM -n $NS)"
  elif (( CREATED_CLAIM )); then
    log "removing dump association and PVC $CLAIM"
    "${V[@]}" memory-dump remove "$VM" >/dev/null 2>&1 || true
    for _ in $(seq 30); do
      "${K[@]}" get vm "$VM" -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null | grep -qw "$CLAIM" || break
      sleep 2
    done
    "${K[@]}" delete pvc "$CLAIM" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  exit $rc
}
trap cleanup EXIT

# Reuse an already-associated dump PVC (virtctl refuses --create-claim in that case).
CLAIM=$("${K[@]}" get vm "$VM" -o jsonpath='{.status.memoryDumpRequest.claimName}' 2>/dev/null || true)
if [[ -n $CLAIM ]]; then
  log "VM already has dump PVC $CLAIM associated; reusing it (it will not be deleted)"
  "${V[@]}" memory-dump get "$VM" >&2
else
  CLAIM="$VM-memdump"
  if [[ -z $SIZE ]]; then
    # virtctl's own PVC sizing is too small in practice ("No space left on device")
    # and has no --size flag, so we create the PVC ourselves: 2x guest memory + 2Gi.
    MEM=$("${K[@]}" get vmi "$VM" -o jsonpath='{.spec.domain.memory.guest}')
    case $MEM in
      *Gi) MIB=$(( ${MEM%Gi} * 1024 ));;
      *Mi) MIB=${MEM%Mi};;
      *) echo "cannot parse guest memory '$MEM'; pass --size" >&2; exit 1;;
    esac
    SIZE="$(( (MIB * 2 + 2048 + 1023) / 1024 ))Gi"
  fi
  CREATED_CLAIM=1
  log "creating PVC $CLAIM ($SIZE${SC:+, $SC})"
  "${K[@]}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $CLAIM
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  resources:
    requests:
      storage: $SIZE
${SC:+  storageClassName: $SC}
YAML
  log "dumping memory of $NS/$VM (node $NODE) to $CLAIM"
  "${V[@]}" memory-dump get "$VM" --claim-name="$CLAIM" >&2
fi

# `virtctl memory-dump get` without --output returns once the request is submitted.
log "waiting for the dump to complete"
DEADLINE=$(( SECONDS + 900 ))
while :; do
  DPHASE=$("${K[@]}" get vm "$VM" -o jsonpath='{.status.memoryDumpRequest.phase}' 2>/dev/null || true)
  case $DPHASE in
    Completed) break;;
    Failed) echo "memory dump failed: $("${K[@]}" get vm "$VM" -o jsonpath='{.status.memoryDumpRequest.message}')" >&2; exit 1;;
  esac
  (( SECONDS < DEADLINE )) || { echo "timed out waiting for dump (phase: ${DPHASE:-none})" >&2; exit 1; }
  sleep 3
done

FILE=$("${K[@]}" get vm "$VM" -o jsonpath='{.status.memoryDumpRequest.fileName}')
[[ -n $FILE ]] || { echo "no dump file name reported by the VM status" >&2; exit 1; }
log "dump file on PVC: $FILE"

log "starting helper pod $POD on $NODE"
"${K[@]}" delete pod "$POD" --ignore-not-found --wait=true >/dev/null
"${K[@]}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  nodeName: $NODE
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: r
    image: docker.io/library/busybox:latest
    command: ["sleep","1800"]
    volumeMounts:
    - {name: d, mountPath: /dump, readOnly: true}
  volumes:
  - name: d
    persistentVolumeClaim: {claimName: $CLAIM, readOnly: true}
YAML
"${K[@]}" wait --for=condition=Ready "pod/$POD" --timeout=180s >&2

mkdir -p "$OUT"
DEST="$OUT/${FILE}.gz"
log "downloading to $DEST"
if ! "${K[@]}" exec "$POD" -- gzip -c "/dump/$FILE" > "$DEST.part"; then
  rm -f "$DEST.part"; echo "download failed" >&2; exit 1
fi
gzip -t "$DEST.part"
mv "$DEST.part" "$DEST"
MAGIC=$( (gzip -dc "$DEST" | head -c 4 | od -An -c | tr -d ' ') || true )  # SIGPIPE from head is expected
[[ $MAGIC == '177ELF' || $MAGIC == '\177ELF' ]] || log "warning: unexpected header '$MAGIC' (expected ELF core)"
log "done: $(ls -lh "$DEST" | awk '{print $5}')  $DEST"
echo "$DEST"
