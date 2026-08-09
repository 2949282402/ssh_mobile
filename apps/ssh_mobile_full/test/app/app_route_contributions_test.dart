/// 验证 App Shell 聚合的 Feature 路由元数据完整且没有重复名称。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/app/navigation/app_route_contributions.dart';

void main() {
  test('aggregates unique public Feature route contributions', () {
    final names = AppRouteContributionCatalog.all
        .map((contribution) => contribution.routeName)
        .toList();

    expect(names, isNotEmpty);
    expect(names.toSet(), hasLength(names.length));
    expect(AppRouteContributionCatalog.contains('/terminal'), isTrue);
    expect(AppRouteContributionCatalog.contains('/mcp-console'), isTrue);
    expect(AppRouteContributionCatalog.contains('/unknown'), isFalse);
  });
}
