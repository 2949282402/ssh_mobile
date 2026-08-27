// 遥测数据库的跨平台连接工厂出口。
//
// 数据库声明只依赖 Drift 核心；平台文件负责选择 Native、Web 或不可用
// 平台的实际执行器，避免在共享库中直接导入 dart:io。

export 'telemetry_database_connection_stub.dart'
    if (dart.library.io) 'telemetry_database_connection_io.dart'
    if (dart.library.html) 'telemetry_database_connection_web.dart';
