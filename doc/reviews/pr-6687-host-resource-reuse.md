# PR 6687: how close is host-resource reuse?

Subject: ubicloud/ubicloud PR #6687, "Reuse GithubRunner Vm resources instead
of reallocating", head `fd5fe94`, base `b74d3d6`.

Question: how close are we to a code edit that makes a new VM reuse a previous
VM's host resources (network namespaces, block devices)? The aim is a design
in which one oversight can never cause this.

Method: static review, done in a multi-agent workflow (65 agents). The phases were:

1. Map the host artifacts and the PR state machine.
2. Find candidate hazards through six lenses.
3. Deduplicate the candidates.
4. Verify each candidate with two or three adversarial verifiers.
5. Write three guard designs, then run a completeness critic.

I re-read the code for every claim in sections 1 to 4.

Limits:
- I did not run the spec suite. It needs Ruby 4.0.7 and Postgres; this container has Ruby 3.3.6.
- I did not read the PR comments. GitHub API access to ubicloud/ubicloud was denied in this session.

Line numbers refer to the PR head unless stated.

---

## 1. Short answer

- **Today, the PR reuses no on-host tenant object.** `Prog::Vm::Metal::Nexus#destroy` runs `setup-vm delete` (`prog/vm/metal/nexus.rb:604`) before the hold block (`:607-613`).
  - The claiming VM is a new `Vm` row with its own id. So it gets a new `inhost_name`, new storage paths, a new netns, a new KEK and a new DEK.
  - The PR moves only control-plane accounting: the slice row (and the live systemd slice), the storage capacity, the host, and the public IPv4 assignment.
- **In production, the PR transfers nothing yet, because of a bug.**
  - `reuse_for` sets the new VM's `sshable.host` to the IPv4 (`model/github/github_runner_vm_allocation.rb:68`).
  - The held VM's `sshable` still has that host. Nothing clears it before `old_vm.destroy` (`:78`).
  - `sshable_host_key` is `UNIQUE(host)` (`migrate/20230117_tables.rb:27`). So each claim raises, and the `start` label rolls back.
  - The specs do not catch this, because the held-VM fixtures have no `Sshable` (`spec/model/github/github_runner_vm_allocation_spec.rb:13-19`).
  - Any fix that makes the feature work also turns on every transfer below.
- **Block devices (cross-tenant plaintext disk): 2 plausible edits away.** Both routes skip `reuse_for`, so they do not depend on the sshable bug.
  - **Route A:** move the hold block to the top of `destroy` ("skip teardown for held VMs"), and remove `vm.update(pool_id: nil)` (`:610`). Then `VmPool#pick_vm` gives the still-running pool VM, with the previous tenant's disk, to the next tenant's runner.
  - **Route B:** give the held `Vm` row itself to the next runner, and skip `setup-vm delete` for held VMs. The VM then starts on the old `disk.raw` with the old KEK.
- **Network namespaces: rhizome never adopts a netns.** `interfaces()` deletes the netns, then creates it again under the VM's own name (`rhizome/host/lib/vm_setup.rb:239-259`). So netns reuse comes only with whole-VM reuse (the 2 edits above).
  - One edit is enough for harm next to the netns: move the hold above the purge. The fix that any author must make for the sshable bug is also needed.
  - The previous tenant's VM, disk, DEK and netns then stay alive with no DB row.
  - The next tenant gets the same public IPv4 and the same cpuset slice. The old netns keeps SNATing outbound traffic from that IPv4.
- **Pre-existing, 0 edits:** `inhost_name` is the first 8 characters of the UBID: `vm` plus 30 random bits (`model/vm.rb:197-199`). No check prevents two VMs with the same name on one host.
  - The code comment at `model/vm.rb:193-196` says so.
  - A collision today gives denial of service and crypto-erasure, not plaintext.
  - The only thing that stops plaintext is that `prep` always makes a new DEK (`rhizome/host/lib/storage_volume.rb:79`), and each volume row has its own KEK.
