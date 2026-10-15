# vm — baseline snapshot and golden-image rails

Moved verbatim out of `SKILL.md` "Safety rails". Read before touching `ubuntu_new` snapshots,
cloning `himmel-ar-N`, or rebuilding the golden image.

- **The baseline snapshot is `suite-ready-v4`; all three older snapshots are
  kept, deliberately.** Three image-level facts, not incident colour —
  introduced at v2/v3 and carried forward unchanged into v4:
  1. `VBoxManage clonevm` regenerates MACs, and the ORIGINAL (`suite-ready`,
     v1) base image's netplan pinned `match: macaddress:` to the SOURCE VM's
     own MAC — so every linked clone of it got a NIC matching nothing: no
     DHCP, no ssh, ever, for ANY clone. Fixed at image level (netplan now
     matches on interface NAME; cloud-init's network config is disabled so
     it cannot regenerate a MAC-pinned file).
  2. `VBoxManage snapshot restore` reverts MACHINE CONFIG, not just disk, so
     a per-clone `modifyvm` fix would be silently undone on the very next
     restore — only an image-level fix persists, which is why the netplan
     fix needed a new base snapshot (`suite-ready-v2`) rather than a
     per-clone patch, and why v4 bakes its own machine-config change
     (bidirectional clipboard AND drag-and-drop) into the snapshot the same
     way.
  3. A linked clone also INHERITS the source's `/etc/machine-id` and ssh
     host keys verbatim (confirmed empirically: source and clone shared the
     same machine-id and all three host-key fingerprints) — an identity
     collision `suite-ready-v2` still had. Fixed by shipping an
     UNPERSONALISED golden image (`suite-ready-v3`: machine-id zeroed, dbus
     id symlinked to it, host keys removed, a first-boot oneshot
     regenerating both) — each CLONE of it then regenerates its OWN
     identity on its first boot, which is why a clone's own baseline
     snapshot must be taken AFTER that first boot, never before. v4 ships
     the same unpersonalised state, and the HIMMEL-2747 re-clone of
     `himmel-ar-1` reconfirmed this empirically rather than assuming it:
     fresh machine-id `3234173620d64e4abedbf4756cb3812c` and freshly
     generated ECDSA/ED25519/RSA host keys at first boot
     (2026-09-07T11:13:24Z), none inherited from `ubuntu_new`.
  `suite-ready` (v1) is NOT dead weight to tidy up: `himmel-ar-1`'s
  linked-clone disk chain still runs back through it (v4 -> ... -> v1 -> the
  base cloud image, four `ubuntu_new` differencing disks deep).
  `suite-ready-v2` and `suite-ready-v3` also still exist on `ubuntu_new` for
  the same reason: superseded, never deleted, not the default.
