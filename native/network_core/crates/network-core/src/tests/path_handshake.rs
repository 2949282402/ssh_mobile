    use super::*;
    use network_identity::DeviceIdentity;

    fn identity(id: &str, seed: u8) -> DeviceIdentity {
        DeviceIdentity::from_private_keys(id.into(), [seed; 32], [seed.wrapping_add(1); 32])
    }

    #[test]
    fn metadata_transcript_binds_versions_identities_policy_binding_and_profile() {
        let initiator = identity("initiator", 1);
        let responder = identity("responder", 3);
        let metadata = PathHandshakeMetadata::new(
            E2eePolicy::Required,
            PathKind::Direct,
            b"session-binding".to_vec(),
            b"direct/quic/v2".to_vec(),
        )
        .unwrap();
        let first = metadata
            .transcript_hash(
                &initiator.device_id,
                &initiator.public_identity_key().to_bytes(),
                &responder.device_id,
                &responder.public_identity_key().to_bytes(),
                E2eePolicy::Required,
            )
            .unwrap();
        let disabled = PathHandshakeMetadata::new(
            E2eePolicy::Disabled,
            PathKind::Direct,
            b"session-binding".to_vec(),
            b"direct/quic/v2".to_vec(),
        )
        .unwrap();
        assert_ne!(
            first,
            disabled
                .transcript_hash(
                    &initiator.device_id,
                    &initiator.public_identity_key().to_bytes(),
                    &responder.device_id,
                    &responder.public_identity_key().to_bytes(),
                    E2eePolicy::Disabled,
                )
                .unwrap()
        );
        for changed in [
            PathHandshakeMetadata::new(
                E2eePolicy::Required,
                PathKind::Direct,
                b"other-binding".to_vec(),
                b"direct/quic/v2".to_vec(),
            )
            .unwrap(),
            PathHandshakeMetadata::new(
                E2eePolicy::Required,
                PathKind::Direct,
                b"session-binding".to_vec(),
                b"direct/tcp/v2".to_vec(),
            )
            .unwrap(),
        ] {
            assert_ne!(
                first,
                changed
                    .transcript_hash(
                        &initiator.device_id,
                        &initiator.public_identity_key().to_bytes(),
                        &responder.device_id,
                        &responder.public_identity_key().to_bytes(),
                        E2eePolicy::Required,
                    )
                    .unwrap()
            );
        }
        assert_ne!(
            first,
            metadata
                .transcript_hash(
                    &responder.device_id,
                    &responder.public_identity_key().to_bytes(),
                    &initiator.device_id,
                    &initiator.public_identity_key().to_bytes(),
                    E2eePolicy::Required,
                )
                .unwrap()
        );
    }

    #[test]
    fn policy_rules_are_fail_closed() {
        assert_eq!(
            E2eePolicy::from_network_code(network_protocol::E2eePolicy::Required as i32),
            Ok(E2eePolicy::Required)
        );
        assert_eq!(
            E2eePolicy::from_network_code(network_protocol::E2eePolicy::Disabled as i32),
            Ok(E2eePolicy::Disabled)
        );
        assert_eq!(
            E2eePolicy::from_network_code(99),
            Err(PathHandshakeError::InvalidFrame)
        );
        assert_eq!(
            negotiate_security(PathKind::Direct, E2eePolicy::Required, E2eePolicy::Disabled),
            Err(PathHandshakeError::SecurityPolicyMismatch)
        );
        assert_eq!(
            negotiate_security(PathKind::Direct, E2eePolicy::Required, E2eePolicy::Required),
            Ok(PathSecurity::E2ee)
        );
        assert_eq!(
            negotiate_security(PathKind::Direct, E2eePolicy::Disabled, E2eePolicy::Disabled),
            Ok(PathSecurity::IdentityOnly)
        );
        assert_eq!(
            negotiate_security(PathKind::Relay, E2eePolicy::Disabled, E2eePolicy::Disabled),
            Err(PathHandshakeError::RelayRequiresE2ee)
        );
        assert_eq!(
            PathHandshakeMetadata::new(
                E2eePolicy::Disabled,
                PathKind::Relay,
                b"binding".to_vec(),
                b"relay-data/v2".to_vec(),
            ),
            Err(PathHandshakeError::RelayRequiresE2ee)
        );
    }
