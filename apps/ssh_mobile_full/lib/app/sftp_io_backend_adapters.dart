// App Shell IO-only SFTP backend entry used by native cache/protocol tests.
//
// The Feature package owns SFTP UI and application state. This entry exposes
// only the still-shared native backend implementation to App Shell tests.

export '../services/sftp/sftp_service_io.dart';
