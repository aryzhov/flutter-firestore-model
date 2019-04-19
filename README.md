# firestore_model

Read-write model objects for Firebase Cloud Firestore backend based on mutable_model package.

## Example

Demonstrates how to define a model class that supports Firebase serialization.

```dart
import 'package:firestore_model/firestore_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class MetaProduct extends MetaModel {
  static final productsRef = Firestore.instance.collection('products'); 

  static final category = Attribute('category', StringProp());
  static final name = Attribute('name', StringProp());
  static final stock = Attribute('stock', IntProp(0));
  static final onSale = Attribute('onSale', BoolProp(false));
  static final price = Attribute('price', DoubleProp());
  static final created = TimestampAttr('created', value);

  static final instance = MetaProduct();
   
  @override
  get collectionRef => prodictsRef;

  @override
  get attrs => [category, name, stock, onSale, price, created];
  
}

class Product extends FirestoreModel {
  
  String get category => get(MetaProduct.category);
  String get name => get(MetaProduct.name);
  int get stock => get(MetaProduct.stock);
  bool get onSale => get(MetaProduct.onSale);
  double get price => get(MetaProduct.price);
  DateTime get created => get(MetaProduct.created);

  set category(String value) => set(MetaProduct.category, value);
  set name(String value) => set(MetaProduct.name, value);
  set stock(int value) => set(MetaProduct.stock, value);
  set onSale(bool value) => set(MetaProduct.onSale, value);
  set price(double value) => set(MetaProduct.price, value);
  
  void setCreated() {
    setData(MetaProduct.created, MetaProduct.created.serverTimestamp());
  }

  static Future<List<Product>> getProductsByName(String name) async {
    return (await ProductAttributes.name.whereEquals(name,
      MetaProduct.productsRef
    ).getDocuments()).map((snapshot) => Product()..init(snapshot)).toList();
  }
}
```
