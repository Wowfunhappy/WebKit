use proc_macro::TokenStream;
#[proc_macro]
pub fn answer(_: TokenStream) -> TokenStream {
    let mut values = std::collections::HashMap::new();
    values.insert("answer", 42);
    let before = std::time::Instant::now();
    assert!(before.elapsed() < std::time::Duration::from_secs(10));
    values["answer"].to_string().parse().unwrap()
}
