// Pure Dart WebShare route boundary.
//
// This entrypoint intentionally exports no Flutter services or widgets so an
// ordinary Dart VM process can bind a real TLS listener and exercise the
// production route handler.

export 'src/services/lan_share/lan_web_share_request_handler.dart';
