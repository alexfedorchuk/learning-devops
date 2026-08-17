# Day 7 — Filesystems, disk, LVM

Date:
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Three questions from previous days, answered aloud before any new material — all
three correct, no corrections needed:

1. Day 2: why doesn't `ulimit -n 65535` in `.bashrc` fix a systemd service's
   file-descriptor limit? `.bashrc` only applies to interactive shells; a
   service never goes through it. Real fix: `LimitNOFILE=` on the unit.
2. Day 4: why does the current SSH session survive `systemctl restart sshd` with a
   broken config? `restart` replaces only the master process; each connection is
   its own forked child, untouched by the master's restart.
3. Day 5: `Requires=` vs `Wants=` — when does the dependency failing take the unit
   down with it? `Requires=` is hard — the dependent unit gets stopped too.
   `Wants=` is soft — the unit proceeds regardless.

## What I did

1. Observed the real system (read-only): `lsblk -f`, `blkid`, `mount | column -t`,
   `cat /etc/fstab`, `df -h`, `df -i`, `du -sh` — noted `/etc/fstab` uses `UUID=`
   rather than `/dev/mmcblk0pX`, since device names aren't guaranteed stable across
   boots.
2. Built a loop-device playground instead of touching the real SD card: two 100 MB
   image files (`dd if=/dev/zero of=~/diskN.img bs=1M count=100`), attached both with
   `sudo losetup -fP`.
3. Full LVM chain on the loop devices: `pvcreate` on both loop devices → `vgcreate
   labvg` → `lvcreate -L 50M -n labvol labvg` → `mkfs.ext4` → mounted at
   `/mnt/labvol`. Extended it live with `lvextend -r -L +50M /dev/labvg/labvol`,
   confirmed the grown size with `df -h`.
4. Looked at `swap`/`tmpfs`/`/dev/shm`: `cat /proc/swaps`, `free -h`, `mount | grep
   tmpfs`, `df -h /dev/shm`.
5. Break-it #1 — inode exhaustion on `/mnt/labvol` (loop-backed, not the real disk):
   filled it with empty files until it failed.
6. Break-it #2 — added a broken line to `/etc/fstab`, tested with `sudo mount -a`
   instead of an actual reboot (no physical/serial console recovery path available
   yet — see day 4's Open questions).
7. Cleanup: removed the test files, `lvremove`/`vgremove`/`pvremove`, detached both
   loop devices, deleted the image files, removed the fstab line.

## What broke

1. **Inode exhaustion, as intended.** `df -h /mnt/labvol` still showed free space,
   while `df -i /mnt/labvol` was at 100% `IUse%` — the volume ran out of inodes long
   before it ran out of bytes, since inode count is fixed at format time and is a
   separate budget from data blocks.
2. **fstab break-it — different failure than planned, more interesting.** The line
   added was `/dev/loop0 /mnt/labvol ext4 defaults 0 2` — `/dev/loop0` was the raw
   loop device, not the LVM logical volume actually formatted with ext4
   (`/dev/labvg/labvol`). `sudo mount -a` failed with `Device or resource busy`,
   not the expected "does not exist": `/dev/loop0` was already held open
   exclusively by LVM's device-mapper as an active PV inside `labvg`. The kernel
   refused the mount at the "who else has this device open" check, before it ever
   got to look for a filesystem superblock — `/dev/loop0` never had one in the first
   place, since the ext4 filesystem lives on the LV built on top of it, not on the
   raw PV itself.

## What surprised me

- The full LVM chain end to end: **file → loop device → Physical Volume → Volume
  Group → Logical Volume**. The point of all four layers isn't complexity for its
  own sake — it's that disk space becomes manageable live, without stopping the
  system (grow a volume, add a disk to a group) in a way a plain partition, fixed to
  one boundary on one disk, can't do.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. `du` says 40 GB, `df` says 80 GB used. Three possible reasons.

   - Deleted-but-open files: a process still holds an fd on a deleted file, so the
     data blocks are still allocated (`df` counts them) but there's no directory
     entry left for `du` to walk.
   - `du` was run without permission to read some directories and silently skipped
     them, undercounting — `df` reports the filesystem-level truth regardless of who
     asks.
   - Scope mismatch: `du` measured one subtree (e.g. `/home`), while `df` reports
     usage for the **whole mounted filesystem**, which includes other directories
     `du` was never pointed at.

2. Why use LVM when plain partitions exist?

   A plain partition is fixed to one boundary on one physical disk. LVM adds a layer
   (PV → VG → LV) that turns disk space into a flexible, resizable pool: grow a
   volume live (`lvextend -r`) or combine multiple physical disks into a single
   volume group — none of which a plain partition can do without unmounting,
   repartitioning, or downtime.

3. What is a loop device, and where is it actually used?

   A virtual block device backed by a regular file — the kernel lets that file be
   treated (partitioned, formatted, mounted) exactly like a real disk. Used for
   mounting ISO images, and as the backing store for container/VM images (Docker
   image layers, VirtualBox/qemu disks) — today's practice used it to build a safe
   LVM/inode playground without touching the real SD card.

## Open questions
