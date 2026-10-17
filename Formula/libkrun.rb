class Libkrun < Formula
  desc "libkrun with balloon free page reclaim on macOS (libkrun PR 931 backported to 1.19.6)"
  homepage "https://github.com/libkrun/libkrun"
  url "https://github.com/containers/libkrun/archive/refs/tags/v1.19.6.tar.gz"
  sha256 "7025d72208172dc06f791ad5af7ccaafeabdac9869f74ccb45fb6d4f6e5991cd"
  license "Apache-2.0"
  revision 1

  depends_on "lld" => :build
  depends_on "rust" => :build
  # Upstream only supports Hypervisor.framework on arm64
  depends_on arch: :arm64
  depends_on "dtc"
  depends_on "libepoxy"
  depends_on "libkrunfw"
  depends_on "virglrenderer-krun"
  depends_on "xz"

  # Gives free pages reported by the guest back to the host on macOS, where madvise()
  # does not release guest RAM: the VMM replaces the reported pages instead
  # (hv_vm_unmap -> mmap(MAP_FIXED|MAP_PRIVATE|MAP_ANON) -> hv_vm_map).
  # Backport of https://github.com/containers/libkrun/pull/931 onto v1.19.6, plus the
  # macos/eventfd O_NONBLOCK fix that the pollable channel of the reclaim thread needs.
  patch :DATA

  def install
    system "make", "BLK=1", "NET=1", "GPU=1", "TIMESYNC=1"
    system "make", "PREFIX=#{prefix}", "install"
  end

  test do
    (testpath/"test.c").write <<~EOS
      #include <libkrun.h>
      int main()
      {
         int c = krun_create_ctx();
         return 0;
      }
    EOS
    system ENV.cc, "test.c", "-I#{include}", "-L#{lib}", "-lkrun", "-o", "test"
    system "./test"
  end
end

__END__
diff --git a/src/devices/src/virtio/balloon/device.rs b/src/devices/src/virtio/balloon/device.rs
index 85b2812..d1eb940 100644
--- a/src/devices/src/virtio/balloon/device.rs
+++ b/src/devices/src/virtio/balloon/device.rs
@@ -52,6 +52,8 @@ pub struct Balloon {
     pub(crate) activate_evt: EventFd,
     pub(crate) device_state: DeviceState,
     config: VirtioBalloonConfig,
+    #[cfg(target_os = "macos")]
+    pub(super) reclaim: super::macos::FreePageReclaim,
 }
 
 impl Balloon {
@@ -64,6 +66,8 @@ impl Balloon {
                 .map_err(BalloonError::EventFd)?,
             device_state: DeviceState::Inactive,
             config: VirtioBalloonConfig::default(),
+            #[cfg(target_os = "macos")]
+            reclaim: Default::default(),
         })
     }
 
