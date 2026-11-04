import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// A photo of a paper document: bytes and content type, or null if the person cancelled.
typedef PhotoTaker = Future<(Uint8List, String)?> Function();

/// Opens the camera. Shrunk on the device (about 200–400 KB) so it travels fast over the co-op Wi-Fi.
/// Tests replace this with a fake.
PhotoTaker takeInvoicePhoto = () async {
  final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 70);
  if (x == null) return null;
  return (await x.readAsBytes(), 'image/jpeg');
};
