# homebrew-krun-balloon

A Homebrew tap with a `libkrun` build that gives guest memory back to macOS.

## The problem

With `krunkit` (and therefore `colima --vm-type krunkit`, `podman machine`), the host keeps
every page the guest has ever touched. Measured on macOS 26.6 (25G72), Apple silicon, 24 GiB
of RAM, colima 12 GiB guest, containers stopped:

```
guest:  MemTotal 12.2 GB, MemFree 11.2 GB
host:   krunkit phys_footprint 21.2 GB (peak 23.2 GB), 9.2 GB swapped out
```

libkrun 1.19.6 does attach a balloon and negotiates `VIRTIO_BALLOON_F_FREE_PAGE_HINT` and
`VIRTIO_BALLOON_F_REPORTING` with the guest, but on a free page report it calls
`madvise(MADV_FREE)`. That is a no-op for guest RAM on macOS: once the range is mapped into
the VM with `hv_vm_map`, XNU treats those pages as shared (they show up in `vmmap` as
`SM=SHM` regions), and `MADV_FREE` releases nothing. What does release them is replacing
them: `hv_vm_unmap`, `mmap(MAP_FIXED | MAP_PRIVATE | MAP_ANON)` over the same host
addresses, then `hv_vm_map` again. The range then reads as zeroes and is populated on first
access, as after `MADV_DONTNEED` on Linux.

That is what libkrun PR 931 does, upstream, for libkrun's main branch. krunkit links the
1.x ABI (`libkrun.1.dylib`, `krun_create_ctx`, `krun_set_firmware`), which main no longer
provides, so this tap carries the balloon part of that PR backported onto the released
v1.19.6 and builds it the same way the upstream formula does.

## Results

Separate 8 GiB / 4 CPU colima profile, workload: write 4 GiB into a tmpfs file, delete it.
`phys_footprint` of the krunkit process:

| build | idle | after writing 4 GiB | 5 s after delete | 30 s after delete |
|---|---|---|---|---|
| stock libkrun 1.19.6 | 5.1 GB | 5.4 GB | 5.4 GB | 5.4 GB |
| this tap | 811 MB | 4.8 GB | 1.0 GB | 1.0 GB |

A second cycle on the same VM: 1.0 GB -> 5.0 GB -> 1.4 GB (+5 s) -> 1.0 GB (+30 s), so
reporting keeps working. libkrun's log shows 454 reclaim calls, no range rejected, no error.

## What the patch contains

Backport of the balloon commits of https://github.com/containers/libkrun/pull/931:

- `WorkerMessage::ReclaimMemory` and its handler in the VMM worker thread;
- `Vm::reclaim_memory()`: unmap, replace with fresh anonymous pages, map back, and a check
  that the range is ordinary RAM rather than the firmware or an SHM region;
- bounds check on free page reports (`get_slice()` instead of `get_host_address().unwrap()`,
  which trusted the guest's length);
- `devices/src/virtio/balloon/macos.rs`: a reclaim thread, so the device's event loop is
  not held up, and a report is put in the used ring only once its pages are mapped into the
  guest again; reports shorter than 2 MiB or not 2 MiB aligned are still `madvise()`d, so
  the guest cannot make the VMM split the stage-2 mapping of its RAM into small pieces;
- the VMM worker thread is started on macOS whenever the VM runs (1.19.6 only started it
  for the GPU) and ends when its channel is closed.

Two changes are specific to this backport:

- `src/utils/src/macos/eventfd.rs`: `EventFd::new()` only set `O_NONBLOCK` for
  `flag == EFD_NONBLOCK`, while `pollable_channel()` passes `EFD_NONBLOCK | EFD_SEMAPHORE`.
  The blocking `read()` in `try_recv()` then stalls the caller's event loop: the first batch
  of reports is reclaimed, and after that the guest waits for a completion that never
  arrives and stops reporting. Upstream main already has this fixed
  (`flag & EFD_NONBLOCK != 0`); 1.19.6 does not, and PR 931 needs it.
- reclaim is on unconditionally. Upstream exposes it as
  `krun_balloon_device_set_free_page_reclaim()`, off by default, and krunkit does not call
  it (with the 1.x ABI it does not create the balloon at all, libkrun attaches it), so an
  opt-in knob would never be switched on for colima or podman machine users.

## Install

```sh
brew uninstall --ignore-dependencies libkrun
brew tap vetermanve/krun-balloon
brew install vetermanve/krun-balloon/libkrun
```

`krunkit` links `/opt/homebrew/opt/libkrun/lib/libkrun.1.dylib`, which now points at this
keg, so nothing else has to change. Restart the VM to pick it up (`colima stop && colima
start`).

Back to the stock build:

```sh
brew uninstall --ignore-dependencies vetermanve/krun-balloon/libkrun
brew untap vetermanve/krun-balloon
brew install libkrun
```

## Measuring it yourself

`tools/measure.sh <colima-profile> <tag>` prints the krunkit footprint next to the guest's
own `/proc/meminfo`. `tools/run-ab.sh <colima-profile> <label>` runs the write-and-delete
cycle and samples the footprint for 30 s afterwards.

To see what the balloon does, run krunkit with libkrun's log at debug level
(`--krun-log-level 4 --log-file <path>`) and grep for `balloon:` and `reclaim_memory:`.
