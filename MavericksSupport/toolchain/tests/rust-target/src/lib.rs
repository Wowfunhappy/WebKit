use std::sync::atomic::{AtomicUsize, Ordering};

struct UnwindDrop<'a>(&'a AtomicUsize);
impl Drop for UnwindDrop<'_> {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn target_runtime_smoke() -> i32 {
    let dropped = AtomicUsize::new(0);
    let caught = std::panic::catch_unwind(|| {
        let _guard = UnwindDrop(&dropped);
        panic!("expected target unwind probe");
    });
    if caught.is_ok() || dropped.load(Ordering::SeqCst) != 1 {
        return 1;
    }

    let mut values = std::collections::HashMap::new();
    values.insert(1, 42);
    let worker = std::thread::spawn(|| {
        let start = std::time::Instant::now();
        std::thread::sleep(std::time::Duration::from_millis(1));
        (42, start.elapsed().as_nanos() > 0)
    });
    if worker.join().unwrap() != (values[&1], true) {
        return 2;
    }

    let directory = std::env::temp_dir().join(format!("webkit-rust-target-{}", std::process::id()));
    std::fs::create_dir(&directory).unwrap();
    let source = directory.join("source");
    let destination = directory.join("destination");
    std::fs::write(&source, b"Mavericks Rust target").unwrap();
    let copied = std::fs::copy(&source, &destination).unwrap();
    let content = std::fs::read(&destination).unwrap();
    std::fs::remove_dir_all(&directory).unwrap();
    if copied != content.len() as u64 || content != b"Mavericks Rust target" {
        return 3;
    }
    42
}
