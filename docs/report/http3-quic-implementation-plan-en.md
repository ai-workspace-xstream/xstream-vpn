# Fix HTTP/3 (QUIC) Tunnel Mode Connection Issues

## Server Validation Results (tky-proxy.svc.plus)
I successfully connected to the online server and analyzed its Xray configuration:

- **Server Version**: Xray 26.3.27
- **Transport**: xhttp (Not tcp + vision).
- **Analysis**: Because the server uses `xhttp`, the `flow` configuration (`xtls-rprx-vision-udp443`) is irrelevant. The `xhttp` transport multiplexes traffic over an outer HTTP/3 or HTTP/2 connection. When the Xray client forwards UDP 443 (QUIC) over `xhttp`, it creates a "QUIC-in-QUIC" encapsulation. This severely breaks MTU limits and causes fragmentation, which frequently crashes the underlying multiplexed proxy connection. When the proxy connection collapses, all concurrent HTTP/2 TCP streams are abruptly reset, causing Chrome to display `ERR_CONNECTION_CLOSED`.

## OneXray Mechanism Comparison (Reference)
OneXray treats UDP 443 / QUIC as a first-class citizen, providing three levers:

1. **Flow Variant**: `VLESSFlow.xtlsRprxVisionUdp443` (`xtls-rprx-vision-udp443` is identical to vision but does not intercept UDP 443, letting QUIC pass through the tunnel).
2. **Mux XUDP Control**: `xudpProxyUDP443` under Mux config (takes `reject` / `allow` / `skip`) to control how XUDP handles UDP 443.
3. **Routing Protocol Matching**: Matches `RoutingRuleProtocol.quic` + `RoutingRuleNetwork.{udp, tcp, udp}` to write specific rules for QUIC.

### Key Constraints for XStream
In Xray-core, XTLS Vision and Mux are mutually exclusive. Therefore:
- For existing Vision deployments in XStream, the only usable lever is the flow suffix `-udp443`.
- `xudpProxyUDP443` only takes effect in non-Vision (Mux/XUDP) outbound modes.
- These represent different outbound configurations and cannot be simply combined.

## The Root Cause in the Client Code
While the previous agent implemented the `blockQuic` routing rule (Plan A) in `VpnConfig.generateContent`, these configurations are statically generated when a node is added/imported. Currently, `native_bridge.dart` dynamically updates the inbounds (to enable TUN) right before launching Xray, but fails to update the `routing` and `dns` sections. Because the block routing rule is never dynamically injected at connection time, QUIC traffic escapes to the `xhttp` proxy server, causing the crash described above.

## Proposed Changes

### 1. `lib/services/vpn_config_service.dart`
- Make `_buildSecureDnsRoutingConfig` public as `buildSecureDnsRoutingConfig`.
- Make `_buildSecureDnsConfig` public as `buildSecureDnsConfig`.
- Expose a helper to dynamically update the `flow` for `xtls-rprx-vision` outbounds (for nodes that actually use TCP) based on `GlobalState.http3Passthrough.value`.

### 2. `lib/utils/native_bridge.dart`
In `_prepareXrayConfig` (where `config.json` is modified just before Xray starts):
- **Update DNS**: `sourceJson['dns'] = VpnConfig.buildSecureDnsConfig();`
- **Update Routing**: `sourceJson['routing'] = VpnConfig.buildSecureDnsRoutingConfig(sourceJson['routing'], enableTunnelMode: isTunMode);`
- **Update Outbound Flow**: Dynamically adjust the `flow` field in the proxy outbound to match `DnsConfig.normalizeVisionFlow(...)` if the outbound supports it.
- This ensures that whenever the user clicks "Connect", the latest DNS, QUIC blocking, and Flow settings are perfectly synchronized with the active UI state.

### 3. `lib/services/dns/dns_control_plane.dart`
- Ensure the UDP 443 block rule is robust and correctly inserted before proxy rules. (Already correct, just requires the dynamic injection from `native_bridge.dart`).

## Verification Plan
- Connect to `tky-proxy.svc.plus` in Tunnel mode.
- Verify `node-tky-proxy-svc-plus-config.json` receives the block routing rule automatically at connection time.
- Access `https://doodles.google` and `https://www.youtube.com`. Chrome will receive an ICMP Unreachable for the UDP socket, gracefully fall back to HTTP/2 over the `xhttp` proxy, and load without `ERR_CONNECTION_CLOSED`.
