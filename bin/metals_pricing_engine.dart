import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';

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
    // allowMalformed prevents the script from crashing if an affiliate sends weird characters
    csvData = utf8.decode(decompressedBytes, allowMalformed: true); 
  } catch (e) {
    csvData = response.body;
  }

  // --- FIX 1: Removed 'const' because newer csv packages don't support it ---
  final List<List<dynamic>> rows = CsvToListConverter().convert(csvData);
  
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

      // --- FIX 2: Modern Sanity Checks (Updated for 2026 Gold/Silver Highs) ---
      if (internalId.startsWith('gold_')) {
        if (internalId.contains('fractional') && (price < 300 || price > 3500)) continue;
        if (internalId == 'gold_1oz' && (price < 4000 || price > 6500)) continue; 
      }
      if (internalId.startsWith('silver_') && (price < 55 || price > 5000)) continue;
      if (internalId.startsWith('platinum_') && (price < 1500 || price > 3500)) continue;
      if (internalId.startsWith('palladium_') && (price < 1100 || price > 3000)) continue;
      if (internalId == 'copper_1oz' && (price < 1 || price > 20)) continue;
      if (internalId == 'morgan_dollar' && (price < 50 || price > 1500)) continue;
      if (internalId == 'peace_dollar' && (price < 50 || price > 1500)) continue;
      if (internalId == 'junk_silver' && (price < 40 || price > 3000)) continue;
      
      // Granular Goldback Bounds
      if (internalId.startsWith('goldback_')) {
        if (internalId == 'goldback_quarter' && (price < 0.5 || price > 15)) continue;
        if (internalId == 'goldback_half' && (price < 1 || price > 20)) continue;
        if (internalId == 'goldback_1' && (price < 2 || price > 30)) continue;
        if (internalId == 'goldback_2' && (price < 4 || price > 60)) continue;
        if (internalId == 'goldback_5' && (price < 10 || price > 150)) continue;
        if (internalId == 'goldback_10' && (price < 20 || price > 300)) continue;
        if (internalId == 'goldback_25' && (price < 50 || price > 700)) continue;
        if (internalId == 'goldback_50' && (price < 100 || price > 1400)) continue;
        if (internalId == 'goldback_100' && (price < 200 || price > 3000)) continue;
      }

      normalizedPrices.add({
        'item_id': internalId,
        'dealer': merchantName,
        'price': price,
        'url': affiliateUrl,
      });
    }
  }

  // CURATE & CAP: Group by item_id and keep only the single lowest price deal per item
  Map<String, List<Map<String, dynamic>>> grouped = {};
  for (var item in normalizedPrices) {
    String id = item['item_id'] as String;
    grouped.putIfAbsent(id, () => []).add(item);
  }

  List<Map<String, dynamic>> curatedPrices = [];
  grouped.forEach((itemId, items) {
    items.sort((a, b) => (a['price'] as double).compareTo(b['price'] as double));
    curatedPrices.addAll(items.take(1)); // Restrict to the single lowest price option
  });

  final file = File('prices.json');
  await file.writeAsString(jsonEncode(curatedPrices));
  
  print('Success! Curated ${curatedPrices.length} lowest-price leader items to prices.json');
}

