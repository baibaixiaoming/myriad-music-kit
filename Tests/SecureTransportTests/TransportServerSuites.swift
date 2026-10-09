import Testing

/// 起服务器的几组测试会改共享的静态设置（登录失败上限、握手时限、单来源上限等），
/// 放在同一个父组里一个一个跑，免得互相影响。
/// 每项测试最多 2 分钟：万一卡住记为失败，不拖住整个测试进程。
@Suite(.serialized, .timeLimit(.minutes(2))) enum TransportServerSuites {}