- **The default is `suite-ready-v4` (HIMMEL-2738/2681/2747).** v4 adds, over
  v3: VirtualBox Guest Additions userspace (`virtualbox-guest-utils`,
  installed guest-side since the host has no `VBoxGuestAdditions.iso` to
  attach); bidirectional clipboard AND drag-and-drop set as MACHINE CONFIG
  (with the VM powered off, so it lives in the snapshot; draganddrop moved
  disabled -> bidirectional); a tty1 auto-login drop-in so an operator has a
  console at all; and node 24.20.0 + npm 11.19.0 + bun 1.4.2 + unzip +
  Claude Code 2.1.263, closing HIMMEL-2681's runtime-skew precondition (v3
  shipped node 18.19.1 against this repo's `.nvmrc` pin of 24, and no bun).
  The move was made by delete-and-re-clone (HIMMEL-2747, 2026-09-07), not by
  pointing the existing `himmel-ar-1` clone at a newer snapshot name — a
  linked clone's disk chain is bound to the source snapshot it was cut from,
  and no VBoxManage operation re-points it. The operator ran `VBoxManage
  unregistervm himmel-ar-1 --delete` on the old v3-based clone and
  re-created `himmel-ar-1` as a fresh linked clone of
  `ubuntu_new@suite-ready-v4`, booted it once so
  `himmel-firstboot-identity` could regenerate its identity (confirmed, see
  fact 3 above), then powered off and snapshotted the clone's OWN baseline
  as `suite-ready-v4`. Machine config (NAT forward, 4096MB RAM, 4 cpus, vram
  32, vmsvga, nic1 nat) was reproduced from the persisted pre-delete
  baseline, with `draganddrop` moved to `bidirectional` to match the new
  image; guest content (node 24.20.0, npm 11.19.0, bun 1.4.2, claude
  2.1.263) was confirmed present. **Known caveat:** bun is on the
  login-shell PATH via `.bashrc` but NOT on the non-interactive ssh PATH
  `after-report.sh`'s `guest_ssh()` actually uses, so a guest suite run
  through that script does not currently see it — a separate ticket, not
  fixed here. **The vacuous-pass trap for the NEXT migration (v4 -> v5):** a
  snapshot merely NAMED `suite-ready-vN` on a clone that still carries the
  PREVIOUS image's guest content reports green while silently measuring the
  suites on stale software — the exact trap HIMMEL-2681 exists to stop.
  Hand-upgrading the guest inside a clone's own writable differencing disk
  is technically possible and is rejected on MERIT, not impossibility: it
  produces a hand-provisioned near-duplicate of the golden image that no
  longer descends from it, drifting silently — "restore to the baseline"
  would then mean "restore to whatever someone typed into this one clone."
  The only sound path, demonstrated by this migration: delete the clone for
  real (an operator action, refused outright by this harness's auto-mode
  classifier so it cannot happen from a session), re-clone from the new
  golden snapshot, boot once to regenerate identity, verify machine-id/
  host-keys are actually fresh and guest content actually matches the new
  image, THEN move `scripts/vm/after-report.sh`'s, `dry-run-restore.sh`'s
  and this file's default together — `test-after-report.sh`'s T10 asserts
  all three agree.
- **`suite-ready-v4` vs `suite-ready-v4-auth`.** `suite-ready-v4`
  (`92a7e71a-6dbd-48a9-bda3-fc1ef1dadfc7`) is the golden, credential-free,
  cloneable base. `suite-ready-v4-auth` (`eb401446-0b61-4fe5-a679-541b427adfe4`)
  is a separate snapshot taken after the operator's one manual `claude`
  login — it is personalised and must NEVER be the source of an
  after-report linked clone, or of any image handed to another machine.
  The HIMMEL-2457 acceptance cells (K1/K2/K2b/K5) run DIRECTLY on
  `ubuntu_new@suite-ready-v4-auth`, restoring that snapshot BETWEEN cells —
  never on a linked clone of it: a restore-per-cell gives the same "no cell
  inherits another" guarantee a fresh clone would, without replicating the
  operator's OAuth credentials into a second registered VM, which is
  exactly what the v4 / v4-auth split exists to prevent. Cloning a
  credential-bearing image is forbidden; clone `suite-ready-v4` (the
  golden, credential-free base) instead.
- **The golden image is snapshotted UNPERSONALISED.** "Snapshot after a
  first boot" (above) is a rule for a CLONE's own baseline, not for the
  golden image — the golden image is snapshotted BEFORE any identity
  exists. If a leg boots `ubuntu_new` to modify the image, it must
  re-de-personalise before snapshotting: truncate `/etc/machine-id` to 0
  bytes, symlink `/var/lib/dbus/machine-id` to it, remove
  `/etc/ssh/ssh_host_*`, re-create `/etc/himmel-regen-identity` (the
  `himmel-firstboot-identity.service` `ConditionPathExists=|` trigger), and
  confirm that service is `enabled`. Skipping this ships a personalised
  golden image — exactly the machine-id/host-key collision `suite-ready-v3`
  was cut to fix, one level up.
- **No GUI in the guest.** This image has no display manager and no X
  server, so the bidirectional clipboard machine-config setting (above) is
  correct and necessary but has nothing to attach to — `VBoxClient
  --clipboard` needs an X11/Wayland session, and a guest-side clipboard
  round trip is NOT achievable on this image. Do not spend a leg trying to
  verify one. Two host→guest text paths ARE proven: (a) `ssh -p 2222
  himmel@127.0.0.1` from a host terminal, using the HOST's own clipboard;
  (b) `VBoxManage controlvm ubuntu_new keyboardputstring "<text>"` followed
  by `VBoxManage controlvm ubuntu_new keyboardputscancode 1c 9c` (Enter),
  typing straight into the auto-logged-in tty1 console.