@@ -87,12 +91,28 @@ impl Balloon {
 
         while let Some(head) = queues[FRQ_INDEX].queue.pop(mem) {
             let index = head.index;
+            #[cfg(target_os = "macos")]
+            let mut reclaim_ranges = Vec::new();
             for desc in head.into_iter() {
-                let host_addr = mem.get_host_address(desc.addr).unwrap();
+                // The range comes from the guest. Releasing one that runs past the end of
+                // a guest memory region would discard whatever the VMM has mapped after it.
+                let Ok(slice) = mem.get_slice(desc.addr, desc.len as usize) else {
+                    warn!(
+                        "balloon: ignoring free page report outside guest memory: guest_addr={:?} len={}",
+                        desc.addr, desc.len
+                    );
+                    continue;
+                };
+                let host_addr = slice.ptr_guard_mut().as_ptr();
                 debug!(
                     "balloon: should release guest_addr={:?} host_addr={:p} len={}",
                     desc.addr, host_addr, desc.len
                 );
+                #[cfg(target_os = "macos")]
+                if self.reclaim.reclaims(desc.addr, desc.len) {
+                    reclaim_ranges.push(desc.addr.0..desc.addr.0 + u64::from(desc.len));
+                    continue;
+                }
                 #[cfg(target_os = "linux")]
                 let advice = libc::MADV_DONTNEED;
                 #[cfg(target_os = "macos")]
@@ -106,6 +126,11 @@ impl Balloon {
                 };
             }
 
+            #[cfg(target_os = "macos")]
+            if self.reclaim.submit(index, reclaim_ranges) {
+                continue;
+            }
+
             have_used = true;
             if let Err(e) = queues[FRQ_INDEX].queue.add_used(mem, index, 0) {
                 error!("failed to add used elements to the queue: {e:?}");
diff --git a/src/devices/src/virtio/balloon/event_handler.rs b/src/devices/src/virtio/balloon/event_handler.rs
index 2558d6e..0820b9a 100644
--- a/src/devices/src/virtio/balloon/event_handler.rs
+++ b/src/devices/src/virtio/balloon/event_handler.rs
@@ -145,6 +145,19 @@ impl Balloon {
                 error!("Failed to register balloon frq with event manager: {e:?}");
             });
 
+        #[cfg(target_os = "macos")]
+        if let Some(fd) = self.reclaim.done_fd() {
+            event_manager
+                .register(
+                    fd,
+                    EpollEvent::new(EventSet::IN, fd as u64),
+                    self_subscriber.clone(),
+                )
+                .unwrap_or_else(|e| {
+                    error!("Failed to register balloon reclaim with event manager: {e:?}");
+                });
+        }
+
         event_manager
             .unregister(self.activate_evt.as_raw_fd())
             .unwrap_or_else(|e| {
@@ -162,6 +175,8 @@ impl Subscriber for Balloon {
         let phq = self.queue_event(PHQ_INDEX).as_raw_fd();
         let frq = self.queue_event(FRQ_INDEX).as_raw_fd();
         let activate_evt = self.activate_evt.as_raw_fd();
+        #[cfg(target_os = "macos")]
+        let reclaim_done = self.reclaim.done_fd();
 
         if self.is_activated() {
             match source {
@@ -170,6 +185,8 @@ impl Subscriber for Balloon {
                 _ if source == stq => self.handle_stq_event(event),
                 _ if source == phq => self.handle_phq_event(event),
                 _ if source == frq => self.handle_frq_event(event),
+                #[cfg(target_os = "macos")]
+                _ if Some(source) == reclaim_done => self.handle_reclaim_done_event(event),
                 _ if source == activate_evt => {
                     self.handle_activate_event(event_manager);
                 }
diff --git a/src/devices/src/virtio/balloon/macos.rs b/src/devices/src/virtio/balloon/macos.rs
new file mode 100644
index 0000000..bb4d5ab
--- /dev/null
+++ b/src/devices/src/virtio/balloon/macos.rs
@@ -0,0 +1,344 @@
+use std::ops::Range;
+use std::os::fd::{AsRawFd, RawFd};
+use std::thread;
+
+use crossbeam_channel::{Receiver, Sender, unbounded};
+use utils::epoll::{EpollEvent, EventSet};
+use utils::pollable_channel::{PollableChannelReciever, PollableChannelSender, pollable_channel};
+use utils::worker_message::WorkerMessage;
+use vm_memory::GuestAddress;
+
+use super::device::{Balloon, FRQ_INDEX};
+use super::{BalloonError, Result};
+use crate::virtio::DeviceState;
+
+/// Smaller or unaligned reports are only madvise()d, so that the guest can't make the VMM split
+/// the stage-2 mapping of its RAM into small pieces. Linux reports 2 MiB blocks by default.
+const RECLAIM_ALIGN: u64 = 2 << 20;
+
+/// Has the VMM replace the pages of free page reports, which gives them back to the host.
+///
+/// A thread waits for the VMM worker, which may be busy, and a report is added to the used ring
+/// only once its pages are mapped into the guest again. The guest doesn't touch reported pages
+/// before that, so it never finds them unmapped.
+#[derive(Default)]
+pub(super) struct FreePageReclaim {
+    enabled: bool,
+    reclaimer: Option<Reclaimer>,
+}
+
+struct Reclaimer {
+    reports: Sender<Report>,
+    done: PollableChannelReciever<u16>,
+}
+
+struct Report {
+    head: u16,
+    ranges: Vec<Range<u64>>,
+}
+
+impl FreePageReclaim {
+    /// Whether a range of a report is to be reclaimed rather than madvise()d.
+    pub(super) fn reclaims(&self, addr: GuestAddress, len: u32) -> bool {
+        self.reclaimer.is_some() && reclaimable(addr, len)
+    }
+
+    /// Has the VMM reclaim the ranges of the report `head`. Returns false if there are none, in
+    /// which case the report can be completed right away.
+    pub(super) fn submit(&self, head: u16, ranges: Vec<Range<u64>>) -> bool {
+        match &self.reclaimer {
+            Some(reclaimer) if !ranges.is_empty() => {
+                reclaimer.reports.send(Report { head, ranges }).unwrap();
+                true
+            }
+            _ => false,
+        }
+    }
+
+    pub(super) fn done_fd(&self) -> Option<RawFd> {
+        self.reclaimer.as_ref().map(|r| r.done.as_raw_fd())
+    }
+}
+
+impl Reclaimer {
+    fn new(map_sender: Sender<WorkerMessage>) -> Result<Self> {
+        let (done_sender, done) = pollable_channel().map_err(BalloonError::EventFd)?;
+        let (reports, report_receiver) = unbounded();
+        thread::Builder::new()
+            .name("balloon reclaim".into())
+            .spawn(move || reclaim(report_receiver, map_sender, done_sender))
+            .map_err(BalloonError::ReclaimThread)?;
+        Ok(Self { reports, done })
+    }
+}
+
+fn reclaim(
+    reports: Receiver<Report>,
+    map_sender: Sender<WorkerMessage>,
+    done: PollableChannelSender<u16>,
+) {
+    for report in reports {
+        for range in report.ranges {
+            let (reply_sender, reply) = unbounded();
+            map_sender
+                .send(WorkerMessage::ReclaimMemory(
+                    reply_sender,
+                    range.start,
+                    range.end - range.start,
+                ))
+                .unwrap();
+            // Pages that the VMM couldn't replace are left as they were, which only costs memory.
+            reply.recv().unwrap();
+        }
+        done.send(report.head).unwrap();
+    }
+}
+
+fn reclaimable(addr: GuestAddress, len: u32) -> bool {
+    let len = u64::from(len);
+    len != 0 && addr.0.is_multiple_of(RECLAIM_ALIGN) && len.is_multiple_of(RECLAIM_ALIGN)
+}
+
+impl Balloon {
+    /// Set whether free page reports are given back to the host by having the VMM replace the
+    /// reported pages, instead of madvise()ing them, which doesn't release pages that the guest
+    /// has written to. Must be called before [`Balloon::set_map_sender`].
+    pub fn set_free_page_reclaim(&mut self, enabled: bool) {
+        self.reclaim.enabled = enabled;
+    }
+
+    /// Set the channel to the VMM worker, and start free page reclaim if it's enabled.
+    pub fn set_map_sender(&mut self, map_sender: Sender<WorkerMessage>) -> Result<()> {
+        if self.reclaim.enabled {
+            self.reclaim.reclaimer = Some(Reclaimer::new(map_sender)?);
+        }
+        Ok(())
+    }
+
+    pub(super) fn handle_reclaim_done_event(&mut self, event: &EpollEvent) {
+        let event_set = event.event_set();
+        if event_set != EventSet::IN {
+            warn!("balloon: reclaim done unexpected event {event_set:?}");
+            return;
+        }
+
+        let DeviceState::Activated(ref mem, _) = self.device_state else {
+            unreachable!()
+        };
+        let queue = &mut self
+            .queues
+            .as_mut()
+            .expect("queues should exist when activated")[FRQ_INDEX]
+            .queue;
+        let reclaimer = self
+            .reclaim
+            .reclaimer
+            .as_ref()
+            .expect("reclaimer should exist when its event fires");
+        let mut have_used = false;
+        while let Ok(Some(head)) = reclaimer.done.try_recv() {
+            have_used = true;
+            if let Err(e) = queue.add_used(mem, head, 0) {
+                error!("failed to add used elements to the queue: {e:?}");
+            }
+        }
+        if have_used {
+            self.device_state.signal_used_queue();
+        }
+    }
+}
+
+#[cfg(test)]
+mod tests {
+    use std::sync::atomic::Ordering;
+    use std::sync::Arc;
+    use std::thread::sleep;
+    use std::time::{Duration, Instant};
+
+    use utils::eventfd::{EFD_NONBLOCK, EventFd};
+    use vm_memory::GuestMemoryMmap;
+
+    use super::*;
+    use crate::legacy::DummyIrqChip;
+    use crate::virtio::queue::tests::VirtQueue;
+    use crate::virtio::queue::{VIRTQ_DESC_F_NEXT, VIRTQ_DESC_F_WRITE};
+    use crate::virtio::{
+        DeviceQueue, InterruptTransport, Queue, VIRTIO_MMIO_INT_VRING, VirtioDevice,
+    };
+
+    const TIMEOUT: Duration = Duration::from_secs(5);
+
+    struct TestDevice<'a> {
+        balloon: Balloon,
+        frq: VirtQueue<'a>,
+        interrupt: InterruptTransport,
+        worker: Receiver<WorkerMessage>,
+    }
+
+    impl<'a> TestDevice<'a> {
+        /// Attaches and activates a balloon, calling set_free_page_reclaim() unless `reclaim` is
+        /// None.
+        fn new(mem: &'a GuestMemoryMmap, reclaim: Option<bool>) -> Self {
+            let mut balloon = Balloon::new().unwrap();
+            if let Some(enabled) = reclaim {
+                balloon.set_free_page_reclaim(enabled);
+            }
+            let (map_sender, worker) = unbounded();
+            balloon.set_map_sender(map_sender).unwrap();
+
+            let frq = VirtQueue::new(GuestAddress(0), mem, 16);
+            let queues = (0..super::super::defs::NUM_QUEUES)
+                .map(|i| {
+                    let queue = if i == FRQ_INDEX {
+                        frq.create_queue()
+                    } else {
+                        Queue::new(16)
+                    };
+                    DeviceQueue::new(queue, Arc::new(EventFd::new(EFD_NONBLOCK).unwrap()))
+                })
+                .collect();
+            let interrupt =
+                InterruptTransport::new(DummyIrqChip::new().into(), "balloon".into()).unwrap();
+            balloon
+                .activate(mem.clone(), interrupt.clone(), queues)
+                .unwrap();
+
+            Self {
+                balloon,
+                frq,
+                interrupt,
+                worker,
+            }
+        }
+
+        /// Puts a report of free pages in the queue, as the guest does.
+        fn report(&self, ranges: &[(u64, u32)]) {
+            for (i, &(addr, len)) in ranges.iter().enumerate() {
+                let next = i + 1 < ranges.len();
+                let flags = VIRTQ_DESC_F_WRITE | if next { VIRTQ_DESC_F_NEXT } else { 0 };
+                self.frq.dtable[i].set(addr, len, flags, i as u16 + 1);
+            }
+            let idx = self.frq.avail.idx.get();
+            self.frq.avail.ring[usize::from(idx) % self.frq.dtable.len()].set(0);
+            self.frq.avail.idx.set(idx + 1);
+        }
+
+        fn used(&self) -> u16 {
+            self.frq.used.idx.get()
+        }
+
+        fn signaled(&self) -> bool {
+            self.interrupt.status().load(Ordering::Relaxed) & VIRTIO_MMIO_INT_VRING as usize != 0
+        }
+
+        fn handle_reclaim_done(&mut self) {
+            let fd = self.balloon.reclaim.done_fd().unwrap();
+            self.balloon
+                .handle_reclaim_done_event(&EpollEvent::new(EventSet::IN, fd as u64));
+        }
+    }
+
+    fn guest_memory() -> GuestMemoryMmap {
+        GuestMemoryMmap::from_ranges(&[(GuestAddress(0), 16 << 20)]).unwrap()
+    }
+
+    #[test]
+    fn test_reclaimable() {
+        assert!(reclaimable(GuestAddress(0x8000_0000), 2 << 20));
+        assert!(reclaimable(GuestAddress(0x8020_0000), 4 << 20));
+        assert!(!reclaimable(GuestAddress(0x8000_0000), 0));
+        assert!(!reclaimable(GuestAddress(0x8000_0000), 1 << 20));
+        assert!(!reclaimable(GuestAddress(0x8000_0000), 3 << 20));
+        assert!(!reclaimable(GuestAddress(0x8010_0000), 2 << 20));
+    }
+
+    #[test]
+    fn test_report_done_after_vmm_replies() {
+        let (map_sender, map_receiver) = unbounded();
+        let reclaimer = Reclaimer::new(map_sender).unwrap();
+        reclaimer
+            .reports
+            .send(Report {
+                head: 7,
+                ranges: vec![0x8000_0000..0x8020_0000, 0x8040_0000..0x8080_0000],
+            })
+            .unwrap();
+
+        for expected in [(0x8000_0000, 2 << 20), (0x8040_0000, 4 << 20)] {
+            let WorkerMessage::ReclaimMemory(reply_sender, guest_addr, len) =
+                map_receiver.recv().unwrap()
+            else {
+                panic!("unexpected worker message");
+            };
+            assert_eq!((guest_addr, len), expected);
+            assert_eq!(reclaimer.done.try_recv().unwrap(), None);
+            reply_sender.send(true).unwrap();
+        }
+
+        let deadline = Instant::now() + TIMEOUT;
+        let head = loop {
+            if let Some(head) = reclaimer.done.try_recv().unwrap() {
+                break head;
+            }
+            assert!(Instant::now() < deadline, "report not done");
+            sleep(Duration::from_millis(1));
+        };
+        assert_eq!(head, 7);
+    }
+
+    #[test]
+    fn test_reports_released_right_away_without_reclaim() {
+        let mem = guest_memory();
+        for reclaim in [None, Some(false)] {
+            let mut dev = TestDevice::new(&mem, reclaim);
+            dev.report(&[(0x40_0000, 2 << 20)]);
+            assert!(dev.balloon.process_frq());
+            assert_eq!(dev.used(), 1);
+            assert!(dev.worker.try_recv().is_err());
+            assert_eq!(dev.balloon.reclaim.done_fd(), None);
+        }
+    }
+
+    #[test]
+    fn test_small_reports_released_right_away() {
+        let mem = guest_memory();
+        let mut dev = TestDevice::new(&mem, Some(true));
+        dev.report(&[(0x40_0000, 1 << 20), (0x80_1000, 2 << 20)]);
+        assert!(dev.balloon.process_frq());
+        assert_eq!(dev.used(), 1);
+        assert!(dev.worker.try_recv().is_err());
+    }
+
+    #[test]
+    fn test_report_used_once_vmm_reclaimed_it() {
+        let mem = guest_memory();
+        let mut dev = TestDevice::new(&mem, Some(true));
+        // The second range is too small to be reclaimed, and is only madvise()d.
+        dev.report(&[(0x40_0000, 2 << 20), (0x80_0000, 0x1000)]);
+        assert!(!dev.balloon.process_frq());
+
+        let WorkerMessage::ReclaimMemory(reply_sender, guest_addr, len) =
+            dev.worker.recv_timeout(TIMEOUT).unwrap()
+        else {
+            panic!("unexpected worker message");
+        };
+        assert_eq!((guest_addr, len), (0x40_0000, 2 << 20));
+
+        // The guest mustn't get the pages back before they are mapped again.
+        dev.handle_reclaim_done();
+        assert_eq!(dev.used(), 0);
+        assert!(!dev.signaled());
+
+        reply_sender.send(true).unwrap();
+        let deadline = Instant::now() + TIMEOUT;
+        while dev.used() == 0 {
+            assert!(Instant::now() < deadline, "report not used");
+            sleep(Duration::from_millis(1));
+            dev.handle_reclaim_done();
+        }
+        assert_eq!(dev.used(), 1);
+        assert_eq!(dev.frq.used.ring[0].get().id, 0);
+        assert!(dev.signaled());
+        assert!(dev.worker.try_recv().is_err());
+    }
+}
diff --git a/src/devices/src/virtio/balloon/mod.rs b/src/devices/src/virtio/balloon/mod.rs
index 6859c79..31290f9 100644
--- a/src/devices/src/virtio/balloon/mod.rs
+++ b/src/devices/src/virtio/balloon/mod.rs
@@ -1,5 +1,7 @@
 mod device;
 mod event_handler;
+#[cfg(target_os = "macos")]
+mod macos;
 
 pub use self::defs::uapi::VIRTIO_ID_BALLOON as TYPE_BALLOON;
 pub use self::device::Balloon;
@@ -25,6 +27,9 @@ mod defs {
 pub enum BalloonError {
     /// Failed to create event fd.
     EventFd(std::io::Error),
+    /// Failed to start the free page reclaim thread.
+    #[cfg(target_os = "macos")]
+    ReclaimThread(std::io::Error),
 }
 
 type Result<T> = std::result::Result<T, BalloonError>;
diff --git a/src/libkrun/src/lib.rs b/src/libkrun/src/lib.rs
index a797fd1..635bc03 100644
--- a/src/libkrun/src/lib.rs
+++ b/src/libkrun/src/lib.rs
@@ -3058,10 +3058,9 @@ pub extern "C" fn krun_start_enter(ctx_id: u32) -> i32 {
         }
     };
 
+    // On macOS, devices (gpu, balloon) change the guest's memory map through the worker.
     #[cfg(target_os = "macos")]
-    if ctx_cfg.gpu_virgl_flags.is_some() {
-        vmm::worker::start_worker_thread(_vmm.clone(), _receiver).unwrap();
-    }
+    vmm::worker::start_worker_thread(_vmm.clone(), _receiver.clone()).unwrap();
 
     #[cfg(target_arch = "x86_64")]
     if ctx_cfg.vmr.split_irqchip {
diff --git a/src/utils/src/macos/eventfd.rs b/src/utils/src/macos/eventfd.rs
index c66ffba..d3e4a25 100644
--- a/src/utils/src/macos/eventfd.rs
+++ b/src/utils/src/macos/eventfd.rs
@@ -38,7 +38,7 @@ impl EventFd {
     pub fn new(flag: i32) -> result::Result<EventFd, io::Error> {
         let (read_fd, write_fd) = pipe()?;
 
-        if flag == EFD_NONBLOCK {
+        if flag & EFD_NONBLOCK != 0 {
             set_nonblock(&read_fd)?;
             set_nonblock(&write_fd)?;
         }
diff --git a/src/utils/src/worker_message.rs b/src/utils/src/worker_message.rs
index 50a4fcf..04c2b74 100644
--- a/src/utils/src/worker_message.rs
+++ b/src/utils/src/worker_message.rs
@@ -18,5 +18,9 @@ pub enum WorkerMessage {
     GpuAddMapping(crossbeam_channel::Sender<bool>, u64, u64, u64),
     #[cfg(target_os = "macos")]
     GpuRemoveMapping(crossbeam_channel::Sender<bool>, u64, u64),
+    /// Gives the host pages backing a range of guest RAM back to the system; the range reads
+    /// as zeroes afterwards. Replies whether they were given back.
+    #[cfg(target_os = "macos")]
+    ReclaimMemory(crossbeam_channel::Sender<bool>, u64, u64),
     ConvertMemory(crossbeam_channel::Sender<bool>, MemoryProperties),
 }
diff --git a/src/vmm/src/builder.rs b/src/vmm/src/builder.rs
index 72831f1..debba98 100644
--- a/src/vmm/src/builder.rs
+++ b/src/vmm/src/builder.rs
@@ -188,6 +188,9 @@ pub enum StartMicrovmError {
     RawOpenKernel(io::Error),
     /// Cannot initialize a MMIO Balloon device or add a device to the MMIO Bus.
     RegisterBalloonDevice(device_manager::mmio::Error),
+    /// Cannot set up free page reclaim for the balloon device.
+    #[cfg(target_os = "macos")]
+    BalloonReclaim(devices::virtio::BalloonError),
     /// Cannot initialize a MMIO Block Device or add a device to the MMIO Bus.
     RegisterBlockDevice(device_manager::mmio::Error),
     /// Cannot register an EventHandler.
@@ -375,6 +378,10 @@ impl Display for StartMicrovmError {
             RawOpenKernel(ref err) => {
                 write!(f, "Cannot open the file containing the kernel code: {err}")
             }
+            #[cfg(target_os = "macos")]
+            BalloonReclaim(ref err) => {
+                write!(f, "Cannot set up balloon free page reclaim: {err:?}")
+            }
             RegisterBalloonDevice(ref err) => {
                 let mut err_msg = format!("{err}");
                 err_msg = err_msg.replace('\"', "");
@@ -978,7 +985,13 @@ pub fn build_microvm(
     }
 
     #[cfg(not(feature = "tee"))]
-    attach_balloon_device(&mut vmm, event_manager, intc.clone())?;
+    attach_balloon_device(
+        &mut vmm,
+        event_manager,
+        intc.clone(),
+        #[cfg(target_os = "macos")]
+        _sender.clone(),
+    )?;
     #[cfg(not(feature = "tee"))]
     attach_rng_device(&mut vmm, event_manager, intc.clone())?;
     let mut console_id = 0;
@@ -2212,11 +2225,21 @@ fn attach_balloon_device(
     vmm: &mut Vmm,
     event_manager: &mut EventManager,
     intc: IrqChip,
+    #[cfg(target_os = "macos")] map_sender: Sender<WorkerMessage>,
 ) -> std::result::Result<(), StartMicrovmError> {
     use self::StartMicrovmError::*;
 
     let balloon = Arc::new(Mutex::new(devices::virtio::Balloon::new().unwrap()));
 
+    // On macOS, madvise() doesn't release guest RAM that the guest has written to, so free page
+    // reports only give memory back to the host if the VMM replaces the reported pages.
+    #[cfg(target_os = "macos")]
+    {
+        let mut balloon = balloon.lock().unwrap();
+        balloon.set_free_page_reclaim(true);
+        balloon.set_map_sender(map_sender).map_err(BalloonReclaim)?;
+    }
+
     event_manager
         .add_subscriber(balloon.clone())
         .map_err(RegisterEvent)?;
diff --git a/src/vmm/src/lib.rs b/src/vmm/src/lib.rs
index 0f0f8c2..54e637e 100644
--- a/src/vmm/src/lib.rs
+++ b/src/vmm/src/lib.rs
@@ -394,6 +394,28 @@ impl Vmm {
     pub fn remove_mapping(&self, reply_sender: Sender<bool>, guest_addr: u64, len: u64) {
         self.vm.remove_mapping(reply_sender, guest_addr, len);
     }
+
+    #[cfg(target_os = "macos")]
+    pub fn reclaim_memory(&mut self, reply_sender: Sender<bool>, guest_addr: u64, len: u64) {
+        let info = &self.arch_memory_info;
+        // Replacing the pages of the firmware or SHM regions, which are guest memory too, would
+        // break them.
+        if guest_addr < info.ram_start_addr || guest_addr + len > info.ram_last_addr {
+            warn!(
+                "Not reclaiming guest memory outside of RAM: guest_addr={guest_addr:x}, len={len}"
+            );
+            reply_sender.send(false).unwrap();
+            return;
+        }
+        match self.vm.reclaim_memory(&self.guest_memory, guest_addr, len) {
+            Ok(reclaimed) => reply_sender.send(reclaimed).unwrap(),
+            Err(e) => {
+                // The guest's accesses to the hole would be emulated as MMIO and lose data.
+                error!("Cannot map reclaimed guest memory back, stopping the VM: {e}");
+                self.stop(i32::from(FC_EXIT_CODE_GENERIC_ERROR));
+            }
+        }
+    }
 }
 
 impl Subscriber for Vmm {
diff --git a/src/vmm/src/macos/vstate.rs b/src/vmm/src/macos/vstate.rs
index ccafa1c..2a81796 100644
--- a/src/vmm/src/macos/vstate.rs
+++ b/src/vmm/src/macos/vstate.rs
@@ -159,6 +159,60 @@ impl Vm {
             reply_sender.send(true).unwrap();
         }
     }
+
+    /// Replaces the host pages backing a range of guest RAM with fresh anonymous memory, which
+    /// gives them back to the system and leaves the range reading as zeroes. madvise() can't do
+    /// this: it doesn't release the pages that the guest has written to.
+    ///
+    /// Returns whether the pages were replaced. If they weren't, the range is mapped as before.
+    /// An error means that it couldn't be mapped into the guest again.
+    pub fn reclaim_memory(
+        &self,
+        guest_mem: &GuestMemoryMmap,
+        guest_addr: u64,
+        len: u64,
+    ) -> Result<bool> {
+        // A range that isn't within a single region of guest memory would make mmap() replace
+        // whatever else the VMM has mapped after the region.
+        let Ok(slice) = guest_mem.get_slice(GuestAddress(guest_addr), len as usize) else {
+            warn!(
+                "Not reclaiming memory outside of a single guest memory region: guest_addr={guest_addr:x}, len={len}"
+            );
+            return Ok(false);
+        };
+        let host_addr = slice.ptr_guard_mut().as_ptr();
+        debug!("reclaim_memory: guest_addr={guest_addr:x}, len={len}");
+        if let Err(e) = self.hvf_vm.unmap_memory(guest_addr, len) {
+            error!("Error removing memory map: {e:?}");
+            return Ok(false);
+        }
+
+        // SAFETY: the range is within one region of guest memory, so only guest memory is
+        // replaced, and it stays mapped for the VMM's accesses.
+        let ret = unsafe {
+            libc::mmap(
+                host_addr.cast(),
+                len as usize,
+                libc::PROT_READ | libc::PROT_WRITE,
+                libc::MAP_FIXED | libc::MAP_PRIVATE | libc::MAP_ANON | libc::MAP_NORESERVE,
+                -1,
+                0,
+            )
+        };
+        let reclaimed = ret != libc::MAP_FAILED;
+        if !reclaimed {
+            // XNU puts the old pages back when a MAP_FIXED mmap() fails.
+            error!(
+                "Error replacing guest memory: {}",
+                io::Error::last_os_error()
+            );
+        }
+
+        self.hvf_vm
+            .map_memory(host_addr as u64, guest_addr, len)
+            .map_err(Error::SetUserMemoryRegion)?;
+        Ok(reclaimed)
+    }
 }
 
 /// Encapsulates configuration parameters for the guest vCPUS.
diff --git a/src/vmm/src/worker.rs b/src/vmm/src/worker.rs
index d0131b9..68845ce 100644
--- a/src/vmm/src/worker.rs
+++ b/src/vmm/src/worker.rs
@@ -25,25 +25,24 @@ pub fn start_worker_thread(
 ) -> io::Result<()> {
     std::thread::Builder::new()
         .name("vmm worker".into())
-        .spawn(move || loop {
-            match receiver.recv() {
-                Err(e) => error!("error receiving message from vmm worker thread: {e:?}"),
-                #[cfg(target_os = "macos")]
-                Ok(message) => vmm.lock().unwrap().match_worker_message(message),
-                #[cfg(target_os = "linux")]
-                Ok(message) => vmm.lock().unwrap().match_worker_message(message),
+        .spawn(move || {
+            // This ends once every sender is gone, as no message can arrive anymore.
+            for message in receiver {
+                vmm.lock().unwrap().match_worker_message(message);
             }
         })?;
     Ok(())
 }
 
 impl super::Vmm {
-    fn match_worker_message(&self, msg: WorkerMessage) {
+    fn match_worker_message(&mut self, msg: WorkerMessage) {
         match msg {
             #[cfg(target_os = "macos")]
             WorkerMessage::GpuAddMapping(s, h, g, l) => self.add_mapping(s, h, g, l),
             #[cfg(target_os = "macos")]
             WorkerMessage::GpuRemoveMapping(s, g, l) => self.remove_mapping(s, g, l),
+            #[cfg(target_os = "macos")]
+            WorkerMessage::ReclaimMemory(s, g, l) => self.reclaim_memory(s, g, l),
             #[cfg(target_arch = "x86_64")]
             WorkerMessage::GsiRoute(sender, entries) => {
                 let mut routing = kvm_bindings::KvmIrqRouting::new(entries.len()).unwrap();
