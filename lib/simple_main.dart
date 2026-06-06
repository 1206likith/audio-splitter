import 'package:flutter/material.dart';

void main() {
  runApp(const AudioSplitterApp());
}

class AudioSplitterApp extends StatelessWidget {
  const AudioSplitterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Splitter',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  bool _isHosting = false;
  bool _isConnected = false;
  int _selectedHostSource = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Audio Splitter',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.broadcast_on_home), text: 'Host'),
            Tab(icon: Icon(Icons.headphones), text: 'Client'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildHostScreen(),
          _buildClientScreen(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed:
            _tabController.index == 0 ? _toggleHosting : _toggleConnection,
        icon: Icon(_tabController.index == 0
            ? (_isHosting ? Icons.stop : Icons.play_arrow)
            : (_isConnected ? Icons.link_off : Icons.link)),
        label: Text(_tabController.index == 0
            ? (_isHosting ? 'Stop Hosting' : 'Start Hosting')
            : (_isConnected ? 'Disconnect' : 'Connect')),
      ),
    );
  }

  Widget _buildHostScreen() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isHosting
                            ? Icons.broadcast_on_home
                            : Icons.broadcast_on_home_outlined,
                        color: _isHosting ? Colors.green : Colors.grey,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isHosting ? 'Hosting Active' : 'Not Hosting',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _isHosting ? Colors.green : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isHosting) ...[
                    const Text('Port: 8080'),
                    const Text('Connected Devices: 0'),
                    const Text('Audio Quality: High (256 kbps)'),
                  ] else ...[
                    const Text('Start hosting to allow devices to connect'),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Audio Source',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  RadioGroup<int>(
                    groupValue: _selectedHostSource,
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedHostSource = value;
                      });
                    },
                    child: const Column(
                      children: [
                        ListTile(
                          leading: Icon(Icons.mic),
                          title: Text('Microphone'),
                          subtitle:
                              Text('Capture audio from device microphone'),
                          trailing: Radio<int>(value: 0),
                        ),
                        ListTile(
                          leading: Icon(Icons.music_note),
                          title: Text('Music Player'),
                          subtitle: Text('Stream from music player app'),
                          trailing: Radio<int>(value: 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (_isHosting) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
              ),
              child: const Column(
                children: [
                  Icon(Icons.wifi, color: Colors.green, size: 32),
                  SizedBox(height: 8),
                  Text(
                    'Broadcasting on WiFi Network',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                  Text(
                    'Other devices can now connect to this host',
                    style: TextStyle(color: Colors.green),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildClientScreen() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isConnected ? Icons.link : Icons.link_off,
                        color: _isConnected ? Colors.green : Colors.grey,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isConnected ? 'Connected to Host' : 'Not Connected',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _isConnected ? Colors.green : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isConnected) ...[
                    const Text('Host: Audio Splitter Host'),
                    const Text('Address: 192.168.1.100'),
                    const Text('Latency: 45ms'),
                  ] else ...[
                    const Text('Connect to a host to start receiving audio'),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Audio Playback',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        _isConnected ? Icons.play_circle : Icons.pause_circle,
                        color: _isConnected ? Colors.green : Colors.grey,
                        size: 32,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isConnected
                                  ? 'Receiving Audio'
                                  : 'No Audio Signal',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            if (_isConnected) ...[
                              const Text('Quality: High (256 kbps)'),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.volume_up),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.volume_down),
                      Expanded(
                        child: Slider(
                          value: 0.7,
                          onChanged: (value) {},
                          divisions: 20,
                        ),
                      ),
                      const Icon(Icons.volume_up),
                      const SizedBox(width: 8),
                      const Text('70%'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (!_isConnected) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: const Column(
                children: [
                  Icon(Icons.search, color: Colors.blue, size: 32),
                  SizedBox(height: 8),
                  Text(
                    'Scanning for Audio Hosts',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  Text(
                    'Make sure the host device is on the same network',
                    style: TextStyle(color: Colors.blue),
                  ),
                ],
              ),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
              ),
              child: const Column(
                children: [
                  Icon(Icons.headphones, color: Colors.green, size: 32),
                  SizedBox(height: 8),
                  Text(
                    'Receiving Synchronized Audio',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                  Text(
                    'Perfect sync with other connected devices',
                    style: TextStyle(color: Colors.green),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _toggleHosting() {
    setState(() {
      _isHosting = !_isHosting;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            _isHosting ? 'Started hosting on port 8080' : 'Stopped hosting'),
        backgroundColor: _isHosting ? Colors.green : Colors.grey,
      ),
    );
  }

  void _toggleConnection() {
    if (_isConnected) {
      setState(() {
        _isConnected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Disconnected from host'),
          backgroundColor: Colors.grey,
        ),
      );
    } else {
      _showConnectDialog();
    }
  }

  void _showConnectDialog() {
    final TextEditingController addressController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to Host'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                labelText: 'Host IP Address',
                hintText: '192.168.1.100',
                prefixIcon: Icon(Icons.computer),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter the IP address of the host device you want to connect to.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _isConnected = true;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Connected to host successfully'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}
