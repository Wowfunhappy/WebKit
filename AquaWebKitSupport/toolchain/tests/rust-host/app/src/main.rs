#[inline(never)]
fn use_main_stack() {
    let mut bytes = [0u8; 768 * 1024];
    std::hint::black_box(&mut bytes);
    bytes[0] = 42;
    assert_eq!(std::hint::black_box(bytes[0]), 42);
}

fn main() {
    use_main_stack();
    assert_eq!(host_macros::answer!(), 42);
    assert_eq!(env!("HOST_BUILD_SCRIPT_RAN"), "1");
    println!("PASS: host build script, proc macro, entropy, time, threaded locks and main stack beyond 512 KiB");
}
