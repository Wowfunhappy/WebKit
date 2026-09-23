fn main() {
    let shared = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let threads: Vec<_> = (0..16).map(|i| {
        let shared = shared.clone();
        std::thread::spawn(move || { shared.lock().unwrap().insert(i, i); })
    }).collect();
    for thread in threads { thread.join().unwrap(); }
    assert_eq!(shared.lock().unwrap().len(), 16);
    assert!(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() > 0);
    println!("cargo:rustc-env=HOST_BUILD_SCRIPT_RAN=1");
}