- **All the guards are conventions, not invariants.** They are a statement order, two incidental column writes, a root `pop`, an id-derived name, and a fresh key. Nothing records or checks that the host purge happened.
  - The spec expectations for the purge are not ordered (`spec/prog/vm/metal/nexus_spec.rb:1826-1828`).
  - On the host, nothing is created "fail if it exists". Rhizome adopts existing per-VM state, or deletes it and takes over.
- **Most fragile guard:** the position of the 7-line hold block in `destroy`, relative to `display_state: "deleting"` (`:582`) and `setup-vm delete` (`:604`). Moving that one block removes the host purge and the `pick_vm` exclusion together.

---

## 2. What the PR moves

| Value | New VM gets | On-host object it names or selects |
|---|---|---|
| `Vm.id` → `inhost_name` | fresh | user, `/vm/<name>`, netns, `vetho<name>`, `/etc/nftables.d/<name>.conf`, units, `/var/storage/.../<name>/<idx>/` |
| `vm_storage_volume` rows, KEK | fresh (made at assemble, `model/metal/vm.rb:204-235`) | wraps the DEK |
| DEK | fresh at every `prep` (`storage_volume.rb:79, 521-529`) | encrypts `disk.raw` |
| `vm_host_id` | moved | host |
| `vm_host_slice_id` | moved | live systemd slice / cgroup / cpuset named after the **old** VM (`scheduling/allocator.rb:576-577`) |
| `storage_device_id` per disk index | moved (rows updated by `allocate_storage_volume_associations`) | storage device directory only |
| `AssignedVmAddress` (public IPv4) | moved by `UPDATE dst_vm_id` (`github_runner_vm_allocation.rb:67`) | routes, nftables allow set, SNAT |
| `sshable.host` | set to the moved IPv4 (`:68`) | the control plane's SSH target |
| `ephemeral_net6`, `local_vetho_ip` | new random values | routes |

Storage "reuse" is capacity accounting only. The PR keeps the debit across the hold, because `pop` (`:612`) comes before `release_host_resources` (`:615`).

---

## 3. Host-side creation semantics

No per-VM artifact is created with fail-if-exists semantics. This is the root of the issue: the host never says "this name belongs to another VM".

| Artifact | What happens when the name already exists | Evidence |
|---|---|---|
| Unix user `vmXXXXXX` | `pkill -u`, `userdel -r`, `adduser` with a random uid: **takes over** | `prog/vm/metal/nexus.rb:148-163` |
| netns, veth, tap | `ip netns del` then `add`: **takes over** | `vm_setup.rb:239-259, 275` |
| nftables allow file | overwritten: **takes over** | `vm_setup.rb:122-136` |
| storage dir | `mkdir_p` + `chown`: **adopts** | `storage_volume.rb:77-78` |
| `disk.raw` | `touch` + `truncate`: **adopts the inode and its bytes** | `storage_volume.rb:755-757` |
| DEK | new at every prep; old wrapped DEK overwritten | `storage_volume.rb:79, 120-130` |
| SPDK bdevs | `SpdkExists` → purge → retry: **takes over** | `storage_volume.rb:449-457` |
| slice unit | **adopts** | `rhizome/host/lib/slice_setup.rb:34-35` |
| `prep_<name>` daemonizer unit in "Succeeded" | **prep is skipped** | `prog/vm/metal/nexus.rb:174-186` |
| writable unencrypted volume | **fails** (a real host guard) | `storage_volume.rb:28` |

So, on the host, the confidentiality of a previous tenant's blocks rests on three things:

1. a new name for each VM;
2. a new DEK at each `prep`;
3. a new KEK for each volume row, unwrapped with AES-GCM.

The host does not check that a KEK's `auth_data` (`"<inhost_name>_<idx>"`, `model/metal/vm.rb:220`) matches the volume it unlocks (`storage_key_encryption.rb:64-97`). ubiblk config v2 uses the constant AAD `"xts-key"` (`storage_volume.rb:349-351`). So if a KEK row moved to another VM, it would unwrap the old DEK.

