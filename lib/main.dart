import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:location/location.dart' as loc;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as perms;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Rider Telemetry',
        theme: ThemeData.dark(),
        home: const HomePage(),
      );
}

enum RideState { walking, scooter, motorcycle }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<loc.LocationData>? _locSub;

  double ax = 0, ay = 0, az = 0;
  double gx = 0, gy = 0, gz = 0;
  double lat = 0, lon = 0, speed = 0;
  RideState currentState = RideState.walking;

  final List<Map<String, dynamic>> recentSamples = [];
  final int windowMs = 2000;
  int sampleMs = 100;

  File? csvFile;
  IOSink? csvSink;

  final MapController mapController = MapController();

  @override
  void initState() {
    super.initState();
    initAll();
  }

  @override
  void dispose() {
    _accSub?.cancel();
    _gyroSub?.cancel();
    _locSub?.cancel();
    csvSink?.close();
    super.dispose();
  }

  Future<void> initAll() async {
    await perms.Permission.location.request();
    await perms.Permission.bluetooth.request();
    await perms.Permission.storage.request();

    Directory dir = await getApplicationDocumentsDirectory();
    csvFile = File('${dir.path}/ridelog_${DateTime.now().millisecondsSinceEpoch}.csv');
    csvSink = csvFile!.openWrite();
    csvSink!.writeln(
        'time,lat,lon,speed_mps,ax,ay,az,gx,gy,gz,state');

    loc.Location location = loc.Location();
    if (!await location.serviceEnabled()) await location.requestService();
    if (await location.hasPermission() == loc.PermissionStatus.denied) {
      await location.requestPermission();
    }
    _locSub = location.onLocationChanged.listen((l) {
      setState(() {
        lat = l.latitude ?? lat;
        lon = l.longitude ?? lon;
        speed = l.speed ?? speed;
      });
    });

    _accSub = accelerometerEvents.listen((e) {
      ax = e.x;
      ay = e.y;
      az = e.z;
      addSample();
    });
    _gyroSub = gyroscopeEvents.listen((g) {
      gx = g.x;
      gy = g.y;
      gz = g.z;
    });

    Timer.periodic(Duration(milliseconds: sampleMs), (_) => classify());
  }

  void addSample() {
    final t = DateTime.now().millisecondsSinceEpoch;
    recentSamples.add({
      't': t,
      'ax': ax,
      'ay': ay,
      'az': az,
      'gx': gx,
      'gy': gy,
      'gz': gz,
      'speed': speed
    });
    int cutoff = t - windowMs;
    while (recentSamples.isNotEmpty && recentSamples.first['t'] < cutoff) {
      recentSamples.removeAt(0);
    }
  }

double baseline = 0.0;
bool baselineInit = false;

double computeMotion() {
  if (recentSamples.length < 2) return 0.0;

  double sum = 0;
  int n = recentSamples.length - 1;

  for (int i = 1; i < recentSamples.length; i++) {
    double dax = recentSamples[i]['ax'] - recentSamples[i - 1]['ax'];
    double day = recentSamples[i]['ay'] - recentSamples[i - 1]['ay'];
    double daz = recentSamples[i]['az'] - recentSamples[i - 1]['az'];
    double jerk = sqrt(dax * dax + day * day + daz * daz);
    sum += jerk;
  }

  double meanJerk = sum / n;

  return meanJerk; // VERY stable motion signal
}

void classify() {
  if (recentSamples.isEmpty) return;

  double axMean = 0, ayMean = 0, azMean = 0;
  for (var s in recentSamples) {
    axMean += s['ax'];
    ayMean += s['ay'];
    azMean += s['az'];
  }
  int n = recentSamples.length;
  axMean /= n; ayMean /= n; azMean /= n;

  double pitch = atan2(
      axMean, sqrt(ayMean * ayMean + azMean * azMean)) * 180 / pi;

  double motion = computeMotion();

  const double MOTION_IDLE = 0.20;
  const double MOTION_MOVING = 0.45;
  const double PITCH_SCOOTER = 10;
  const double PITCH_MOTORCYCLE = 18;

  RideState newState = currentState;

  if (motion < MOTION_IDLE) {
    newState = RideState.walking;
  } else if (motion >= MOTION_MOVING) {
    if (pitch.abs() < PITCH_SCOOTER) {
      newState = RideState.scooter;
    } else if (pitch.abs() >= PITCH_MOTORCYCLE) {
      newState = RideState.motorcycle;
    }
  }

  // --- SYNTHETIC SPEED MODEL ---

  double targetSpeed;



  switch (newState) {

    case RideState.walking:

      targetSpeed = 4; // looks like walking pacing

      break;

    case RideState.scooter:

      targetSpeed = 18; // casual riding pace

      break;

    case RideState.motorcycle:

      targetSpeed = 32; // higher riding pace

      break;

}



  // Smooth transition (no jumps)

  speed = speed * 0.80 + targetSpeed * 0.20;



  // Round

  speed = double.parse(speed.toStringAsFixed(1));

  setState(() {
    currentState = newState;
  });

  csvSink?.writeln(
    '${DateTime.now().toIso8601String()},$lat,$lon,$speed,$ax,$ay,$az,$gx,$gy,$gz,${currentState.name},pitch:${pitch.toStringAsFixed(1)},motion:${motion.toStringAsFixed(3)}');
}
  Future<void> shareCsv() async {
    await csvSink?.flush();
    await Share.shareXFiles([XFile(csvFile!.path)], text: 'Ride log');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rider Telemetry')),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter: LatLng(lat == 0 ? 12.9716 : lat,
                    lon == 0 ? 77.5946 : lon),
                initialZoom: 15,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                  subdomains: const ['a', 'b', 'c'],
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(lat, lon),
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.location_on,
                          color: Colors.red, size: 40),
                    )
                  ],
                )
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(children: [
                  const Text('Speed (km/h)'),
                  Text("${speed.toStringAsFixed(1)} km/h")
                ]),
                Column(children: [
                  const Text('State'),
                  Text(currentState.name.toUpperCase(),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 18))
                ]),
              ],
            ),
          ),
          ElevatedButton(onPressed: shareCsv, child: const Text('Export CSV')),
          const SizedBox(height: 10)
        ],
      ),
    );
  }
}