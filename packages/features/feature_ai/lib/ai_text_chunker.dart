// AI Chat 使用的上下文分块公共出口。
//
// 它与 feature_rag 的 RagChunk 是不同边界的模型：AI 只接收已整理的上下文，
// 不直接依赖 RAG Feature 的存储和检索实现。
library;

export 'src/chat/text_chunker.dart';
