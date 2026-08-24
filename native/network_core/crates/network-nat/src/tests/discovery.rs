use super::*;

#[test]
fn never_advertises_unspecified_or_loopback_addresses() {
    assert!(!is_advertisable("0.0.0.0".parse().unwrap()));
    assert!(!is_advertisable("127.0.0.1".parse().unwrap()));
    assert!(!is_advertisable("169.254.1.20".parse().unwrap()));
    assert!(!is_advertisable("224.0.0.1".parse().unwrap()));
    assert!(!is_advertisable("255.255.255.255".parse().unwrap()));
    assert!(!is_advertisable("::".parse().unwrap()));
    assert!(!is_advertisable("::1".parse().unwrap()));
    assert!(!is_advertisable("ff02::1".parse().unwrap()));
    assert!(!is_advertisable("fc00::1".parse().unwrap()));
    assert!(is_advertisable("2001:db8::10".parse().unwrap()));
    assert!(is_advertisable("192.168.1.20".parse().unwrap()));
}

#[tokio::test]
async fn discovered_candidates_are_unique_and_use_the_requested_port() {
    let candidates = discover_candidates(42).await;
    let mut addresses = HashSet::new();
    for candidate in candidates {
        assert_eq!(candidate.endpoint.port(), 42);
        assert!(!candidate.endpoint.ip().is_unspecified());
        assert!(!candidate.endpoint.ip().is_loopback());
        assert!(addresses.insert(candidate.endpoint));
    }
}
