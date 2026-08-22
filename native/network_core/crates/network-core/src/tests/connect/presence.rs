use super::*;

#[test]
fn hints_are_ui_only_and_track_online_offline() {
    let cache = PresenceHintCache::new();
    cache.mark_online("device-b", 7);
    assert_eq!(cache.get("device-b"), Some(PresenceHint::new(true, 7)));
    cache.mark_offline("device-b");
    assert_eq!(cache.get("device-b"), Some(PresenceHint::new(false, 0)));
    assert_eq!(cache.get("device-c"), None);
}

#[test]
fn snapshot_reconcile_drops_absent_peers() {
    let cache = PresenceHintCache::new();
    cache.mark_online("device-b", 1);
    cache.mark_online("device-c", 2);
    let dropped = cache.reconcile_snapshot(&[("device-b".to_string(), 9)]);
    assert_eq!(dropped, vec!["device-c".to_string()]);
    assert_eq!(cache.get("device-b"), Some(PresenceHint::new(true, 9)));
    assert_eq!(cache.get("device-c"), None);
    assert_eq!(cache.len(), 1);
}

#[test]
fn available_hint_marks_online_with_new_generation() {
    let cache = PresenceHintCache::new();
    cache.mark_online("device-b", 11);
    assert_eq!(cache.get("device-b"), Some(PresenceHint::new(true, 11)));
    cache.mark_online("device-b", 12);
    assert_eq!(cache.get("device-b"), Some(PresenceHint::new(true, 12)));
}
