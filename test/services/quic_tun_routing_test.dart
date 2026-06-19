import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xstream/services/dns/dns_control_plane.dart';
import 'package:xstream/services/vpn_config_service.dart';
import 'package:xstream/utils/global_config.dart';

const _visionUri =
    'vless://11111111-1111-1111-1111-111111111111@example.com:443'
    '?type=tcp&security=tls&flow=xtls-rprx-vision#example';
const _udp443Uri =
    'vless://11111111-1111-1111-1111-111111111111@example.com:443'
    '?type=tcp&security=tls&flow=xtls-rprx-vision-udp443#example';

Map<String, dynamic> _decode(String value) =>
    jsonDecode(value) as Map<String, dynamic>;

List<Map<String, dynamic>> _routingRules(Map<String, dynamic> config) {
  final routing = config['routing'] as Map;
  return (routing['rules'] as List<dynamic>)
      .map((value) => Map<String, dynamic>.from(value as Map))
      .toList();
}

bool _isQuicBlock(Map<String, dynamic> rule) =>
    rule['type'] == 'field' &&
    rule['network'] == 'udp' &&
    rule['port'] == '443' &&
    rule['outboundTag'] == 'block';

const _routePolicy = RoutePolicy(
  domainSets: DomainSets(
    direct: <String>[],
    proxy: <String>[],
    fake: <String>[],
    directIpCidrs: <String>[],
  ),
  tunnelDnsServers4: <String>[],
  tunnelDnsServers6: <String>[],
  captureSystemDnsToBuiltInDns: false,
  forceTunnelDnsToProxy: false,
);

List<Map<String, dynamic>> _secureRules(
  bool enableTunnelMode, {
  bool blockQuic = true,
}) =>
    _routePolicy.buildSecureDnsRules(
      enableTunnelMode: enableTunnelMode,
      blockQuic: blockQuic,
      tunInboundTag: 'tun-in',
      directResolverInboundTags: const <String>['dns-direct'],
      proxyResolverInboundTags: const <String>['dns-proxy'],
      fakeDnsEnabled: false,
    );

String? _proxyFlow(Map<String, dynamic> config) {
  final proxy = (config['outbounds'] as List<dynamic>)
      .cast<Map>()
      .firstWhere((value) => value['tag'] == 'proxy');
  final vnext = (proxy['settings'] as Map)['vnext'] as List<dynamic>;
  final users = (vnext.first as Map)['users'] as List<dynamic>;
  return (users.first as Map)['flow'] as String?;
}

void main() {
  group('TUN QUIC fallback routing', () {
    setUp(() {
      GlobalState.http3Passthrough.value = false;
    });

    test('adds UDP 443 block before proxy rules in TUN mode', () {
      final rules = _secureRules(true);

      final blockIndex = rules.indexWhere(_isQuicBlock);
      final proxyIndex = rules.indexWhere(
        (rule) => rule['outboundTag'] == 'proxy',
      );
      expect(blockIndex, greaterThanOrEqualTo(0));
      expect(blockIndex, lessThan(proxyIndex));
      expect(rules[blockIndex]['inboundTag'], <String>['tun-in']);
    });

    test('omits UDP 443 block outside TUN mode', () {
      expect(_secureRules(false).where(_isQuicBlock), isEmpty);
    });

    test('omits UDP 443 block when passthrough is enabled', () {
      expect(
        _secureRules(true, blockQuic: false).where(_isQuicBlock),
        isEmpty,
      );
    });

    test('keeps base Vision flow while blocking QUIC in TUN mode', () async {
      final text = await VpnConfig.tryGenerateXrayJsonFromVlessUri(_visionUri);
      expect(text, isNotNull);
      final config = _decode(text!);
      expect(_routingRules(config).where(_isQuicBlock), hasLength(1));
      expect(_proxyFlow(config), 'xtls-rprx-vision');
    });

    test('upgrades base Vision flow to udp443 when passthrough is enabled',
        () async {
      GlobalState.http3Passthrough.value = true;
      final text = await VpnConfig.tryGenerateXrayJsonFromVlessUri(_visionUri);
      expect(text, isNotNull);
      final config = _decode(text!);
      expect(_proxyFlow(config), 'xtls-rprx-vision-udp443');
      expect(_routingRules(config).where(_isQuicBlock), isEmpty);
    });

    test('keeps explicit udp443 flow when passthrough is enabled', () async {
      GlobalState.http3Passthrough.value = true;
      final text = await VpnConfig.tryGenerateXrayJsonFromVlessUri(_udp443Uri);
      expect(text, isNotNull);
      expect(_proxyFlow(_decode(text!)), 'xtls-rprx-vision-udp443');
    });

    test('downgrades explicit udp443 flow when passthrough is disabled',
        () async {
      final text = await VpnConfig.tryGenerateXrayJsonFromVlessUri(_udp443Uri);
      expect(text, isNotNull);
      expect(_proxyFlow(_decode(text!)), 'xtls-rprx-vision');
    });
  });
}
