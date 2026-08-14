import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';

// Paste your exact Awin Create-a-Feed URL here
const String awinFeedUrl = 'https://productdata.awin.com/datafeed/download/apikey/09d40570b9ac3b418229e8a6faeda0fa/language/en/fid/98921,102758,103024/rid/0/hasEnhancedFeeds/0/columns/product_name,aw_deep_link,search_price,aw_product_id,merchant_name,merchant_product_id,merchant_image_url,description,merchant_category/format/csv/delimiter/%2C/compression/gzip/adultcontent/1/';

void main() async {
  print('Fetching Awin affiliate data feed...');
  
  final response = await http.get(Uri.parse(awinFeedUrl));
  if (response.statusCode != 200) {
    print('Failed to download feed. HTTP Status: ${response.statusCode}');
    return;
  }

  print('Download complete. Decompressing and parsing CSV...');
  
  String csvData;
  try {
    final decompressedBytes = gzip.decode(response.bodyBytes);
    csvData = utf8.decode(decompressedBytes);
  } catch (e) {
    csvData = response.body;
  }

  final List<List<dynamic>> rows = csv.decode(csvData);
  
  if (rows.isEmpty) {
    print('The CSV is empty.');
    return;
  }

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

  for (int i = 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.length <= linkIndex) continue;
    
    final String rawName = row[nameIndex].toString();
    final String rawPrice = row[priceIndex].toString();
    final String affiliateUrl = row[linkIndex].toString();
    final String merchantName = merchantIndex != -1 ? row[merchantIndex].toString() : 'Unknown Dealer';

    String? internalId = mapToInternalId(rawName);
    
    if (internalId != null) {
      double price = double.tryParse(rawPrice.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
      if (price <= 0) continue;

      // SANITY CHECKS BY CATEGORY (Evaluated here in main where price exists)
      if (internalId.startsWith('gold_') && (price < 30 || price > 6000)) continue;
      if (internalId.startsWith('silver_') && (price < 2 || price > 5000)) continue;
      if (internalId == 'morgan_dollar' && (price < 25 || price > 1000)) continue;
      if (internalId == 'peace_dollar' && (price < 25 || price > 1000)) continue;
      if (internalId == 'junk_silver' && (price < 10 || price > 2500)) continue;
      
      // Granular Goldback Sanity Bounds (1/4 up to 100)
      if (internalId.startsWith('goldback_')) {
        if (internalId == 'goldback_quarter' && (price < 0.5 || price > 10)) continue;
        if (internalId == 'goldback_half' && (price < 1 || price > 15)) continue;
        if (internalId == 'goldback_1' && (price < 2 || price > 25)) continue;
        if (internalId == 'goldback_2' && (price < 4 || price > 50)) continue;
        if (internalId == 'goldback_5' && (price < 10 || price > 120)) continue;
        if (internalId == 'goldback_10' && (price < 20 || price > 250)) continue;
        if (internalId == 'goldback_25' && (price < 50 || price > 600)) continue;
        if (internalId == 'goldback_50' && (price < 100 || price > 1200)) continue;
        if (internalId == 'goldback_100' && (price < 200 || price > 2500)) continue;
      }

      normalizedPrices.add({
        'item_id': internalId,
        'dealer': merchantName,
        'price': price,
        'url': affiliateUrl,
      });
    }
  }

  final file = File('prices.json');
  await file.writeAsString(jsonEncode(normalizedPrices));
  
  print('Success! Mapped ${normalizedPrices.length} clean items to prices.json');
}

// ==========================================
// THE COMPREHENSIVE NORMALIZATION DICTIONARY
// ==========================================
String? mapToInternalId(String rawName) {
  final name = rawName.toLowerCase();

  // EXCLUDE non-coin accessories immediately
  if (name.contains('empty tube') || 
      name.contains('plastic capsule') || 
      name.contains('display box') || 
      name.contains('bezel') ||
      name.contains('air-tite') ||
      name.contains('slab holder')) {
    return null;
  }

  // 1. GOLDBACKS (Parsed by Denomination)
  if (name.contains('goldback')) {
    if (name.contains('100')) return 'goldback_100';
    if (name.contains('50')) return 'goldback_50';
    if (name.contains('25')) return 'goldback_25';
    if (name.contains('10')) return 'goldback_10';
    if (name.contains('5')) return 'goldback_5';
    if (name.contains('2')) return 'goldback_2';
    if (name.contains('1/2') || name.contains('half')) return 'goldback_half';
    if (name.contains('1/4') || name.contains('quarter')) return 'goldback_quarter';
    if (name.contains('1')) return 'goldback_1';
    return 'goldback_1'; 
  }

  // 2. MORGAN & PEACE DOLLARS
  if (name.contains('morgan') && name.contains('dollar')) {
    return 'morgan_dollar';
  }
  if (name.contains('peace') && name.contains('dollar')) {
    return 'peace_dollar';
  }

  // 3. 90% JUNK SILVER
  if (name.contains('90%') || 
      name.contains('junk silver') || 
      name.contains('constitutional') || 
      name.contains('walking liberty') || 
      name.contains('benjamin franklin') || 
      name.contains('barber') || 
      name.contains('mercury dime') || 
      name.contains('roosevelt dime') || 
      name.contains('washington quarter')) {
    return 'junk_silver';
  }

  // 4. GOLD
  if (name.contains('gold')) {
    if (name.contains('1/10') || name.contains('0.1 oz')) return 'gold_fractional_1_10oz';
    if (name.contains('1/4') || name.contains('0.25 oz')) return 'gold_fractional_1_4oz';
    if (name.contains('1/2') || name.contains('0.5 oz')) return 'gold_fractional_1_2oz';
    if (name.contains('1 oz') || name.contains('1 ounce')) return 'gold_1oz';
    return 'gold_other';
  }

  // 5. SILVER
  if (name.contains('silver')) {
    if (name.contains('1/2 oz') || name.contains('half oz')) return 'silver_fractional_1_2oz';
    if (name.contains('1 oz') || name.contains('1 ounce')) return 'silver_1oz';
    if (name.contains('5 oz') || name.contains('10 oz') || name.contains('100 oz') || name.contains(' kilo')) return 'silver_bar_bulk';
    return 'silver_other';
  }

  return null; 
}