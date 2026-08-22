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

    struct TestCursor {
        bytes: Vec<u8>,
        offset: usize,
    }

    impl TestCursor {
        fn new(bytes: Vec<u8>) -> Self {
            Self { bytes, offset: 0 }
        }
    }

    impl MetadataCursor for TestCursor {
        fn take_byte(&mut self) -> Result<u8, PathHandshakeError> {
            let value = self
                .bytes
                .get(self.offset)
                .copied()
                .ok_or(PathHandshakeError::InvalidFrame)?;
            self.offset += 1;
            Ok(value)
        }

        fn take_u32(&mut self) -> Result<u32, PathHandshakeError> {
            let end = self.offset.saturating_add(4);
            let value = self
                .bytes
                .get(self.offset..end)
                .ok_or(PathHandshakeError::InvalidFrame)?;
            self.offset = end;
            Ok(u32::from_be_bytes(value.try_into().unwrap()))
        }

        fn take_bytes(&mut self, max: usize) -> Result<&[u8], PathHandshakeError> {
            let end = self.offset.saturating_add(2);
            let value = self
                .bytes
                .get(self.offset..end)
                .ok_or(PathHandshakeError::InvalidFrame)?;
            let length = u16::from_be_bytes(value.try_into().unwrap()) as usize;
            self.offset = end;
            if length == 0 || length > max {
                return Err(PathHandshakeError::InvalidFrame);
            }
            let end = self.offset.saturating_add(length);
            let value = self
                .bytes
                .get(self.offset..end)
                .ok_or(PathHandshakeError::InvalidFrame)?;
            self.offset = end;
            Ok(value)
        }
    }

    #[test]
    fn metadata_wire_round_trip_and_validation_boundaries_are_explicit() {
        assert_eq!(E2eePolicy::from_code(0), Ok(E2eePolicy::Required));
        assert_eq!(E2eePolicy::from_code(1), Ok(E2eePolicy::Disabled));
        assert_eq!(E2eePolicy::from_code(9), Err(PathHandshakeError::InvalidFrame));
        assert_eq!(PathKind::from_code(1), Ok(PathKind::Direct));
        assert_eq!(PathKind::from_code(2), Ok(PathKind::Relay));
        assert_eq!(PathKind::from_code(9), Err(PathHandshakeError::InvalidFrame));

        let metadata = PathHandshakeMetadata::new(
            E2eePolicy::Required,
            PathKind::Direct,
            b"session".to_vec(),
            b"direct/quic/v2".to_vec(),
        )
        .expect("metadata");
        let mut encoded = Vec::new();
        metadata.encode(&mut encoded).expect("encode metadata");
        let mut cursor = TestCursor::new(encoded.clone());
        assert_eq!(PathHandshakeMetadata::decode(&mut cursor).unwrap(), metadata);

        let mut old = encoded.clone();
        old[..4].copy_from_slice(&1u32.to_be_bytes());
        assert_eq!(
            PathHandshakeMetadata::decode(&mut TestCursor::new(old)),
            Err(PathHandshakeError::DowngradeRejected)
        );
        let mut future = encoded;
        future[..4].copy_from_slice(&3u32.to_be_bytes());
        assert_eq!(
            PathHandshakeMetadata::decode(&mut TestCursor::new(future)),
            Err(PathHandshakeError::PeerProtocolMismatch)
        );
        assert!(PathHandshakeMetadata::new(
            E2eePolicy::Required,
            PathKind::Direct,
            Vec::new(),
            b"direct/quic/v2".to_vec(),
        )
        .is_err());
        assert!(PathHandshakeMetadata::new(
            E2eePolicy::Required,
            PathKind::Direct,
            b"session".to_vec(),
            Vec::new(),
        )
        .is_err());
    }
