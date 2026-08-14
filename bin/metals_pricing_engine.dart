import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';

// 1. Paste your exact Awin Create-a-Feed URL here
const String awinFeedUrl = 'https://productdata.awin.com/datafeed/download/apikey/09d40570b9ac3b418229e8a6faeda0fa/language/en/fid/98921,102758,103024/rid/0/hasEnhancedFeeds/0/columns/product_name,aw_deep_link,search_price,aw_product_id,merchant_name,merchant_product_id,merchant_image_url,description,merchant_category/format/csv/delimiter/%2C/compression/gzip/adultcontent/1/';

void main() async {
  print('Fetching Awin affiliate data feed...');
  
  final response = await http.get(Uri.parse(awinFeedUrl));
  if (response.statusCode != 200) {
    print('Failed to download feed. HTTP Status: ${response.statusCode}');
    return;
  }

  print('Download complete. Decompressing and parsing CSV...');
  
  // Unpack the gzip binary stream into a readable UTF-8 string
  String csvData;
  try {
    final decompressedBytes = gzip.decode(response.bodyBytes);
    csvData = utf8.decode(decompressedBytes);
  } catch (e) {
    csvData = response.body;
  }

  // Parse CSV using the version 8+ API
  final List<List<dynamic>> rows = csv.decode(csvData);
  
  if (rows.isEmpty) {
    print('The CSV is empty.');
    return;
  }

  // Find the column indexes dynamically matching Awin's exact snake_case headers
  final headerRow = rows[0].map((e) => e.toString().toLowerCase().trim()).toList();
  
  final nameIndex = headerRow.indexWhere((h) => h == 'product_name' || h.contains('product name') || h.contains('title'));
  final priceIndex = headerRow.indexWhere((h) => (h == 'search_price' || h.contains('price')) && !h.contains('currency'));
  final linkIndex = headerRow.indexWhere((h) => h == 'aw_deep_link' || h.contains('deep_link' ) || h.contains('url') || h.contains('link'));
  final merchantIndex = headerRow.indexWhere((h) => h == 'merchant_name' || h.contains('merchant') || h.contains('advertiser'));

  if (nameIndex == -1 || priceIndex == -1 || linkIndex == -1) {
    print('Could not find required columns in header: $headerRow');
    return;
  }

  List<Map<String, dynamic>> normalizedPrices = [];

  // Loop through the items (skipping the header)
  for (int i = 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.length <= linkIndex) continue; // Skip malformed rows
    
    final String rawName = row[nameIndex].toString();
    final String rawPrice = row[priceIndex].toString();
    final String affiliateUrl = row[linkIndex].toString();
    final String merchantName = merchantIndex != -1 ? row[merchantIndex].toString() : 'Unknown Dealer';

    // Try to map this messy product name to a clean internal ID
    String? internalId = mapToInternalId(rawName);
    
    if (internalId != null) {
      double price = double.tryParse(rawPrice.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;

      // UPDATED SANITY CHECK: Realistic market price boundaries for single units
      if (internalId == 'silver_eagle_1oz' && (price < 30 || price > 150)) continue;
      if (internalId == 'gold_maple_1oz' && (price < 2000 || price > 6000)) continue;
      if (internalId == 'silver_bar_10oz' && (price < 400 || price > 1200)) continue;

      normalizedPrices.add({
        'item_id': internalId,
        'dealer': merchantName,
        'price': price,
        'url': affiliateUrl,
      });
    }
  }

  // Save to JSON
  final file = File('prices.json');
  await file.writeAsString(jsonEncode(normalizedPrices));
  
  print('Success! Mapped ${normalizedPrices.length} clean benchmark items to prices.json');
}

// ==========================================
// THE NORMALIZATION DICTIONARY
// ==========================================
String? mapToInternalId(String rawName) {
  final name = rawName.toLowerCase();

  // EXCLUDE non-coin/bar accessories immediately
  if (name.contains('tube') || 
      name.contains('capsule') || 
      name.contains('holder') || 
      name.contains('empty') || 
      name.contains('roll') ||
      name.contains('box') ||
      name.contains('bezel')) {
    return null;
  }

  // Silver Eagles
  if (name.contains('silver eagle') && name.contains('1 oz')) {
    return 'silver_eagle_1oz';
  }
  
  // Gold Maples
  if (name.contains('gold maple') && name.contains('1 oz')) {
    return 'gold_maple_1oz';
  }
  
  // 10 oz Silver Bars
  if (name.contains('silver bar') && name.contains('10 oz')) {
    return 'silver_bar_10oz';
  }

  return null; 
}