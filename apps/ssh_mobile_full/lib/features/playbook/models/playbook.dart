// 旧 Playbook 模型路径的兼容出口。
//
// 生产代码使用 feature_playbook 的公共入口；保留该路径是为了让旧 AI、备份
// 和外部调用方在迁移期间继续编译，避免把重构误当成删除功能。
export 'package:feature_playbook/feature_playbook.dart'
    show Playbook, PlaybookStep, StepStatus;