---

## 4. Verified findings

"Edits" is the number of plausible code edits needed to get the harm. "+sshable" means the harm also needs the fix that the sshable bug forces. I counted that fix separately, because shipping the feature needs it anyway.

| # | Finding | Edits | Pre-existing | Impact | Verdict |
|---|---|---|---|---|---|
| F1 | `reuse_for` breaks `sshable_host_key` UNIQUE; every production claim rolls back; fixtures lack `Sshable` | 0 (bug) | no | feature does not work; its fix turns on F4, F7, F9 | confirmed by critic and all 3 designs; I re-checked |
| F2 | Route A: `pick_vm` gives a live held pool VM to another tenant. Guards: `display_state` (`:582`) and `pool_id: nil` (`:610`). The PR removed the third guard, the runner row (see below) | 2 | no | cross-tenant live VM: disk, memory, netns | confirmed (2 of 3 votes: critical) |
| F3 | Route B: give the held `Vm` row to the next runner and skip the purge; it starts on the old `disk.raw` with the old KEK | 2 or 3 | no | cross-tenant plaintext disk | confirmed (votes: 2 or 3 edits; severity critical / high / medium) |
| F4 | Hold above the purge (or purge deferred to release): the old VM, its disk, DEK and netns stay alive with no DB row, on the IPv4 and slice now owned by the next tenant | 1 + sshable | no | ghost VM shares cpuset and IPv4 identity with the next tenant | confirmed (high) |
| F5 | Purge made asynchronous or timeout-tolerant while the hold stays in `destroy` | 1 + sshable | no | same as F4, inside a race window | partially confirmed (medium) |
| F6 | Time-ordered VM UBIDs (for example adding `TYPE_VM` to `CURRENT_TIMESTAMP_TYPES`, `ubid.rb:125`): `inhost_name` becomes the top 30 bits of the ms timestamp, so all VMs made in the same ~262 s window share a name | 1 | yes | routine name collisions: see F8 | partially confirmed (medium) |
| F7 | Parked strand instead of root `pop`, with deferred purge: host-reboot or admin semaphores restart the held VM on its old disk while its IPv4 has moved | 2 + sshable | no | old tenant's VM back on the next tenant's IP | partially confirmed (medium) |
| F8 | `inhost_name` collision today: 30 bits, no per-host check. About 1.4e-4 per host-day at 5k VMs/day with 30 running. Effects: `pkill` of the live VM, netns and nftables take-over, `disk.raw` inode adopted (crypto-erased under a new DEK), slices merged, the victim's later delete purges the other tenant | 0 | yes | DoS, crypto-erase, cross-tenant serial-log read; no plaintext | confirmed (medium) |
| F9 | IPv4 goes to the next tenant deterministically, about 60 s later, by `UPDATE`. This also erases the previous tenant's tenure of the IP from `DeletedRecord` (abuse attribution) | 1 (sshable) | no | IP-identity reuse; lost attribution | confirmed (medium) |
| F10 | `destroy` does not stop an in-flight daemonized `setup-vm prep`. It can re-create the netns, route, nftables file and storage dir after the delete; the PR then hands the IPv4 and slice on within about 1 min | 1 (sshable) | race yes, hand-off no | orphans, IPv4 confusion | partially confirmed (low to medium) |
| F11 | The dedicated slice named after the dead VM lives on in the next tenant. A later VM with that name adopts the live slice: two tenants in one cpuset, and stopping either slice kills both | 0 | partly (burstable slices already do this) | DoS, co-location | partially confirmed (low) |
| F12 | `claim` is a second placement path. It skips most Allocator checks (`storage_device.enabled`, `os_filter`/`ch_version`, `ip4_enabled`, data-center exclusion, backend minimum version on SPDK hosts). A per-host name check added only to the Allocator, as `model/vm.rb:193-196` says to do, would not apply to `claim` | 0 | no | future host-safety checks silently bypassed | partially confirmed (low; structural) |
| F13 | Daemonizer v1 writes the prep stdin, which holds the plaintext storage KEKs, to `var/proc/prep_<name>.stdin` and never deletes it (`rhizome/common/bin/daemonizer:65-68`). daemonizer2 does delete its stdin file | 0 | yes | weakens crypto-erasure of orphaned disks | confirmed by reading |
| F14 | `runneradmin` SSH uses no host-key pinning (`model/sshable.rb:282`; `verify_host_key: :accept_new` with empty known-hosts). The public IPv4 is the only identity binding between the control plane and a runner VM | 0 | yes | in every IP-overlap hazard, the JIT config goes to whatever answers on the IP | confirmed by reading |
| F15 | The uid is `rand(1100..59999)` (`nexus.rb:149`) and gets reused. Orphaned files and the SPDK vhost socket ACL (`setfacl u:<name>:rw`) pass to whichever later VM user draws that uid | 0 | yes | turns an orphan into something another tenant's host process can reach | from critic; not voted |