// ==========================================
// MASTER CATALOG NORMALIZATION DICTIONARY
// ==========================================
String? mapToInternalId(String rawName) {
  final name = rawName.toLowerCase();

  // EXCLUDE non-coin accessories, books, copper items, and low-grade culls immediately
  if (name.contains('empty tube') || 
      name.contains('plastic capsule') || 
      name.contains('display box') || 
      name.contains('bezel') ||
      name.contains('air-tite') ||
      name.contains('slab holder') ||
      name.contains('manifesto') ||
      name.contains('copper bar') ||
      name.contains('copper round') ||
      name.contains('cull') ||
      name.contains('slick') ||
      name.contains('damaged') ||
      name.contains('cleaned') ||
      name.contains('holed')) {
    return null;
  }

  // 1. GOLDBACKS
  if (name.contains('goldback')) {
    if (name.contains('100')) return 'goldback_100';
    if (name.contains('50')) return 'goldback_50';
    if (name.contains('25')) return 'goldback_25';
    if (name.contains('10')) return 'goldback_10';
    if (name.contains('5')) return 'goldback_5';
    if (name.contains('2')) return 'goldback_2';
    if (name.contains('1/2') || name.contains('half')) return 'goldback_half';
    if (name.contains('1/4') || name.contains('quarter')) return 'goldback_quarter';
    return 'goldback_1'; 
  }

  // 2. SPECIFIC DOLLARS
  if (name.contains('morgan')) {
    if (name.contains('dollar') || name.contains('coin') || name.contains('18') || name.contains('19') || name.contains('circulated') || name.contains('au') || name.contains('vf') || name.contains('ms')) {
      if (!name.contains('copper') && !name.contains('round')) {
        return 'morgan_dollar';
      }
    }
  }
  if (name.contains('peace')) {
    if (name.contains('dollar') || name.contains('coin') || name.contains('19') || name.contains('circulated')) {
      return 'peace_dollar';
    }
  }

  // 3. 90%, 40%, & 35% JUNK SILVER
  if (name.contains('90%') || 
      name.contains('40%') || 
      name.contains('35%') || 
      name.contains('junk') || 
      name.contains('constitutional') || 
      name.contains('walking liberty') || 
      name.contains('franklin') || 
      name.contains('barber') || 
      name.contains('mercury') || 
      name.contains('roosevelt') || 
      name.contains('washington') ||
      name.contains('war nickel') ||
      name.contains('face value')) {
    return 'junk_silver';
  }

  // 4. PLATINUM & PALLADIUM
  if (name.contains('platinum')) {
    if (name.contains('1 oz') || name.contains('1 ounce') || name.contains('eagle') || name.contains('maple')) return 'platinum_1oz';
    return 'platinum_other';
  }
  if (name.contains('palladium')) {
    if (name.contains('1 oz') || name.contains('1 ounce')) return 'palladium_1oz';
    return 'palladium_other';
  }

  // 5. COPPER
  if (name.contains('copper')) {
    return 'copper_1oz';
  }

  // 6. GOLD (Includes Pre-1933 and Bullion)
  if (name.contains('gold')) {
    
    // --- FIX 3: Intercept foreign/historical gold so they don't trigger "eagle" or "1 oz" logic ---
    if (name.contains('peso') || 
        name.contains('franc') || 
        name.contains('ducat') || 
        name.contains('corona') || 
        name.contains('sovereign') ||
        name.contains('gram') ||
        name.contains('pamp')) {
      return 'gold_other';
    }

    if (name.contains('double eagle') || name.contains(r'$20') || name.contains('pre-1933')) return 'gold_1oz';
    if (name.contains('1/10') || name.contains('0.1')) return 'gold_fractional_1_10oz';
    if (name.contains('1/4') || name.contains('0.25')) return 'gold_fractional_1_4oz';
    if (name.contains('1/2') || name.contains('0.5')) return 'gold_fractional_1_2oz';
    if (name.contains('1 oz') || name.contains('1 ounce') || name.contains('buffalo') || name.contains('maple') || name.contains('eagle')) return 'gold_1oz';
    return 'gold_other';
  }

  // 7. SILVER (Includes World Silver & Bullion)
  if (name.contains('silver')) {

    // --- FIX 4: Intercept silver pesos/grams so they don't trigger "eagle" or "1 oz" logic ---
    if (name.contains('peso') || name.contains('franc') || name.contains('gram')) {
      return 'silver_other';
    }

    if (name.contains('eagle')) return 'silver_eagle_1oz';
    if (name.contains('1/2') || name.contains('half')) return 'silver_fractional_1_2oz';
    if (name.contains('5 oz') || name.contains('10 oz') || name.contains('100 oz') || name.contains('kilo') || name.contains('kg')) return 'silver_bar_bulk';
    if (name.contains('1 oz') || name.contains('1 ounce') || name.contains('maple') || name.contains('britannia') || name.contains('libertad')) return 'silver_1oz';
    return 'silver_other';
  }

  return null; 
}