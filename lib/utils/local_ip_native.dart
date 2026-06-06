import 'dart:io';

Future<String> detectLocalIp() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (!addr.isLoopback &&
            (addr.address.startsWith('192.') ||
                addr.address.startsWith('10.') ||
                addr.address.startsWith('172.'))) {
          return addr.address;
        }
      }
    }
  } catch (_) {}
  return '';
}