More detail on F2: before the PR, `wait_vm_destroy` kept the `github_runner` row until the VM row was gone (`nap 10 unless vm.nil?`). `pick_vm` excludes VMs that have a runner row (`model/vm_pool.rb:15-17`). The PR changes this to `nap 10 if vm.strand` (`prog/github/github_runner_nexus.rb:879`), so the runner row goes as soon as the hold pops. After that, the only things that hide a held pool VM from `pick_vm` are `display_state != "running"` and `pool_id = NULL`. Both are single column writes in `destroy`, and they sit next to the hold block.

Refuted or low:
- **"`purge_user` first makes `delete` skip storage."** Refuted on ubiblk hosts: the ubiblk unit keeps `userdel` busy. The critic says it is valid on SPDK hosts, where it becomes a 1-edit orphan.
- **"Keep held VMs stopped and restart them."** Low plausibility.
- **No reuse risk:** GPU/VFIO (a held VM's `pci_devices` would make `old_vm.destroy` fail on the FK), hugetlbfs (memfd; the kernel zeroes pages), shared read-only boot images, NDP proxy entries (no data; the IPv6 range is drawn again).

---

## 5. Recommendations

Goal: one oversight must never be enough. Use three independent layers. Each layer fails closed by itself.

1. **Control plane:** never transfer identity-bearing rows.
2. **Hold gate:** a hold must not exist without proof that the host purge finished.
3. **Host:** never adopt per-VM state that was not created for this exact VM.

### Before merge (in this PR)

1. **Hold capacity, not a VM.**
   - Remove `vm_id` from `github_runner_vm_allocation`. Store only `vm_host_slice_id`, `storage_device_id`, `storage_gib`, `cpu_percent_limit`, `memory_gib` and `host_purge_verified_at`.
   - In `destroy`, after the purge, create the hold, then run `final_clean_up` as usual. The `Vm`, `Sshable`, `vm_storage_volume`/KEK and `AssignedVmAddress` rows are then destroyed and archived as usual.
   - Claim through `Scheduling::Allocator::Allocation#update_vm`, so the IPv4 comes from the normal random pick.
   - This removes F1 to F3, F7 and F9, and the KEK and sshable residue.
   - It also removes `release_held_allocation`, `Strand.create_with_id(vm_id)` and the `destroying` workaround. `wait_vm_destroy` can go back to `nap 10 unless vm.nil?`.
2. **Make the purge a data dependency, not a statement order.**
   - Add `setup-vm verify-purged <name>`. It exits non-zero if any of these remain: the user, `/vm/<name>`, the netns, `vetho<name>`, the nftables.d file, units (including `prep_<name>`), storage roots, the SPDK vhost sockets, the hugepages mount, or `var/proc/prep_<name>.stdin`. It also checks that the slice cgroup is empty.
   - Create a hold only through a `hold!` method that runs this check first, and make `host_purge_verified_at` `NOT NULL`. The migration is not deployed yet, so this costs nothing.
   - In `destroy`, before `setup-vm delete`, stop and reset `prep_<name>` and remove its stdin file. This fixes F10 and F13 for all VMs.
3. **Positive exclusion.**
   - If a held `Vm` row stays (if 1. is not done): `VmPool#pick_vm` must exclude VMs that have an allocation row or no strand.
   - `wait_vm_destroy` must check for a hold explicitly, not for `vm.strand`.
4. **Fix the fixtures.** Make the held-VM fixtures production-shaped: `Sshable` with the IP as host, an encrypted volume made by `create_storage_volumes` (so it has a KEK), a `Nic`, and an `AssignedVmAddress`. Add an isolation spec: the new VM shares no `inhost_name`, KEK id, storage path, unit name or tap name with the held VM. Make the destroy expectations `.ordered`.
5. **Keep IPv4 tenure attributable.** If the IPv4 must move to the next tenant, make that an explicit decision. Destroy and re-create the `AssignedVmAddress` instead of the `UPDATE`, so that `DeletedRecord` keeps the history.
6. **Ship with `github_runner_vm_allocation_ratio` default `0.0`** (`config.rb:266` sets `0.01`). Raise it only after items 1 and 2 are in place.

### Follow-ups (separate PRs, structural)

7. **Host fails closed.**
   - Use `Dir.mkdir` (not `mkdir_p`) for the storage root, and `File::EXCL` for `disk.raw` and the DEK file.
   - Do not purge and retry on `SpdkExists` during a first prep.
   - Do not `pkill` and `userdel` an existing user that has a different owner.
   - Allow idempotent retries only for the *same* VM. To decide this, write an ownership marker with the full VM UUID (not the 8-character prefix) at creation, and check it in every action.
8. **Per-host name uniqueness in the database.** The cheapest form is a unique expression index on `vm` over (`vm_host_id`, the 30 name bits of `id`). A stronger form is a per-host name registry that outlives the `Vm` row until the host confirms the purge.
   - Both placement paths would then hit the same constraint, which fixes F12 for names.
   - Name slices from the slice's own id, with `UNIQUE(vm_host_id, name)` on `vm_host_slice` (F11).
9. **Bind each KEK to its volume on the host.** Check `auth_data` against `<name>_<idx>` before unwrapping, and use a per-volume AAD in ubiblk config v2.
10. **Use one placement predicate** for both the Allocator and any reuse path (F12).
11. **Detection.**
    - Run a periodic host audit: every `/var/storage/**/<name>`, netns, unit and user must map to exactly one live VM UUID. Page on orphans.
    - Run a metal e2e that forces holds and claims (ratio 1.0).
12. **Defense in depth.**
    - Pin SSH host keys for `runneradmin` (generate the key in the control plane, inject it via cloud-init, and use `verify_host_key :always`) (F14).
    - Sandbox the cloud-hypervisor unit (`ProtectSystem`, `InaccessiblePaths=/var/storage` for other VMs).
    - Do not reuse a uid while anything is owned by it or has an ACL entry for it (F15).

Of these, items 1, 2 and 4 give the most protection for the least cost. Item 1 alone removes the whole class of "the same `Vm` row serves two tenants" hazards. Item 2 turns the most fragile guard (a statement order) into a checked precondition. Item 7 makes a host collision fail with an error instead of a silent take-over.

---

## Appendix: method and data

- Workflow: 4 mappers, then 6 finder lenses (35 raw candidates), deduplicated to 21, verified by 2 or 3 adversarial verifiers each (20 survived), then 3 guard designs and 1 completeness critic.
- The raw workflow output (maps, every vote with its reasoning, the full designs, and the critic) is in the git bundle on ref `review-raw/pr-6687`, file `doc/reviews/pr-6687-workflow-output.json`.
- Local refs used: `pr-6687` (PR head `fd5fe94`), `ubicloud-main`.
