use super::*;

#[test]
fn signaling_state_machine_requires_offer_before_answer() {
    let mut machine = SignalingStateMachine::default();
    assert!(matches!(
        machine.local_answer(),
        Err(SignalingError::InvalidTransition(SignalingState::New))
    ));
    machine.local_offer().unwrap();
    machine.remote_answer().unwrap();
    assert_eq!(machine.state(), SignalingState::Connected);
    assert_eq!(machine.revision(), 2);
}

#[test]
fn signaling_inputs_are_bounded_and_validated() {
    assert!(SessionDescription::new(DescriptionType::Offer, "v=0\r\n".into()).is_ok());
    assert!(matches!(
        SessionDescription::new(DescriptionType::Offer, "s=invalid".into()),
        Err(SignalingError::InvalidDescription)
    ));
    assert!(IceCandidate::new("candidate:1".into(), None, Some(0), None).is_ok());
    assert!(matches!(
        IceCandidate::new("invalid".into(), None, None, None),
        Err(SignalingError::InvalidCandidate)
    ));
}

#[test]
fn remote_offer_can_start_a_new_generation_after_a_local_answer() {
    let mut machine = SignalingStateMachine::default();
    machine.remote_offer().unwrap();
    machine.local_answer().unwrap();
    machine.remote_offer().unwrap();
    assert_eq!(machine.state(), SignalingState::RemoteOffer);
    assert_eq!(machine.revision(), 3);
}

#[test]
fn signaling_values_reject_empty_and_oversized_inputs() {
    assert!(matches!(
        SessionDescription::new(DescriptionType::Offer, String::new()),
        Err(SignalingError::EmptyDescription)
    ));
    assert!(matches!(
        SessionDescription::new(DescriptionType::Offer, "v=0".repeat(MAX_SDP_BYTES)),
        Err(SignalingError::DescriptionTooLarge)
    ));
    assert!(matches!(
        IceCandidate::new("x".repeat(MAX_ICE_CANDIDATE_BYTES + 1), None, None, None),
        Err(SignalingError::CandidateTooLarge)
    ));
    let end = IceCandidate::end_of_candidates();
    assert!(end.candidate.is_empty());
    assert!(IceCandidate::new(String::new(), None, None, None).is_ok());
}

#[test]
fn signaling_state_machine_restart_and_close_are_fail_closed() {
    let mut machine = SignalingStateMachine::default();
    assert!(machine.remote_answer().is_err());
    machine.local_offer().unwrap();
    assert!(machine.local_offer().is_err());
    machine.remote_answer().unwrap();
    machine.restart().unwrap();
    assert_eq!(machine.state(), SignalingState::Restarting);
    assert_eq!(machine.revision(), 3);
    machine.local_offer().unwrap();
    machine.remote_answer().unwrap();
    machine.close();
    assert_eq!(machine.state(), SignalingState::Closed);
    assert!(matches!(
        machine.restart(),
        Err(SignalingError::InvalidTransition(SignalingState::Closed))
    ));
}
