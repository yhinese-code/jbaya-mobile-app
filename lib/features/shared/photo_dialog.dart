import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';

/// Loads an evidence photo from an authenticated endpoint ({mime, base64}) and shows it full size.
Future<void> showEvidencePhoto(BuildContext context, String apiPath, {String title = 'الصورة'}) {
  return showDialog(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 800),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
            ),
            Flexible(
              child: FutureBuilder<dynamic>(
                future: ApiClient.instance.get(apiPath),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: NoticeBanner(tone: Tone.bad, title: 'تعذر تحميل الصورة', message: snap.error.toString()),
                    );
                  }
                  final bytes = base64Decode((snap.data as Map)['base64'] as String);
                  return InteractiveViewer(maxScale: 5, child: Image.memory(bytes, fit: BoxFit.contain));
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
